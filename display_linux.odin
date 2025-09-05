package main

import "core:log"
import "core:math/rand"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

import "wayland"

DISPLAY_POLL_FDS :: 1

// Enum of the keys we care about
Key :: enum {
	W,
	A,
	S,
	D,
	UP,
	Left,
	Right,
	Down,
	Space,
	Esc,
}

Key_State :: bool

Display_State :: struct {
	game_ref:        ^Game_State,
	conn:            wayland.Connection,

	// Static IDs
	wl_display:      wayland.Wl_Display,
	wl_registry:     wayland.Wl_Registry,

	// Bound IDs from the registry
	wl_compositor:   wayland.Wl_Compositor,
	wl_seat:         wayland.Wl_Seat,
	wl_shm:          wayland.Wl_Shm,
	xdg_wm_base:     wayland.Xdg_Wm_Base,

	// SHM-related data (pointed is tracked in frame_buffer)
	shm_fd:          posix.FD,
	shm_data:        []u8,
	// TODO: Do these need to be persistend long-term?
	wl_shm_pool:     wayland.Wl_Shm_Pool,

	// Window-related objects and data
	wl_surface:      wayland.Wl_Surface,
	wl_buffer:       wayland.Wl_Buffer,
	xdg_surface:     wayland.Xdg_Surface,
	xdg_toplevel:    wayland.Xdg_Toplevel,
	surface_state:   Surface_State,
	close_requested: bool,

	// Input
	wl_keyboard:     wayland.Wl_Keyboard,
	// TODO: Use bit_array?
	key_states:      [Key]Key_State,

	// Frame state
	frame_buffer:    Frame_Buffer,
	frame_callback:  wayland.Wl_Callback,
	last_frame_time: u32,
	x_offset:        f32,
	y_offset:        f32,
}

COLOR_CHANNELS :: 4

Surface_State :: enum {
	Initial = 0,
	Pending_Configure,
	Configured,
}

display_init :: proc(state: ^Display_State, game_ref: ^Game_State) -> bool {
	state.game_ref = game_ref
	if err := wayland.connection_init(&state.conn); err != nil {
		log.fatal("failed to setup connection:", err)
		return false
	}

	// Display is always the first ID
	state.wl_display, _ = wayland.connection_alloc_id(&state.conn)

	err: wayland.Conn_Error
	state.wl_registry, err = wayland.wl_display_get_registry(&state.conn, state.wl_display)
	if err != nil {
		log.fatal("failed to setup wl_registry:", err)
		return false
	}

	// TODO: I guess this needs to be re-created when the window is?
	state.frame_buffer.width = 640
	state.frame_buffer.height = 480
	state.frame_buffer.stride = state.frame_buffer.width * COLOR_CHANNELS

	shm_err: Shm_Error
	shm_data: []u8
	state.shm_fd, state.shm_data, shm_err = create_shm_file(
		uint(state.frame_buffer.stride * state.frame_buffer.height),
	)
	if shm_err != nil {
		log.fatal("failed to create SHM file:", posix.strerror())
	}
	state.frame_buffer.base = &state.shm_data[0]

	render(state.game_ref, state.frame_buffer)

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

	// TODO: Resize pool/buffers when window is resized
	state.wl_shm_pool, _ = wayland.wl_shm_create_pool(
		&state.conn,
		state.wl_shm,
		state.shm_fd,
		i32(len(state.shm_data)),
	)
	// TODO: Setup double-buffering
	state.wl_buffer, _ = wayland.wl_shm_pool_create_buffer(
		&state.conn,
		state.wl_shm_pool,
		offset = 0,
		width = i32(state.frame_buffer.width),
		height = i32(state.frame_buffer.height),
		stride = i32(state.frame_buffer.stride),
		format = .Xrgb8888,
	)
	// TODO: Destroy wl_shm_pool after buffers are created
	_ = wayland.wl_surface_attach(&state.conn, state.wl_surface, state.wl_buffer, 0, 0)

	state.frame_callback, _ = wayland.wl_surface_frame(&state.conn, state.wl_surface)
	return true
}

display_get_poll_descriptor :: proc(state: ^Display_State) -> (poll: posix.pollfd, ok: bool) {
	return posix.pollfd {
			fd = state.conn.socket_fd,
			events = wayland.connection_needs_flush(&state.conn) ? {.IN, .OUT} : {.IN},
		},
		true
}

display_handle_poll :: proc(state: ^Display_State, poll: ^posix.pollfd) -> (ok: bool) {
	if poll.revents & {.IN, .OUT} == {} do return true
	process_wayland_messages(state)
	if state.key_states[.Esc] do state.close_requested = true
	return true
}

draw :: proc(state: ^Display_State) {
	wayland.wl_surface_damage_buffer(&state.conn, state.wl_surface, 0, 0, max(i32), max(i32))
	wayland.wl_surface_commit(&state.conn, state.wl_surface)
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

set_scan_code_state :: proc(state: ^Display_State, scan_code: u32, pressed: bool) {
	key: Maybe(Key) = nil
	switch scan_code {
	case KEY_W:
		key = .W
	case KEY_A:
		key = .A
	case KEY_S:
		key = .S
	case KEY_D:
		key = .D
	case KEY_UP:
		key = .UP
	case KEY_LEFT:
		key = .Left
	case KEY_DOWN:
		key = .Down
	case KEY_RIGHT:
		key = .Right
	case KEY_SPACE:
		key = .Space
	case KEY_ESC:
		key = .Esc
	}
	if k, ok := key.?; ok do state.key_states[k] = pressed
}

handle_keyboard_enter :: proc(state: ^Display_State, event: wayland.Wl_Keyboard_Enter_Event) {
	scan_codes := mem.slice_data_cast([]u32, event.keys)
	// Everything is un-pressed
	for _, index in state.key_states {
		state.key_states[index] = false
	}
	for code in scan_codes {
		set_scan_code_state(state, code, true)
	}
}

handle_keyboard_leave :: proc(state: ^Display_State, event: wayland.Wl_Keyboard_Leave_Event) {
	// TODO: Reset key states here isntead of in enter?
}

handle_keyboard_key :: proc(state: ^Display_State, event: wayland.Wl_Keyboard_Key_Event) {
	// TODO: Track event time?
	set_scan_code_state(state, event.key, event.state == .Pressed)
}

handle_keyboard_modifiers :: proc(
	state: ^Display_State,
	event: wayland.Wl_Keyboard_Modifiers_Event,
) {}

handle_frame_callback :: proc(state: ^Display_State, event: wayland.Wl_Callback_Done_Event) {
	state.frame_callback, _ = wayland.wl_surface_frame(&state.conn, state.wl_surface)

	// TODO: Cleanup callback, or can/should this be done in auto-generated code?
	frame_time := event.callback_data
	dt_ms := frame_time - state.last_frame_time
	state.last_frame_time = frame_time

	// rate=24px/sec
	rate: f32 = 24.0 / 1000.0
	x_rate: f32 = 0.0
	y_rate: f32 = 0.0

	// Use +=/-= so that pressing 2 directions at the same time cancels out
	if state.key_states[.W] || state.key_states[.UP] do y_rate += rate
	if state.key_states[.A] || state.key_states[.Left] do x_rate += rate
	if state.key_states[.S] || state.key_states[.Down] do y_rate -= rate
	if state.key_states[.D] || state.key_states[.Right] do x_rate -= rate
	state.x_offset += f32(dt_ms) * x_rate
	state.y_offset += f32(dt_ms) * y_rate

	render(state.game_ref, state.frame_buffer)
	draw(state)
}

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
