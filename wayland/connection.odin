package wayland

import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import "core:c"
import "core:container/queue"
import "core:crypto/_aes/hw_intel"
import "core:io"
import "core:log"
import "core:mem"
import "core:os"
import "core:os/os2"
import "core:path/filepath"
import "core:slice"
import "core:sys/linux"
import "core:sys/posix"

ID_Allocator :: struct {
	free_list:    [dynamic]Object_Id,
	// Store "last used" instead of "next unused" so that zero-initialization is valid (for tracking client IDs, at least)
	last_used_id: Object_Id,
}

id_allocator_init :: proc(id_alloc: ^ID_Allocator, allocator := context.allocator) {
	// TODO: Is this the proper way to configure an allocator for a dynamic array without allocating it?
	id_alloc.free_list = make([dynamic]Object_Id, 0, 0, allocator)
	id_alloc.last_used_id = MIN_CLIENT_ID - 1
}

id_allocator_destroy :: proc(id_alloc: ^ID_Allocator) {
	delete(id_alloc.free_list)
	id_alloc.free_list = nil
	id_alloc.last_used_id = MIN_CLIENT_ID - 1
}

id_allocator_alloc :: proc(id_alloc: ^ID_Allocator) -> (Object_Id, bool) {
	if id, ok := pop_safe(&id_alloc.free_list); ok {
		return id, true
	}
	if id_alloc.last_used_id == MAX_CLIENT_ID {
		return 0, false
	}
	id_alloc.last_used_id += 1
	return id_alloc.last_used_id, true
}

id_allocator_free :: proc(id_alloc: ^ID_Allocator, id: Object_Id) -> runtime.Allocator_Error {
	if id == id_alloc.last_used_id {
		id_alloc.last_used_id -= 1
		return nil
	} else if MIN_CLIENT_ID <= id && id <= MAX_CLIENT_ID {
		// TODO: Check that it isn't already freed?
		_, err := append(&id_alloc.free_list, id)
		return err
	} else {
		log.warnf("tried to free non-client-side ID: {}", id)
		return nil
	}
}

Connection :: struct {
	socket_fd:          posix.FD,
	id_allocator:       ID_Allocator,
	send_buf, recv_buf: bytes.Buffer,
	send_fds, recv_fds: queue.Queue(posix.FD),
}

connection_reader :: #force_inline proc(conn: ^Connection) -> io.Reader {
	return bytes.buffer_to_stream(&conn.recv_buf)
}

connection_writer :: #force_inline proc(conn: ^Connection) -> io.Writer {
	// TODO: Wrap in writer that flushes outgoing messages instead of just expanding the buffer
	return bytes.buffer_to_stream(&conn.send_buf)
}

connection_alloc_id :: proc(conn: ^Connection) -> (Object_Id, ID_Error) {
	if id, ok := id_allocator_alloc(&conn.id_allocator); ok {
		return id, nil
	} else {
		return 0, .No_More_IDs
	}
}

connection_free_id :: proc(conn: ^Connection, id: Object_Id) {
	if err := id_allocator_free(&conn.id_allocator, id); err != nil {
		log.warnf("object ID could not be freed for reuse: {}: {}", id, err)
	}
}

FD_Error :: enum {
	None = 0,
	Expected_FD,
	FD_Buffer_Full,
	FD_Dup_Failed,
}

ID_Error :: enum {
	None = 0,
	No_More_IDs,
}

Parse_Error :: enum {
	None = 0,
	Invalid_Message,
}

Conn_Error :: union #shared_nil {
	io.Error,
	FD_Error,
	ID_Error,
	Parse_Error,
}

connection_read_fd :: proc(conn: ^Connection) -> (posix.FD, FD_Error) {
	if fd, ok := queue.pop_front_safe(&conn.recv_fds); ok {
		return fd, nil
	} else {
		return -1, .Expected_FD
	}
}

connection_write_fd :: proc(conn: ^Connection, fd: posix.FD) -> FD_Error {
	// dup the FD since it will be sent asynchronously
	fd := posix.dup(fd)
	if fd == -1 {
		log.error("failed to dup FD:", posix.errno())
		return .FD_Dup_Failed
	}
	if ok, _ := queue.push_back(&conn.send_fds, fd); !ok {
		return .FD_Buffer_Full
	} else {
		return nil
	}
}

Socket_Path_Error :: enum {
	None = 0,
	Env_Var_Not_Found,
	Env_Var_Error,
	Path_Too_Long,
}

@(private)
build_socket_path :: proc(path_buf: []u8) -> Socket_Path_Error {
	// New variable so it can be offset
	path_buf := path_buf

	err: os.Error
	xdg_runtime_dir: string
	// Leave room for / and null byte
	switch xdg_runtime_dir, err = os.lookup_env(
		path_buf[:len(path_buf) - 2],
		"XDG_RUNTIME_DIR",
	); err {
	case nil:
	case .Buffer_Full:
		log.error("XDG_RUNTIME_DIR too long")
		return .Path_Too_Long
	case .Env_Var_Not_Found:
		log.error("could not find XDG_RUNTIME_DIR", err)
		return .Env_Var_Not_Found
	case:
		log.error("could not read XDG_RUNTIME_DIR", err)
		return .Env_Var_Error
	}

	path_buf[len(xdg_runtime_dir)] = filepath.SEPARATOR
	path_buf = path_buf[len(xdg_runtime_dir) + 1:]

	wayland_display: string
	// Leave room for null byte
	switch wayland_display, err = os.lookup_env(
		path_buf[:len(path_buf) - 1],
		"WAYLAND_DISPLAY",
	); err {
	case nil:
	case .Env_Var_Not_Found:
		wayland_display = "wayland-0"
		if copy(path_buf, wayland_display) < len(wayland_display) {
			log.error("default for WAYLAND_DISPLAY too long")
			return .Path_Too_Long
		}
	case .Buffer_Full:
		log.error("WAYLAND_DISPLAY too long")
		return .Path_Too_Long
	case:
		log.error("could not read WAYLAND_DISPLAY")
		return .Env_Var_Error
	}
	path_buf[len(wayland_display)] = 0

	return nil
}

Connect_Error :: union #shared_nil {
	posix.Errno,
	Socket_Path_Error,
}

// Large enough to hold any message
// TODO: This can probably be smaller if logic is added to expand the buffer as-needed based on messages that are sent/received
CONN_INIT_BUF_LEN :: 65536

connection_init :: proc(conn: ^Connection, allocator := context.allocator) -> Connect_Error {
	sockaddr := posix.sockaddr_un {
		sun_family = .UNIX,
	}

	if err := build_socket_path(sockaddr.sun_path[:]); err != nil {
		return err
	}

	// TODO: Report "bug" since it isn't really "IP"
	conn.socket_fd = posix.socket(.UNIX, .STREAM, .IP)
	if conn.socket_fd == -1 {
		log.error("failed to create socket:", posix.errno())
		return posix.errno()
	}

	{
		// TODO: Use linux-specific SOCK_NONBLOCK (and other Linux APIs?)
		flags := posix.fcntl(conn.socket_fd, .GETFL)
		if flags == -1 {
			log.error("failed to get socket flags:", posix.errno())
			return posix.errno()
		}
		flags = posix.fcntl(conn.socket_fd, .SETFL, flags | posix.O_NONBLOCK)
		if flags == -1 {
			log.error("failed to make socket non-blocking:", posix.errno())
			return posix.errno()
		}
	}

	if posix.connect(conn.socket_fd, (^posix.sockaddr)(&sockaddr), size_of(sockaddr)) == .FAIL {
		log.error(
			"could not connect to Wayland socket:",
			cstring(&sockaddr.sun_path[0]),
			":",
			posix.strerror(posix.errno()),
		)
		posix.close(conn.socket_fd)
		return posix.errno()
	}

	id_allocator_init(&conn.id_allocator, allocator)
	bytes.buffer_init_allocator(&conn.send_buf, 0, CONN_INIT_BUF_LEN, allocator)
	bytes.buffer_init_allocator(&conn.recv_buf, 0, CONN_INIT_BUF_LEN, allocator)
	queue.init(&conn.send_fds, allocator = allocator)
	queue.init(&conn.recv_fds, allocator = allocator)
	return nil
}

connection_close :: proc(conn: ^Connection) -> posix.result {
	id_allocator_destroy(&conn.id_allocator)
	bytes.buffer_destroy(&conn.send_buf)
	bytes.buffer_destroy(&conn.recv_buf)
	queue.destroy(&conn.send_fds)
	queue.destroy(&conn.recv_fds)

	for i in 0 ..< queue.len(conn.send_fds) {
		posix.close(queue.get(&conn.send_fds, i))
	}
	for i in 0 ..< queue.len(conn.recv_fds) {
		posix.close(queue.get(&conn.recv_fds, i))
	}
	return posix.close(conn.socket_fd)
}

// From man pages and testing
SCM_MAX_FD :: 253
CMSG_MAX_LEN :: 1032

CMSG_ALIGN :: #force_inline proc(size: int) -> int {
	return (size + size_of(uint) - 1) & ~int(size_of(uint) - 1)
}

CMSG_SPACE :: #force_inline proc(size: int) -> int {
	return CMSG_ALIGN(size) + CMSG_ALIGN(size_of(posix.cmsghdr))
}

CMSG_LEN :: #force_inline proc(size: int) -> int {
	return CMSG_ALIGN(size_of(posix.cmsghdr)) + size
}

Flush_Error :: enum {
	None = 0,
	Would_Block,
	Send_Failed,
}

// Flush write buffer
@(private)
send_chunk :: proc(conn: ^Connection, max_len: int) -> Flush_Error {
	data_iov := posix.iovec {
		iov_base = &bytes.buffer_to_bytes(&conn.send_buf)[0],
		iov_len  = uint(max_len),
	}

	// Wrap in a struct to ensure alignment
	cmsg_buf := struct #align (align_of(posix.cmsghdr)) {
		buf: [CMSG_MAX_LEN]u8,
	}{}

	fds_to_send := min(queue.len(conn.send_fds), SCM_MAX_FD)
	cmsg_len := uint(CMSG_LEN(size_of(posix.FD) * fds_to_send))

	msg := posix.msghdr {
		msg_iov        = &data_iov,
		msg_iovlen     = 1,
		msg_control    = &cmsg_buf,
		msg_controllen = cmsg_len,
	}

	cmsg := posix.CMSG_FIRSTHDR(&msg)
	assert(cmsg != nil)
	cmsg^ = posix.cmsghdr {
		cmsg_len   = cmsg_len,
		cmsg_level = posix.SOL_SOCKET,
		cmsg_type  = posix.SCM_RIGHTS,
	}

	// Copy the FDs, but keep them in the queue for now in case the send fails
	cmsg_data_base := posix.CMSG_DATA(cmsg)
	for i in 0 ..< fds_to_send {
		// man page says to use memcpy instead of casting
		mem.copy(
			&cmsg_data_base[size_of(posix.FD) * i],
			queue.get_ptr(&conn.send_fds, i),
			size_of(posix.FD),
		)
	}

	send_res: c.ssize_t
	for {
		send_res = posix.sendmsg(conn.socket_fd, &msg, {.NOSIGNAL})
		if send_res == -1 && posix.errno() == .EINTR do continue
		break
	}

	if send_res == -1 {
		if posix.errno() == .EAGAIN || posix.errno() == .EWOULDBLOCK {
			return .Would_Block
		}

		log.error("failed to send wayland message:", posix.errno())
		return .Send_Failed
	}

	// FDs are dup'ed when stored, so they can be closed now
	for i in 0 ..< fds_to_send {
		posix.close(queue.get(&conn.send_fds, i))
	}

	// Mark the data as sent
	queue.consume_front(&conn.send_fds, fds_to_send)
	bytes.buffer_next(&conn.send_buf, send_res)
	return nil
}

@(private)
_connection_flush :: proc(conn: ^Connection) -> Flush_Error {
	// Send FDs (almost) by themselves if somehow there are more than fit in 1 message
	// (this is done by libwayland, so might as well copy them)
	for queue.len(conn.send_fds) > SCM_MAX_FD {
		send_chunk(conn, 1) or_return
	}

	// Keep flushing until error or Would_Block
	for bytes.buffer_length(&conn.send_buf) > 0 {
		send_chunk(conn, bytes.buffer_length(&conn.send_buf)) or_return
	}
	return nil
}

connection_flush :: proc(conn: ^Connection) -> (ok: bool) {
	if err := _connection_flush(conn); err == nil || err == .Would_Block {
		return true
	} else {
		return false
	}
}

connection_needs_flush :: proc(conn: ^Connection) -> bool {
	return !bytes.buffer_is_empty(&conn.send_buf)
}

@(private)
_posix_socket_stream_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []u8,
	offset: i64,
	whence: io.Seek_From,
) -> (
	i64,
	io.Error,
) {
	fd := posix.FD(uintptr(stream_data))
	#partial switch mode {
	case .Read:
		if len(p) == 0 do return 0, .None
		n_read: c.ssize_t
		for {
			n_read = posix.read(fd, &p[0], len(p))
			if n_read == -1 && posix.errno() == .EINTR do continue
			break
		}
		if n_read == -1 do return 0, .Unknown
		if n_read == 0 do return 0, .EOF
		return i64(n_read), .None
	case .Write:
		if len(p) == 0 do return 0, .None
		n_written: c.ssize_t
		for {
			n_written = posix.write(fd, &p[0], len(p))
			if n_written == -1 && posix.errno() == .EINTR do continue
			break
		}
		if n_written == -1 do return 0, .Unknown
		if n_written == 0 do return 0, .EOF
		return i64(n_written), .None
	case .Close:
		if posix.close(fd) == .OK {
			return 0, .None
		} else {
			return 0, .Unknown
		}
	case .Query:
		return io.query_utility({.Read, .Write, .Close})
	case:
		return 0, .Empty
	}
}

@(private)
socket_to_stream :: proc(socket_fd: posix.FD) -> io.Read_Write_Closer {
	return {procedure = _posix_socket_stream_proc, data = rawptr(uintptr(socket_fd))}
}

Read_Error :: enum {
	None = 0,
	Would_Block,
	Failed,
}

@(private)
read_chunk :: proc(conn: ^Connection, read_at_least: int) -> (n: int, err: Read_Error) {
	// Create capacity in the buffer for read_at_least
	init_len := bytes.buffer_length(&conn.recv_buf)
	bytes.buffer_grow(&conn.recv_buf, max(bytes.MIN_READ, read_at_least))
	// Update space in case the buffer was grown larger
	end_off := len(conn.recv_buf.buf)
	space := bytes.buffer_capacity(&conn.recv_buf) - end_off
	// TODO: Figure out a way to do this that doesn't require messing around with bytes.Buffer's internal state
	resize(&conn.recv_buf.buf, bytes.buffer_capacity(&conn.recv_buf))

	// Collapse the buffer to fit existing data
	defer bytes.buffer_truncate(&conn.recv_buf, init_len + n)

	data_iov := posix.iovec {
		iov_base = &bytes.buffer_to_bytes(&conn.recv_buf)[end_off],
		iov_len  = uint(space),
	}

	// Wrap in a struct to ensure alignment
	cmsg_buf := struct #align (align_of(posix.cmsghdr)) {
		buf: [CMSG_MAX_LEN]u8,
	}{}

	msg := posix.msghdr {
		msg_iov        = &data_iov,
		msg_iovlen     = 1,
		msg_control    = &cmsg_buf,
		msg_controllen = CMSG_MAX_LEN,
	}

	recv_res: c.ssize_t
	for {
		recv_res = posix.recvmsg(conn.socket_fd, &msg, {.NOSIGNAL})
		if recv_res == -1 && posix.errno() == .EINTR do continue
		break
	}

	if recv_res == -1 {
		if posix.errno() == .EAGAIN || posix.errno() == .EWOULDBLOCK {
			return 0, .Would_Block
		}

		log.error("failed to send wayland message:", posix.strerror())
		return 0, .Failed
	}

	n = recv_res

	if cmsg := posix.CMSG_FIRSTHDR(&msg); cmsg != nil {
		// Copy the FDs, but keep them in the queue for now in case the send fails
		cmsg_data_base := posix.CMSG_DATA(cmsg)
		fd_count :=
			(cmsg.cmsg_len - uint(uintptr(cmsg_data_base) - uintptr(cmsg))) / size_of(posix.FD)
		for i in 0 ..< fd_count {
			fd: posix.FD
			// man page says to use memcpy instead of casting
			mem.copy(&fd, &cmsg_data_base[size_of(fd) * i], size_of(fd))
			queue.push_back(&conn.recv_fds, fd)
		}
	}

	return
}

@(private)
fill_read_buffer :: proc(conn: ^Connection, read_at_least: int) -> (n: int, err: Read_Error) {
	for n < read_at_least {
		n += read_chunk(conn, read_at_least - n) or_return
	}
	return
}

@(private)
try_parse_buffered_message :: proc(conn: ^Connection) -> (message: Message, bytes_needed: int) {
	buf_len := bytes.buffer_length(&conn.recv_buf)
	if bytes_needed = message_header_size - buf_len; bytes_needed > 0 {
		return
	}

	// Copy the bytes, but don't advance the buffer until we know the full message is available
	header_bytes: [message_header_size]u8
	copy(header_bytes[:], bytes.buffer_to_bytes(&conn.recv_buf))

	message.header = message_parse_header(header_bytes)
	if message.header.size < message_header_size {
		log.error("message size field too small:", message.header.size)
		bytes_needed = -1
		return
	}
	if bytes_needed = int(message.header.size) - buf_len; bytes_needed > 0 {
		return
	}

	message.payload =
	bytes.buffer_next(&conn.recv_buf, int(message.header.size))[message_header_size:]
	bytes_needed = 0
	return
}

connection_next_event :: proc(conn: ^Connection) -> (message: Message, err: Read_Error) {
	// May need to run up to 3 times since it may take some data to determine the next message size/
	// For example:
	// 1)
	//  - header isn't complete, so full size isn't known
	//  - read 8 bytes for the header
	// 2)
	//  - full size is known, but now the buffer needs to be shifted/grown to fit the whole message
	//  - read full message size
	// 3)
	//  - now the message can be fully parsed
	for _ in 1 ..= 3 {
		// Try to parse from current buffer
		bytes_needed: int
		message, bytes_needed = try_parse_buffered_message(conn)
		switch bytes_needed {
		case 0:
			return message, nil
		case -1:
			return {}, .Failed
		}

		// Read from network
		n_read := fill_read_buffer(conn, bytes_needed) or_return
		if n_read < bytes_needed do return {}, .Would_Block
	}
	return
}

connection_skip_event :: proc(conn: ^Connection, header: Event_Header) {
	_ = bytes.buffer_next(&conn.recv_buf, int(header.size))
}
