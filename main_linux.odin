package main

import "base:intrinsics"
import "core:c"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

State :: struct {
	display: Display_State,
	audio:   Audio_State,
	game:    Game_State,
}

main :: proc() {
	context.logger = log.create_console_logger(lowest = .Info)

	state: State

	if !display_init(&state.display) do os.exit(1)

	if audio_init(&state.audio) != nil do os.exit(1)

	game_loop(&state)
}

MIN_UPDATE_PERIOD_NS :: 1_000_000_000 / 30

game_loop :: proc(state: ^State) {
	poll_fds: []posix.pollfd
	display_poll_fd: ^posix.pollfd
	audio_poll_fds: []posix.pollfd
	{
		audio_poll_fd_count := audio_get_poll_descriptor_count(&state.audio)
		display_poll_fd_count := 1
		poll_fds = make([]posix.pollfd, display_poll_fd_count + audio_poll_fd_count)
		offset := 0
		display_poll_fd = &poll_fds[offset]
		offset += display_poll_fd_count
		audio_poll_fds = poll_fds[offset:][:audio_poll_fd_count]
		offset += audio_poll_fd_count
		assert(offset == len(poll_fds))
	}

	// display_poll_fd is initialized each time based on the state

	// ALSA docs say this can be called once since it doesn't need to change
	// dynamically:
	// https://www.alsa-project.org/alsa-doc/alsa-lib/group___p_c_m.html#ga742e8705f6992fd0e36efc868e574f01
	if ok := audio_get_poll_descriptors(&state.audio, audio_poll_fds); !ok {
		// TODO: Don't exit in case of audio-related failures?
		log.error("failed to initialize audio file descriptors")
		return
	}

	display_setup_first_frame(&state.display)

	last_loop_ns: i64
	last_update_time_ns: i64 = get_perf_counter_cpu_ns()
	last_render_time_ns: i64 = -1

	loop: for !state.display.close_requested {
		counter_start_wall_ns := get_perf_counter_wall_ns()
		counter_start_cpu_ns := get_perf_counter_cpu_ns()
		counter_start_cpu_cycles := get_perf_counter_cpu_cycles()

		if poll_fd, ok := display_get_poll_descriptor(&state.display); ok {
			display_poll_fd^ = poll_fd
		} else {
			log.error("failed to setup display file descriptors")
			break
		}

		// Set timeout at next simulation frame boundary in case there are no
		// display/audio events to process
		next_update_time_ns := last_update_time_ns + MIN_UPDATE_PERIOD_NS
		max_wait_time_ms := i32(
			max(next_update_time_ns - get_perf_counter_cpu_ns(), 0) / 1_000_000,
		)
		switch poll_res := posix.poll(&poll_fds[0], posix.nfds_t(1), max_wait_time_ms); poll_res {
		case 0:
			// timeout
			continue loop
		case -1:
			// error
			log.error("failed to poll for updates:", posix.errno())
			break loop
		}

		display_handle_poll(&state.display, display_poll_fd) or_break
		if button_input_press_count(state.display.keyboard_input[.Esc]) > 0 {
			break
		}

		// TODO: Simulate at fixed DT? Would require running this potentially
		// multiple times if the render loop takes longer than MIN_UPDATE_PERIOD_NS
		now := get_perf_counter_wall_ns()
		if now >= next_update_time_ns {
			// TODO: Don't create the Game_Input object every time
			input := Game_Input{state.display.keyboard_input}
			game_update(&state.game, input, now - last_update_time_ns)
			keyboard_input_reset(&state.display.keyboard_input)

			last_update_time_ns = now
		}

		if state.display.last_frame_time_ns > last_render_time_ns {
			game_render(&state.game, state.display.frame_buffers[state.display.back_buffer_index])
			last_render_time_ns = state.display.last_frame_time_ns
		}

		audio_handle_poll(state, audio_poll_fds) or_break

		free_all(context.temp_allocator)

		counter_total_wall_ns := get_perf_counter_wall_ns() - counter_start_wall_ns
		counter_total_cpu_ns := get_perf_counter_cpu_ns() - counter_start_cpu_ns
		counter_total_cpu_cycles := get_perf_counter_cpu_cycles() - counter_start_cpu_cycles

		log.debugf(
			"perf counter: wall={}ms  cpu={}ms  cycles={}K",
			counter_total_wall_ns / 1_000_000,
			counter_total_cpu_ns / 1_000_000,
			counter_total_cpu_cycles / 1_000_000,
		)
	}
}

// Video

import "vendor/wayland"

BUFFER_COUNT :: 2

Display_State :: struct {
	conn:               wayland.Connection,

	// Static IDs
	wl_display:         wayland.Wl_Display,
	wl_registry:        wayland.Wl_Registry,

	// Bound IDs from the registry
	wl_compositor:      wayland.Wl_Compositor,
	wl_seat:            wayland.Wl_Seat,
	wl_shm:             wayland.Wl_Shm,
	xdg_wm_base:        wayland.Xdg_Wm_Base,

	// SHM-related data (pointed is tracked in frame_buffer)
	shm_fd:             posix.FD,
	shm_data:           []u8,
	// TODO: Do these need to be persistend long-term?
	wl_shm_pool:        wayland.Wl_Shm_Pool,

	// Window-related objects and data
	wl_surface:         wayland.Wl_Surface,
	wl_buffers:         [BUFFER_COUNT]wayland.Wl_Buffer,
	xdg_surface:        wayland.Xdg_Surface,
	xdg_toplevel:       wayland.Xdg_Toplevel,
	surface_state:      Surface_State,
	close_requested:    bool,

	// Index of the buffer which should be used to render the next frame
	back_buffer_index:  int,

	// Input
	wl_keyboard:        wayland.Wl_Keyboard,
	keyboard_input:     Keyboard_Input,

	// Frame state
	frame_buffers:      [BUFFER_COUNT]Frame_Buffer,
	frame_callback:     wayland.Wl_Callback,
	frame_rate_ns:      i64,
	last_frame_time_ns: i64,
}

COLOR_CHANNELS :: 4

Surface_State :: enum {
	Initial = 0,
	Pending_Configure,
	Configured,
}

display_init :: proc(state: ^Display_State) -> bool {
	if err := wayland.connection_init(&state.conn); err != nil {
		log.fatal("failed to setup connection:", err)
		return false
	}

	// TODO: Query Wayland for this
	state.frame_rate_ns = 1_000_000_000 / 30

	// Display is always the first ID
	state.wl_display, _ = wayland.connection_alloc_id(&state.conn)

	err: wayland.Conn_Error
	state.wl_registry, err = wayland.wl_display_get_registry(&state.conn, state.wl_display)
	if err != nil {
		log.fatal("failed to setup wl_registry:", err)
		return false
	}

	// Initial setup event loop to bind to globals
	for state.wl_compositor == 0 || state.wl_shm == 0 || state.xdg_wm_base == 0 {
		wayland_socket_poll := posix.pollfd {
			fd     = state.conn.socket_fd,
			events = {.IN, .OUT},
		}
		switch poll_res := posix.poll(&wayland_socket_poll, 1, -1); poll_res {
		case 0: // timeout
		case -1:
			// error
			log.error("failed to poll wayland socket:", posix.errno())
		case:
			process_wayland_messages(state)
		}

		// Just in case some setup events need to allocate later on
		free_all(context.temp_allocator)
	}

	// Create window-related objects

	state.wl_surface, _ = wayland.wl_compositor_create_surface(&state.conn, state.wl_compositor)
	state.xdg_surface, _ = wayland.xdg_wm_base_get_xdg_surface(
		&state.conn,
		state.xdg_wm_base,
		state.wl_surface,
	)
	state.xdg_toplevel, _ = wayland.xdg_surface_get_toplevel(&state.conn, state.xdg_surface)
	_ = wayland.xdg_toplevel_set_title(&state.conn, state.xdg_toplevel, "Handmade")
	_ = wayland.wl_surface_commit(&state.conn, state.wl_surface)

	display_setup_buffers(state, 640, 480)

	return true
}

display_setup_buffers :: proc(state: ^Display_State, width, height: u32) {
	stride := width * COLOR_CHANNELS
	buffer_size := stride * height

	// Free current allocations
	// TODO: Re-use current SHM allocation when possible
	// TODO: Look into wl_shm_pool_resize when growing the pool

	for buf in state.wl_buffers {
		if buf != wayland.OBJECT_ID_NIL {
			_ = wayland.wl_buffer_destroy(&state.conn, buf)
		}
	}
	if state.wl_shm_pool != wayland.OBJECT_ID_NIL {
		_ = wayland.wl_shm_pool_destroy(&state.conn, state.wl_shm_pool)
	}
	destroy_shm_mapping(state.shm_fd, state.shm_data)

	shm_err: Shm_Error
	shm_data: []u8
	state.shm_fd, state.shm_data, shm_err = create_shm_file(BUFFER_COUNT * uint(buffer_size))
	if shm_err != nil {
		log.fatal("failed to create SHM file:", posix.strerror())
		return
	}
	for &fb, i in state.frame_buffers {
		fb.width = width
		fb.height = height
		fb.stride = stride
		fb.base = &state.shm_data[i * int(buffer_size)]
	}

	state.wl_shm_pool, _ = wayland.wl_shm_create_pool(
		&state.conn,
		state.wl_shm,
		state.shm_fd,
		i32(len(state.shm_data)),
	)
	for &buf, i in state.wl_buffers {
		buf, _ = wayland.wl_shm_pool_create_buffer(
			&state.conn,
			state.wl_shm_pool,
			offset = i32(i * int(buffer_size)),
			width = i32(width),
			height = i32(height),
			stride = i32(stride),
			format = .Xrgb8888,
		)
	}

	// Attach one of the new, valid buffers
	// TODO: Will this result in blank frames when resizing?
	_ = wayland.wl_surface_attach(
		&state.conn,
		state.wl_surface,
		state.wl_buffers[state.back_buffer_index],
		0,
		0,
	)
}

display_get_poll_descriptor :: proc(state: ^Display_State) -> (poll: posix.pollfd, ok: bool) {
	return posix.pollfd {
			fd = state.conn.socket_fd,
			events = wayland.connection_needs_flush(&state.conn) ? {.IN, .OUT} : {.IN},
		},
		true
}

display_handle_poll :: proc(state: ^Display_State, poll: ^posix.pollfd) -> (ok: bool) {
	if poll.revents & {.IN, .OUT} == {} {
		return true
	}
	process_wayland_messages(state)
	return true
}

// Submit the current frame, rendered in the back-buffer, and swap buffers to
// prepare for the next frame
submit_frame :: proc(state: ^Display_State) {
	wayland.wl_surface_attach(
		&state.conn,
		state.wl_surface,
		state.wl_buffers[state.back_buffer_index],
		0,
		0,
	)
	wayland.wl_surface_damage_buffer(&state.conn, state.wl_surface, 0, 0, max(i32), max(i32))
	wayland.wl_surface_commit(&state.conn, state.wl_surface)

	state.back_buffer_index = (state.back_buffer_index + 1) % BUFFER_COUNT
}

process_wayland_messages :: proc(state: ^Display_State) {
	// Whether the previous iteration processed any events (and hence, should re-flush outgoing messages)
	for processed_events := true; processed_events; {
		// Flush outgoing messages
		if !wayland.connection_flush(&state.conn) {
			log.error("failed to flush outgoing messages")
		}

		// Process all active messages
		processed_events = false
		for {
			if event, err := wayland.connection_next_event(&state.conn); err == nil {
				processed_events = true
				handle_event(state, event)
			} else {
				break
			}
		}
	}
}

handle_event :: proc(state: ^Display_State, message: wayland.Message) -> wayland.Conn_Error {
	opcode := message.header.opcode
	switch message.header.target {
	case 0:
		log.error("received event for nil object ID:", message)
		return nil
	case state.wl_display:
		switch opcode {
		case wayland.WL_DISPLAY_ERROR_EVENT_OPCODE:
			event := wayland.wl_display_error_parse(&state.conn, message) or_return
			handle_wl_display_error(state, event)
			return nil
		case wayland.WL_DISPLAY_DELETE_ID_EVENT_OPCODE:
			// Just parse for logging purposes for now
			// IDs are cleaned up in "destructor" calls currently, but maybe they should be cleaned up here?
			_ = wayland.wl_display_delete_id_parse(&state.conn, message) or_return
			return nil
		}
	case state.wl_registry:
		switch opcode {
		case wayland.WL_REGISTRY_GLOBAL_EVENT_OPCODE:
			event := wayland.wl_registry_global_parse(&state.conn, message) or_return
			handle_wl_registry_global(state, event)
			return nil
		case wayland.WL_REGISTRY_GLOBAL_REMOVE_EVENT_OPCODE:
		// TOOD: Cleanup various globals if they are removed
		}
	case state.wl_seat:
		switch opcode {
		case wayland.WL_SEAT_CAPABILITIES_EVENT_OPCODE:
			handle_seat_capabilities(
				state,
				wayland.wl_seat_capabilities_parse(&state.conn, message) or_return,
			)
			return nil
		case wayland.WL_SEAT_NAME_EVENT_OPCODE:
			// TODO: Does the name actually matter?
			_ = wayland.wl_seat_name_parse(&state.conn, message) or_return
			return nil
		}
	case state.wl_keyboard:
		switch opcode {
		case wayland.WL_KEYBOARD_KEYMAP_EVENT_OPCODE:
			handle_keyboard_keymap(
				state,
				wayland.wl_keyboard_keymap_parse(&state.conn, message) or_return,
			)
			return nil
		case wayland.WL_KEYBOARD_ENTER_EVENT_OPCODE:
			handle_keyboard_enter(
				state,
				wayland.wl_keyboard_enter_parse(&state.conn, message) or_return,
			)
			return nil
		case wayland.WL_KEYBOARD_LEAVE_EVENT_OPCODE:
			handle_keyboard_leave(
				state,
				wayland.wl_keyboard_leave_parse(&state.conn, message) or_return,
			)
			return nil
		case wayland.WL_KEYBOARD_KEY_EVENT_OPCODE:
			handle_keyboard_key(
				state,
				wayland.wl_keyboard_key_parse(&state.conn, message) or_return,
			)
			return nil
		case wayland.WL_KEYBOARD_MODIFIERS_EVENT_OPCODE:
			handle_keyboard_modifiers(
				state,
				wayland.wl_keyboard_modifiers_parse(&state.conn, message) or_return,
			)
			return nil
		}
	case state.wl_shm:
		switch opcode {
		case wayland.WL_SHM_FORMAT_EVENT_OPCODE:
			_ = wayland.wl_shm_format_parse(&state.conn, message) or_return
			// Ignore for now as the required foramts are sufficient
			return nil
		}
	case state.wl_surface:
		switch opcode {
		case wayland.WL_SURFACE_PREFERRED_BUFFER_SCALE_EVENT_OPCODE:
			_ = wayland.wl_surface_preferred_buffer_scale_parse(&state.conn, message) or_return
			// TODO: Impl
			return nil
		}
	case state.xdg_surface:
		switch opcode {
		case wayland.XDG_SURFACE_CONFIGURE_EVENT_OPCODE:
			handle_xdg_surface_configure(
				state,
				wayland.xdg_surface_configure_parse(&state.conn, message) or_return,
			)
			return nil
		}
	case state.xdg_toplevel:
		switch opcode {
		case wayland.XDG_TOPLEVEL_CLOSE_EVENT_OPCODE:
			handle_xdg_toplevel_close(
				state,
				wayland.xdg_toplevel_close_parse(&state.conn, message) or_return,
			)
			return nil
		case wayland.XDG_TOPLEVEL_CONFIGURE_EVENT_OPCODE:
			handle_xdg_toplevel_configure(
				state,
				wayland.xdg_toplevel_configure_parse(&state.conn, message) or_return,
			)
			return nil
		}
	case state.xdg_wm_base:
		switch opcode {
		case wayland.XDG_WM_BASE_PING_EVENT_OPCODE:
			handle_xdg_wm_base_ping(
				state,
				wayland.xdg_wm_base_ping_parse(&state.conn, message) or_return,
			)
			return nil
		}

	case state.frame_callback:
		switch opcode {
		case wayland.WL_CALLBACK_DONE_EVENT_OPCODE:
			handle_frame_callback(
				state,
				wayland.wl_callback_done_parse(&state.conn, message) or_return,
			)
			return nil
		}
	}
	for buf in state.wl_buffers {
		if message.header.target == buf {
			switch opcode {
			case wayland.WL_BUFFER_RELEASE_EVENT_OPCODE:
				handle_buffer_release(
					state,
					wayland.wl_buffer_release_parse(&state.conn, message) or_return,
				)
				return nil
			}
		}
	}

	log.debugf(
		"<- unhandled message: target={} opcode={} size={}",
		message.header.target,
		message.header.opcode,
		message.header.size,
	)
	return nil
}

handle_wl_display_error :: proc(state: ^Display_State, event: wayland.Wl_Display_Error_Event) {
	log.errorf(
		"error from compositor: object_id={} code={} message={}",
		event.object_id,
		event.code,
		event.message,
	)
}

handle_wl_registry_global :: proc(state: ^Display_State, event: wayland.Wl_Registry_Global_Event) {
	state_field: ^wayland.Object_Id
	switch event.interface {
	case "wl_compositor":
		state_field = &state.wl_compositor
	case "wl_seat":
		state_field = &state.wl_seat
	case "wl_shm":
		state_field = &state.wl_shm
	case "xdg_wm_base":
		state_field = &state.xdg_wm_base
	}
	if state_field == nil do return

	err: wayland.Conn_Error
	state_field^, err = wayland.wl_registry_bind(
		&state.conn,
		state.wl_registry,
		event.name,
		event.interface,
		event.version,
	)
	if err != nil {
		log.error("failed to send bind request for:", event)
	}
}

handle_xdg_wm_base_ping :: proc(state: ^Display_State, event: wayland.Xdg_Wm_Base_Ping_Event) {
	_ = wayland.xdg_wm_base_pong(&state.conn, state.xdg_wm_base, event.serial)
}

handle_xdg_surface_configure :: proc(
	state: ^Display_State,
	event: wayland.Xdg_Surface_Configure_Event,
) {
	// TODO: Should drawing happen here instead?
	_ = wayland.xdg_surface_ack_configure(&state.conn, state.xdg_surface, event.serial)
	_ = wayland.wl_surface_commit(&state.conn, state.wl_surface)
}

handle_xdg_toplevel_configure :: proc(
	state: ^Display_State,
	event: wayland.Xdg_Toplevel_Configure_Event,
) {
	states := mem.slice_data_cast([]wayland.Xdg_Toplevel_State_Enum, event.states)
	log.debug("xdg_toplevel.configure: states={}", states)
	// TODO: Actually handle the requests
}

request_frame_callback :: proc(state: ^Display_State) {
	if cb, err := wayland.wl_surface_frame(&state.conn, state.wl_surface); err == nil {
		state.frame_callback = cb
	} else {
		log.errorf("frame request failed: {}", err)
	}
}

handle_frame_callback :: proc(state: ^Display_State, event: wayland.Wl_Callback_Done_Event) {
	request_frame_callback(state)

	frame_time_ms := event.callback_data
	frame_time_ns := i64(frame_time_ms) * 1_000_000

	frame_dt_ns: i64
	if state.last_frame_time_ns == 0 {
		frame_dt_ns = 0
	} else {
		frame_dt_ns = frame_time_ns - state.last_frame_time_ns
	}
	log.debugf("frame: {}ms", f64(frame_dt_ns) / 1_000_000.0)

	state.last_frame_time_ns = frame_time_ns

	submit_frame(state)
}

display_setup_first_frame :: proc(state: ^Display_State) {
	request_frame_callback(state)
}

handle_buffer_release :: proc(state: ^Display_State, event: wayland.Wl_Buffer_Release_Event) {
	// TODO: Is there anything to do here?
	// With double-buffering, this seems irrelevant
}

handle_xdg_toplevel_close :: proc(state: ^Display_State, event: wayland.Xdg_Toplevel_Close_Event) {
	state.close_requested = true
}

handle_seat_capabilities :: proc(
	state: ^Display_State,
	event: wayland.Wl_Seat_Capabilities_Event,
) {
	if .Keyboard not_in event.capabilities {
		log.error("wl_seat keyboard not available")
		return
	}

	state.wl_keyboard, _ = wayland.wl_seat_get_keyboard(&state.conn, state.wl_seat)
}

// TODO: Pull these (and others) from linux EVDEV header
KEY_W :: 17
KEY_A :: 30
KEY_S :: 31
KEY_D :: 32

KEY_UP :: 103
KEY_LEFT :: 105
KEY_DOWN :: 108
KEY_RIGHT :: 106
KEY_SPACE :: 57
KEY_ESC :: 1

handle_keyboard_keymap :: proc(state: ^Display_State, event: wayland.Wl_Keyboard_Keymap_Event) {
	// Don't care about the keymap for now
	if event.fd > 0 do posix.close(event.fd)
}

scancode_to_key :: proc(code: u32) -> (Key, bool) {
	switch code {
	case KEY_W:
		return .W, true
	case KEY_A:
		return .A, true
	case KEY_S:
		return .S, true
	case KEY_D:
		return .D, true
	case KEY_UP:
		return .UP, true
	case KEY_LEFT:
		return .Left, true
	case KEY_DOWN:
		return .Down, true
	case KEY_RIGHT:
		return .Right, true
	case KEY_SPACE:
		return .Space, true
	case KEY_ESC:
		return .Esc, true
	case:
		return {}, false
	}
}

handle_keyboard_enter :: proc(state: ^Display_State, event: wayland.Wl_Keyboard_Enter_Event) {
	scan_codes := mem.slice_data_cast([]u32, event.keys)
	for code in scan_codes {
		if k, ok := scancode_to_key(code); ok {
			button_input_update(&state.keyboard_input[k], pressed = true)
		}
	}
}

handle_keyboard_leave :: proc(state: ^Display_State, event: wayland.Wl_Keyboard_Leave_Event) {
	// Releasing all keys when un-focusing makes logic in `enter` easiest
	for &key in state.keyboard_input {
		button_input_update(&key, pressed = false)
	}
}

handle_keyboard_key :: proc(state: ^Display_State, event: wayland.Wl_Keyboard_Key_Event) {
	// TODO: Track event time?
	if k, ok := scancode_to_key(event.key); ok {
		button_input_update(&state.keyboard_input[k], pressed = event.state == .Pressed)
	}
}

handle_keyboard_modifiers :: proc(
	state: ^Display_State,
	event: wayland.Wl_Keyboard_Modifiers_Event,
) {}

Shm_Error :: posix.Errno

create_shm_file :: proc(size: uint) -> (shm_fd: posix.FD, shm_buf: []u8, err: Shm_Error) {
	name_buf := [255]u8{}
	name_builder := strings.builder_from_slice(name_buf[:])
	// TODO: More robust way of making a random name?
	strings.write_byte(&name_builder, filepath.SEPARATOR)
	strings.write_u64(&name_builder, rand.uint64())
	strings.write_u64(&name_builder, rand.uint64())
	strings.write_u64(&name_builder, rand.uint64())
	strings.write_u64(&name_builder, rand.uint64())

	name := strings.to_cstring(&name_builder)
	shm_fd = posix.shm_open(name, {.CREAT, .EXCL, .RDWR}, {.IRUSR, .IWUSR})
	if shm_fd == -1 {
		err = posix.errno()
		return
	}

	if posix.shm_unlink(name) != .OK {
		posix.close(shm_fd)
		err = posix.errno()
		return
	}

	if posix.ftruncate(shm_fd, posix.off_t(size)) != .OK {
		posix.close(shm_fd)
		err = posix.errno()
		return
	}

	mmap_ptr := posix.mmap(nil, size, {.READ, .WRITE}, {.SHARED}, shm_fd)
	if mmap_ptr == posix.MAP_FAILED {
		posix.close(shm_fd)
		err = posix.errno()
		return
	}

	shm_buf = mem.byte_slice(mmap_ptr, size)
	return
}

destroy_shm_mapping :: proc(shm_fd: posix.FD, shm_buf: []u8) {
	if shm_fd == 0 {
		return
	}

	if res := posix.close(shm_fd); res != .OK {
		log.warnf("failed to close SHM file descriptor: {}", posix.strerror())
	}
	if res := posix.munmap(&shm_buf[0], len(shm_buf)); res != .OK {
		log.warnf("failed to unmap SHM region: {}", posix.strerror())
	}
}

// Audio

import "vendor/alsa"

SAMPLE_RATE :: 48000
BUF_DURATION_SEC :: 2
BUF_FRAME_COUNT :: BUF_DURATION_SEC * SAMPLE_RATE

// 30 FPS
LATENCY_US :: 1_000_000 / 30

Audio_State :: struct {
	pcm:         alsa.Pcm,
	buffer_size: alsa.Pcm_Uframes,
	period_size: alsa.Pcm_Uframes,
}

Audio_Error :: enum {
	None = 0,
	Failed,
}

audio_init :: proc(state: ^Audio_State) -> Audio_Error {
	if err := alsa.pcm_open(&state.pcm, "default", .Playback, .Block); err != 0 {
		log.error("failed to open audio device:", alsa.strerror(err))
		return .Failed
	}

	if err := alsa.pcm_set_params(
		state.pcm,
		format = .S16,
		access = .MMAP_INTERLEAVED,
		channels = 2,
		rate = SAMPLE_RATE,
		soft_resample = .Enable,
		// TODO: Play around with buffer/period size
		latency = LATENCY_US * 2,
	); err != 0 {
		log.error("failed to configure audio device:", alsa.strerror(err))
		return .Failed
	}

	// TODO: Alignment?
	sw_params_buf := make([]u8, alsa.pcm_sw_params_sizeof(), context.temp_allocator)
	sw_params := (^alsa.Pcm_Sw_Params)(&sw_params_buf[0])
	// TODO: Error handling
	alsa.pcm_sw_params_current(state.pcm, sw_params)
	alsa.pcm_sw_params_set_start_threshold(state.pcm, sw_params, max(alsa.Pcm_Uframes))
	alsa.pcm_sw_params_set_stop_threshold(state.pcm, sw_params, 0)
	alsa.pcm_sw_params_set_silence_size(state.pcm, sw_params, SAMPLE_RATE)
	alsa.pcm_sw_params(state.pcm, sw_params)

	if err := alsa.pcm_get_params(state.pcm, &state.buffer_size, &state.period_size); err != 0 {
		log.error("failed to fetch configuration:", alsa.strerror(err))
		return .Failed
	}
	log.infof(
		"audio device config: buffer_size={} period_size={}",
		state.buffer_size,
		state.period_size,
	)

	// TODO: Is this necessary?
	if err := alsa.pcm_prepare(state.pcm); err != 0 {
		log.error("failed to prepare audio device:", alsa.strerror(err))
		return .Failed
	}

	return nil
}

get_audio_buffer :: proc(
	buffer_size: alsa.Pcm_Uframes,
	area: ^alsa.Pcm_Channel_Area,
	offset: alsa.Pcm_Uframes,
	space: alsa.Pcm_Uframes,
) -> (
	buf: []Audio_Frame,
	ok: bool,
) {
	// TODO: Add more generic Audio_Buffer type if first and step have padding
	// TODO: Just assert?
	if area.first != 0 {
		log.errorf("channel offset not byte-aligned: first_bits={}", area.first)
		return
	}
	if area.step != 8 * size_of(Audio_Frame) {
		log.errorf("channel offset not Frame: step_bits={}", area.step)
		return
	}

	// Make sure the API doesn't expect me to handle wrap-around
	assert(offset + space <= buffer_size)

	full_buffer := mem.slice_ptr((^Audio_Frame)(area.addr), int(buffer_size))
	return full_buffer[offset:][:space], true
}

audio_fill_buffer :: proc(state: ^State) -> Audio_Error {
	now_ns := get_perf_counter_wall_ns()
	next_frame_start_target_ns := state.display.last_frame_time_ns // + state.display.frame_rate_ns
	next_frame_end_target_ns := next_frame_start_target_ns + state.display.frame_rate_ns
	// TODO: Handle this case
	assert(now_ns < next_frame_start_target_ns)
	margin_ns := now_ns - state.display.last_frame_time_ns
	write_target_ns := next_frame_end_target_ns + margin_ns

	audio := &state.audio
	// Based on ALSA's PCM example:
	// https://www.alsa-project.org/alsa-doc/alsa-lib/_2test_2alsa.pcm_8c-example.html#example_test_pcm
	// Loop until "would block"
	audio_loop: for {
		need_start: bool
		#partial switch status := alsa.pcm_state(audio.pcm); status {
		case .STATE_RUNNING:
			need_start = false
		case .STATE_XRUN:
			log.warn("audio overrun")
			if err := alsa.pcm_recover(audio.pcm, -posix.EPIPE, alsa.PCM_RECOVER_VERBOSE);
			   err != 0 {
				log.error("failed to recover:", alsa.strerror(err))
				return .Failed
			}
			// TODO: Is this needed? ALSA's example does it, but it seems redundant to
			// re-check the status
			continue audio_loop
		case:
			need_start = true
		}

		avail: alsa.Pcm_Sframes
		delay: alsa.Pcm_Sframes
		if err := alsa.pcm_avail_delay(audio.pcm, &avail, &delay); err != 0 {
			if err := alsa.pcm_recover(audio.pcm, err, alsa.PCM_RECOVER_VERBOSE); err != 0 {
				log.error(
					"failed to update available space: failed to recover:",
					alsa.strerror(err),
				)
				return .Failed
			}
			continue
		}

		// Supposedly faster version that doesn't return delay
		// avail := alsa.pcm_avail_update(audio.pcm)
		// if avail < 0 {
		// 	if err := alsa.pcm_recover(audio.pcm, c.int(avail), alsa.PCM_RECOVER_VERBOSE);
		// 	   err != 0 {
		// 		log.error(
		// 			"failed to update available space: failed to recover:",
		// 			alsa.strerror(err),
		// 		)
		// 		return .Failed
		// 	}
		// 	continue
		// }

		if alsa.Pcm_Uframes(avail) < audio.period_size {
			// Wait for more data
			return nil
		}
		log.debugf("audio state: delay={}frames avail={}frames", delay, avail)

		// TODO: Repeat just this section if possible to avoid re-checking status?
		delay_ns := delay * 1_000_000_000 / SAMPLE_RATE
		write_timestamp_ns := now_ns + delay_ns
		// TODO: Handle when starting delay is past the next target

		log.debugf(
			"next={} next'={} now={} write={} target={}",
			f64(next_frame_start_target_ns - state.display.last_frame_time_ns) / 1_000_000.0,
			f64(next_frame_end_target_ns - state.display.last_frame_time_ns) / 1_000_000.0,
			f64(now_ns - state.display.last_frame_time_ns) / 1_000_000.0,
			f64(write_timestamp_ns - state.display.last_frame_time_ns) / 1_000_000.0,
			f64(write_target_ns - state.display.last_frame_time_ns) / 1_000_000.0,
		)

		if write_timestamp_ns >= next_frame_end_target_ns {
			return nil
		}

		write_dur_ns := write_target_ns - write_timestamp_ns
		target_write_frames := (write_dur_ns * SAMPLE_RATE / 1_000_000_000)

		area: [^]alsa.Pcm_Channel_Area // Multi-pointer for the API
		offset: alsa.Pcm_Uframes
		space := alsa.Pcm_Uframes(target_write_frames)
		if err := alsa.pcm_mmap_begin(audio.pcm, &area, &offset, &space); err != 0 {
			log.error("failed to lock mmap area:", alsa.strerror(err))
			return .Failed
		}

		frame_buf, ok := get_audio_buffer(audio.buffer_size, area, offset, space)
		if !ok do return .Failed

		game_render_audio(&state.game, frame_buf)

		if err := alsa.pcm_mmap_commit(audio.pcm, offset, space); err < 0 {
			log.error("failed to commit mmap area:", alsa.strerror(i32(err)))
			return .Failed
		} else if alsa.Pcm_Uframes(err) != space {
			log.warnf("short commit: expected={} got={}", space, err)
		}

		// Start after putting something in the buffer
		if need_start {
			if err := alsa.pcm_start(audio.pcm); err != 0 {
				log.error("failed to start audio device:", alsa.strerror(err))
				return .Failed
			}
		}
	}
}

audio_destroy :: proc(state: ^Audio_State) -> Audio_Error {
	if err := alsa.pcm_close(state.pcm); err != 0 {
		log.error("failed to close audio device:", alsa.strerror(err))
		return .Failed
	}
	return nil
}

audio_get_poll_descriptor_count :: proc(state: ^Audio_State) -> int {
	return int(alsa.pcm_poll_descriptors_count(state.pcm))
}

audio_get_poll_descriptors :: proc(state: ^Audio_State, pfds: []posix.pollfd) -> (ok: bool) {
	if res := alsa.pcm_poll_descriptors(state.pcm, &pfds[0], c.uint(len(pfds)));
	   res == c.int(len(pfds)) {
		return true
	} else if res < 0 {
		log.error("failed to get poll descriptors:", alsa.strerror(res))
		return false
	} else {
		log.warnf("got too few poll FDs: expected={} got={}", len(pfds), res)
		return true
	}
}

audio_handle_poll :: proc(state: ^State, pfds: []posix.pollfd) -> Audio_Error {
	revents: posix.Poll_Event
	if err := alsa.pcm_poll_descriptors_revents(
		state.audio.pcm,
		&pfds[0],
		c.uint(len(pfds)),
		&revents,
	); err != 0 {
		log.error("failed to get poll descriptor revents:", alsa.strerror(err))
		return .Failed
	}

	if .OUT in revents {
		// return audio_fill_buffer(state)
		return nil
	} else {
		return nil
	}
}

// Timers

get_perf_counter_wall_ns :: proc() -> i64 {
	t: posix.timespec
	if posix.clock_gettime(.MONOTONIC, &t) != .OK {
		return 0
	}
	return i64(t.tv_sec) * 1_000_000_000 + t.tv_nsec
}

get_perf_counter_cpu_ns :: proc() -> i64 {
	t: posix.timespec
	if posix.clock_gettime(.PROCESS_CPUTIME_ID, &t) != .OK {
		return 0
	}
	return i64(t.tv_sec) * 1_000_000_000 + t.tv_nsec
}

get_perf_counter_cpu_cycles :: intrinsics.read_cycle_counter
