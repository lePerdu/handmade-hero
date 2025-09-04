package wayland

import "base:runtime"
import "core:io"

// Growable ring buffer
// TODO: Just use bytes.Buffer and container/queue for the various use-cases?
// This doesn't need to copy data as often as bytes.Buffer, but having data always be contiguous is nice
Ring_Buffer :: struct($T: typeid) {
	data:      []T,
	allocator: runtime.Allocator,
	head:      int,
	size:      int,
}

@(private)
RING_MIN_SIZE :: 16

ring_init :: proc(
	ring: ^Ring_Buffer($T),
	cap: int,
	allocator := context.allocator,
) -> (
	err: runtime.Allocator_Error,
) {
	ring.data, err = make([]T, ring_pow2_size(cap), allocator)
	ring.allocator = allocator
	ring.head = 0
	ring.size = 0
	return
}

@(private)
ring_wrap :: #force_inline proc(ring: ^Ring_Buffer($T), index: int) -> int {
	// Only works because len is a power of 2
	assert(len(ring.data) & (len(ring.data) - 1) == 0)
	return index & (len(ring.data) - 1)
}

@(private)
ring_pow2_size :: proc(cap: int, min_size: int = RING_MIN_SIZE) -> int {
	assert(min_size & (min_size - 1) == 0)
	size := min_size
	for size < cap {
		// TODO: Handle overflow
		size *= 2
	}
	return size
}

ring_read :: proc(ring: ^Ring_Buffer($T), buf: []T) -> (n_read: int) {
	wrapped_len := ring.head + ring.size - len(ring.data)
	if wrapped_len > 0 {
		n_read += copy(buf, ring.data[ring.head:])
		// copy() checks sizes of both buffers, so the second one will be a no-op if buf is already filled
		n_read += copy(buf[n_read:], ring.data[:wrapped_len])
	} else {
		n_read += copy(buf, ring.data[ring.head:ring.head + ring.size])
	}

	ring.head = ring_wrap(ring, ring.head + n_read)
	ring.size -= n_read
	return
}

ring_write :: proc(ring: ^Ring_Buffer($T), buf: []T) -> (n_written: int) {
	wrapped_len := ring.head + ring.size - len(ring.data)
	if wrapped_len > 0 {
		n_written += copy(ring.data[wrapped_len:ring.head], buf)
	} else {
		n_written += copy(ring.data[ring.head + ring.size:], buf)
		n_written += copy(ring.data[:ring.head], buf[n_written:])
	}

	ring.size += n_written
	return
}

ring_ensure_space :: proc(ring: ^Ring_Buffer($T), space: int) -> runtime.Allocator_Error {
	req_size := ring.size + space
	if req_size > len(ring.data) {
		new_data, err := make([]T, ring_pow2_size(req_size, min_size = ring.size), ring.allocator)
		if err != .None do return err
		// Copy existing data to the front for simplicity
		n_copied := ring_read(ring, new_data)
		assert(n_copied == ring.size)
		ring.data = new_data
		ring.head = 0
	}
	return .None
}

ring_write_expand :: proc(ring: ^Ring_Buffer($T), buf: []T) -> runtime.Allocator_Error {
	ring_ensure_space(ring, len(buf))
	n_written := ring_write(ring, buf)
	assert(n_writte == len(buf))
	return .None
}

ring_append :: proc(ring: ^Ring_Buffer($T), elem: T) -> runtime.Allocator_Error {
	err := ring_ensure_space(ring, 1)
	if err != .None do return err
	ring.data[ring_wrap(ring, ring.head + ring.size)] = elem
	ring.size += 1
	return .None
}

ring_remove :: proc(ring: ^Ring_Buffer($T)) -> (T, bool) {
	if ring.size == 0 do return {}, false
	ring.size -= 1
	return ring.data[ring_wrap(ring, ring.head + ring.size)], true
}

ring_slice :: proc(ring: Ring_Buffer($T), start: int, end: int) -> Ring_Buffer(T) {
	assert(start >= 0)
	assert(start < ring.size)
	assert(end > start)
	assert(end < ring.size)
	return {
		allocator = ring.allocator,
		data = ring.data,
		head = ring_wrap(&ring, ring.head + start),
		size = end - start,
	}
}

@(private)
ring_stream_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (
	n: i64,
	err: io.Error,
) {
	ring := (^Ring_Buffer(u8))(stream_data)
	#partial switch mode {
	case .Read:
		if len(p) == 0 {
			return 0, nil
		}
		if ring.size == 0 {
			return 0, .EOF
		}
		n_read := ring_read(ring, p)
		if n_read < len(p) {
			return i64(n_read), .EOF
		} else {
			return i64(n_read), nil
		}
	case .Write:
		if len(p) == 0 {
			return 0, nil
		}
		// TODO: Use write_expand instead?
		n_written := ring_write(ring, p)
		if n_written < len(p) {
			return i64(n_written), .Buffer_Full
		} else {
			return i64(n_written), nil
		}
	// TODO: Implement Seek, Read_At, Write_At?
	case .Query:
		return io.query_utility({.Read, .Write, .Query})
	case:
		return 0, .Empty
	}
}

ring_to_stream :: proc(ring: ^Ring_Buffer(u8)) -> io.Read_Writer {
	return {procedure = ring_stream_proc, data = ring}
}
