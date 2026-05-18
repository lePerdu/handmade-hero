package platform_wayland

import platform ".."
import game_api "../../game/api"
import "../../vendor/wayland"
import "core:log"
import "core:math/fixed"
import "core:math/rand"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

// Video

State :: struct {
	using common: platform.Display_Common,
	conn: wayland.Connection,

	// Static IDs
	wl_display: wayland.Wl_Display,
	wl_registry: wayland.Wl_Registry,

	// Bound IDs from the registry
	wl_compositor: wayland.Wl_Compositor,
	wl_seat: wayland.Wl_Seat,
	wl_shm: wayland.Wl_Shm,
	xdg_wm_base: wayland.Xdg_Wm_Base,

	// SHM-related data (pointed is tracked in frame_buffer)
	shm_fd: posix.FD,
	shm_data: []byte,
	// TODO: Do these need to be persistend long-term?
	wl_shm_pool: wayland.Wl_Shm_Pool,

	// Window-related objects and data
	wl_surface: wayland.Wl_Surface,
	xdg_surface: wayland.Xdg_Surface,
	xdg_toplevel: wayland.Xdg_Toplevel,
	xdg_configure_serial: Maybe(u32),
	surface_state: Surface_State,
	close_requested: bool,
	buffers: [BUFFER_COUNT]Display_Buffer,
	// Index of the buffer which should be used to render the next frame
	back_buffer_index: int,

	// Window state changes buffered until the next xdg_surface.configure
	buffered_window_state: Window_State,
	current_window_state: Window_State,
	fullscreen_state: Fullscreen_State,

	// Keyboard
	wl_keyboard: wayland.Wl_Keyboard,
	// Keys that are only used for the engine, not passed to the game code
	engine_keyboard_input: [platform.Engine_Key]game_api.Button_Input,

	// Pointer
	wl_pointer: wayland.Wl_Pointer,

	// Frame state
	frame_callback: wayland.Wl_Callback,
	frame_rate_ns: i64,
	last_cb_time_ms: u32,
}

@(private)
BUFFER_COUNT :: 2

@(private)
Buffer_State :: enum {
	// Ready to render into
	Free,
	// In-use by the compositor and shouldn't be touched
	Attached,
}

@(private)
Display_Buffer :: struct {
	wl_buffer: wayland.Wl_Buffer,
	state: Buffer_State,
	frame_buffer: game_api.Frame_Buffer,
}

@(private)
COLOR_CHANNELS :: 4

@(private)
Surface_State :: enum {
	Initial = 0,
	Pending_Configure,
	Configured,
}

@(private)
Window_State :: struct {
	width, height: u32,
	fullscreen: bool,
}

@(private)
Fullscreen_State :: enum {
	Off = 0,
	Requested_On,
	Requested_Off,
	On,
}

init :: proc(state: ^State) -> bool {
	if err := wayland.connection_init(&state.conn); err != nil {
		log.fatal("failed to setup connection:", err)
		return false
	}

	// Guess initial value. Will be set more acurately later on from frame
	// callbacks
	state.frame_rate_ns = 1_000_000_000 / 30

	// Display is always the first ID
	state.wl_display, _ = wayland.connection_alloc_id(&state.conn)

	err: wayland.Conn_Error
	state.wl_registry, err = wayland.wl_display_get_registry(
		&state.conn,
		state.wl_display,
	)
	if err != nil {
		log.fatal("failed to setup wl_registry:", err)
		return false
	}

	// Initial setup event loop to bind to globals
	for state.wl_compositor == 0 ||
	    state.wl_shm == 0 ||
	    state.xdg_wm_base == 0 {
		wayland_socket_poll := posix.pollfd {
			fd = state.conn.socket_fd,
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
	}

	// Create window-related objects

	state.wl_surface, _ = wayland.wl_compositor_create_surface(
		&state.conn,
		state.wl_compositor,
	)
	state.xdg_surface, _ = wayland.xdg_wm_base_get_xdg_surface(
		&state.conn,
		state.xdg_wm_base,
		state.wl_surface,
	)
	state.xdg_toplevel, _ = wayland.xdg_surface_get_toplevel(
		&state.conn,
		state.xdg_surface,
	)
	_ = wayland.xdg_toplevel_set_title(
		&state.conn,
		state.xdg_toplevel,
		"Handmade",
	)
	_ = wayland.xdg_toplevel_set_app_id(
		&state.conn,
		state.xdg_toplevel,
		"lePerdu.handmade-hero",
	)
	_ = wayland.wl_surface_commit(&state.conn, state.wl_surface)

	// Prepare default settings, but don't use them until xdg_surface.configure
	state.current_window_state = {}
	state.buffered_window_state = {
		width = platform.DEFAULT_WINDOW_WIDTH,
		height = platform.DEFAULT_WINDOW_HEIGHT,
		fullscreen = false,
	}

	// Wait for xdg_surface.configure, so that the window is ready for rendering
	// TODO: Introduce a more explicit check? This relies on
	// `display_setup_buffers` being called in the `xdg_surface.configure`
	// handler
	for state.buffers[0].wl_buffer == wayland.OBJECT_ID_NIL {
		wayland_socket_poll := posix.pollfd {
			fd = state.conn.socket_fd,
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
	}

	return true
}

get_back_buffer :: proc(
	state: ^State,
) -> (
	fb: game_api.Frame_Buffer,
	ok: bool,
) {
	b := &state.buffers[state.back_buffer_index]
	if b.state == .Attached || b.wl_buffer == wayland.OBJECT_ID_NIL {
		return {}, false
	} else {
		return b.frame_buffer, true
	}
}

get_poll_descriptor :: proc(state: ^State) -> (poll: posix.pollfd, ok: bool) {
	return posix.pollfd {
			fd = state.conn.socket_fd,
			events = wayland.connection_needs_flush(&state.conn) ? {.IN, .OUT} : {.IN},
		},
		true
}

handle_poll :: proc(state: ^State, poll: ^posix.pollfd) -> (ok: bool) {
	if poll.revents & {.IN, .OUT} == {} {
		return true
	}
	process_wayland_messages(state)
	return true
}

// Submit the current frame, rendered in the back-buffer, and swap buffers to
// prepare for the next frame
submit_frame :: proc(state: ^State) {
	back_buffer := &state.buffers[state.back_buffer_index]

	wayland.wl_surface_attach(
		&state.conn,
		state.wl_surface,
		back_buffer.wl_buffer,
		0,
		0,
	)
	wayland.wl_surface_damage_buffer(
		&state.conn,
		state.wl_surface,
		0,
		0,
		max(i32),
		max(i32),
	)

	wayland.wl_surface_commit(&state.conn, state.wl_surface)
	back_buffer.state = .Attached

	state.back_buffer_index = (state.back_buffer_index + 1) % BUFFER_COUNT
}

submit_first_frame :: proc(state: ^State) {
	state.last_frame_time_ns = get_perf_counter_wall_ns()
	request_frame_callback(state)
	submit_frame(state)
}

toggle_fullscreen :: proc(state: ^State) {
	switch (state.fullscreen_state) {
	case .Off, .Requested_On:
		_ = wayland.xdg_toplevel_set_fullscreen(
			&state.conn,
			state.xdg_toplevel,
			wayland.OBJECT_ID_NIL,
		)
		state.fullscreen_state = .Requested_On
	case .On, .Requested_Off:
		_ = wayland.xdg_toplevel_unset_fullscreen(
			&state.conn,
			state.xdg_toplevel,
		)
		state.fullscreen_state = .Requested_Off
	}
}

//
// Private functions
//

@(private)
setup_buffers :: proc(state: ^State) {
	width := state.current_window_state.width
	height := state.current_window_state.height
	stride := width * COLOR_CHANNELS
	buffer_size := stride * height

	log.infof("allocate display buffers: {}x{}", width, height)

	// Free current allocations
	// TODO: Re-use current SHM allocation when possible
	// TODO: Look into wl_shm_pool_resize when growing the pool

	for buf in state.buffers {
		if buf.wl_buffer != wayland.OBJECT_ID_NIL {
			// TODO: Should destroying the buffer wait until the buffer is released?
			// That could get tricky since events are async...
			// Maybe a handle doesn't have to be tracked, since the server will
			// send a `wl_buffer.release` event?
			_ = wayland.wl_buffer_destroy(&state.conn, buf.wl_buffer)
		}
	}
	if state.wl_shm_pool != wayland.OBJECT_ID_NIL {
		_ = wayland.wl_shm_pool_destroy(&state.conn, state.wl_shm_pool)
	}
	destroy_shm_mapping(state.shm_fd, state.shm_data)

	shm_err: Shm_Error
	shm_data: []byte
	state.shm_fd, state.shm_data, shm_err = create_shm_file(
		BUFFER_COUNT * uint(buffer_size),
	)
	if shm_err != nil {
		log.fatal("failed to create SHM file:", posix.strerror())
		return
	}

	state.wl_shm_pool, _ = wayland.wl_shm_create_pool(
		&state.conn,
		state.wl_shm,
		state.shm_fd,
		i32(len(state.shm_data)),
	)
	for &buf, i in state.buffers {
		offset := i * int(buffer_size)
		buf.frame_buffer.width = width
		buf.frame_buffer.height = height
		buf.frame_buffer.stride = stride
		buf.frame_buffer.pixels = &state.shm_data[offset]

		buf.wl_buffer, _ = wayland.wl_shm_pool_create_buffer(
			&state.conn,
			state.wl_shm_pool,
			offset = i32(offset),
			width = i32(width),
			height = i32(height),
			stride = i32(stride),
			format = .Xrgb8888,
		)
		buf.state = .Free
	}

	state.back_buffer_index = 0

	// Attach one of the new, valid buffers, but don't commit yet since the buffer isn't written
	// TODO: Will this result in blank frames when resizing?
	_ = wayland.wl_surface_attach(
		&state.conn,
		state.wl_surface,
		state.buffers[state.back_buffer_index].wl_buffer,
		0,
		0,
	)
}

@(private)
process_wayland_messages :: proc(state: ^State) {
	// Whether the previous iteration processed any events (and hence, should re-flush outgoing messages)
	for processed_events := true; processed_events; {
		// Flush outgoing messages
		if !wayland.connection_flush(&state.conn) {
			log.error("failed to flush outgoing messages")
		}

		// Process all active messages
		processed_events = false
		for {
			if event, err := wayland.connection_next_event(&state.conn);
			   err == nil {
				processed_events = true
				handle_event(state, event)
			} else {
				break
			}
		}
	}
}

@(private)
handle_event :: proc(
	state: ^State,
	message: wayland.Message,
) -> wayland.Conn_Error {
	opcode := message.header.opcode
	switch message.header.target {
	case 0:
		log.error("received event for nil object ID:", message)
		return nil
	case state.wl_display:
		switch opcode {
		case wayland.WL_DISPLAY_ERROR_EVENT_OPCODE:
			event := wayland.wl_display_error_parse(
				&state.conn,
				message,
			) or_return
			handle_wl_display_error(state, event)
			return nil
		case wayland.WL_DISPLAY_DELETE_ID_EVENT_OPCODE:
			// Just parse for logging purposes for now
			// IDs are cleaned up in "destructor" calls currently, but maybe they should be cleaned up here?
			_ = wayland.wl_display_delete_id_parse(
				&state.conn,
				message,
			) or_return
			return nil
		}
	case state.wl_registry:
		switch opcode {
		case wayland.WL_REGISTRY_GLOBAL_EVENT_OPCODE:
			event := wayland.wl_registry_global_parse(
				&state.conn,
				message,
			) or_return
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
				wayland.wl_seat_capabilities_parse(
					&state.conn,
					message,
				) or_return,
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
				wayland.wl_keyboard_keymap_parse(
					&state.conn,
					message,
				) or_return,
			)
			return nil
		case wayland.WL_KEYBOARD_REPEAT_INFO_EVENT_OPCODE:
			handle_keyboard_reapeat_info(
				state,
				wayland.wl_keyboard_repeat_info_parse(
					&state.conn,
					message,
				) or_return,
			)
			return nil
		case wayland.WL_KEYBOARD_ENTER_EVENT_OPCODE:
			handle_keyboard_enter(
				state,
				wayland.wl_keyboard_enter_parse(
					&state.conn,
					message,
				) or_return,
			)
			return nil
		case wayland.WL_KEYBOARD_LEAVE_EVENT_OPCODE:
			handle_keyboard_leave(
				state,
				wayland.wl_keyboard_leave_parse(
					&state.conn,
					message,
				) or_return,
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
				wayland.wl_keyboard_modifiers_parse(
					&state.conn,
					message,
				) or_return,
			)
			return nil
		}
	case state.wl_pointer:
		switch opcode {
		case wayland.WL_POINTER_ENTER_EVENT_OPCODE:
			handle_pointer_enter(
				state,
				wayland.wl_pointer_enter_parse(&state.conn, message) or_return,
			)
			return nil
		case wayland.WL_POINTER_LEAVE_EVENT_OPCODE:
			handle_pointer_leave(
				state,
				wayland.wl_pointer_leave_parse(&state.conn, message) or_return,
			)
			return nil
		case wayland.WL_POINTER_MOTION_EVENT_OPCODE:
			handle_pointer_motion(
				state,
				wayland.wl_pointer_motion_parse(
					&state.conn,
					message,
				) or_return,
			)
			return nil
		case wayland.WL_POINTER_BUTTON_EVENT_OPCODE:
			handle_pointer_button(
				state,
				wayland.wl_pointer_button_parse(
					&state.conn,
					message,
				) or_return,
			)
			return nil
		case wayland.WL_POINTER_AXIS_EVENT_OPCODE:
			handle_pointer_axis(
				state,
				wayland.wl_pointer_axis_parse(&state.conn, message) or_return,
			)
			return nil
		case wayland.WL_POINTER_FRAME_EVENT_OPCODE:
			handle_pointer_frame(
				state,
				wayland.wl_pointer_frame_parse(&state.conn, message) or_return,
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
			_ = wayland.wl_surface_preferred_buffer_scale_parse(
				&state.conn,
				message,
			) or_return
			// TODO: Impl
			return nil
		case wayland.WL_SURFACE_PREFERRED_BUFFER_TRANSFORM_EVENT_OPCODE:
			_ = wayland.wl_surface_preferred_buffer_transform_parse(
				&state.conn,
				message,
			) or_return
			// TODO: Impl
			return nil
		}
	case state.xdg_surface:
		switch opcode {
		case wayland.XDG_SURFACE_CONFIGURE_EVENT_OPCODE:
			handle_xdg_surface_configure(
				state,
				wayland.xdg_surface_configure_parse(
					&state.conn,
					message,
				) or_return,
			)
			return nil
		}
	case state.xdg_toplevel:
		switch opcode {
		case wayland.XDG_TOPLEVEL_WM_CAPABILITIES_EVENT_OPCODE:
			handle_xdg_toplevel_wm_capabilities(
				state,
				wayland.xdg_toplevel_wm_capabilities_parse(
					&state.conn,
					message,
				) or_return,
			)
			return nil
		case wayland.XDG_TOPLEVEL_CLOSE_EVENT_OPCODE:
			handle_xdg_toplevel_close(
				state,
				wayland.xdg_toplevel_close_parse(
					&state.conn,
					message,
				) or_return,
			)
			return nil
		case wayland.XDG_TOPLEVEL_CONFIGURE_EVENT_OPCODE:
			handle_xdg_toplevel_configure(
				state,
				wayland.xdg_toplevel_configure_parse(
					&state.conn,
					message,
				) or_return,
			)
			return nil
		case wayland.XDG_TOPLEVEL_CONFIGURE_BOUNDS_EVENT_OPCODE:
			handle_xdg_toplevel_configure_bounds(
				state,
				wayland.xdg_toplevel_configure_bounds_parse(
					&state.conn,
					message,
				) or_return,
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
	for buf, i in state.buffers {
		if message.header.target == buf.wl_buffer {
			switch opcode {
			case wayland.WL_BUFFER_RELEASE_EVENT_OPCODE:
				handle_buffer_release(
					state,
					i,
					wayland.wl_buffer_release_parse(
						&state.conn,
						message,
					) or_return,
				)
				return nil
			}
		}
	}

	log.warnf(
		"<- unhandled message: target={} opcode={} size={}",
		message.header.target,
		message.header.opcode,
		message.header.size,
	)
	return nil
}

@(private)
handle_wl_display_error :: proc(
	state: ^State,
	event: wayland.Wl_Display_Error_Event,
) {
	log.errorf(
		"error from compositor: object_id={} code={} message={}",
		event.object_id,
		event.code,
		event.message,
	)
}

@(private)
handle_wl_registry_global :: proc(
	state: ^State,
	event: wayland.Wl_Registry_Global_Event,
) {
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

@(private)
handle_xdg_wm_base_ping :: proc(
	state: ^State,
	event: wayland.Xdg_Wm_Base_Ping_Event,
) {
	_ = wayland.xdg_wm_base_pong(&state.conn, state.xdg_wm_base, event.serial)
}

@(private)
handle_xdg_surface_configure :: proc(
	state: ^State,
	event: wayland.Xdg_Surface_Configure_Event,
) {
	// TODO: Remove field
	// state.xdg_configure_serial = event.serial

	// TODO: Only check the size for re-allocating buffers
	if state.buffered_window_state != state.current_window_state {
		state.current_window_state = state.buffered_window_state
		setup_buffers(state)

		state.fullscreen_state =
			state.current_window_state.fullscreen ? .On : .Off
	}

	_ = wayland.xdg_surface_ack_configure(
		&state.conn,
		state.xdg_surface,
		event.serial,
	)
}

@(private)
handle_xdg_toplevel_wm_capabilities :: proc(
	state: ^State,
	event: wayland.Xdg_Toplevel_Wm_Capabilities_Event,
) {
	// TODO: Handle
}

@(private)
handle_xdg_toplevel_configure :: proc(
	state: ^State,
	event: wayland.Xdg_Toplevel_Configure_Event,
) {
	toplevel_states := mem.slice_data_cast(
		[]wayland.Xdg_Toplevel_State_Enum,
		event.states,
	)
	log.debug("xdg_toplevel.configure: states={}", toplevel_states)
	is_fullscreen: bool
	for toplevel_state in toplevel_states {
		#partial switch toplevel_state {
		case .Fullscreen:
			is_fullscreen = true
		}
	}

	// Buffer window size/state until next xdg_surface_configure
	window_state := &state.buffered_window_state

	window_state.fullscreen = is_fullscreen
	// TODO: Check for negative
	if event.width != 0 {
		window_state.width = u32(event.width)
	}
	if event.height != 0 {
		window_state.height = u32(event.height)
	}
}

@(private)
handle_xdg_toplevel_configure_bounds :: proc(
	state: ^State,
	event: wayland.Xdg_Toplevel_Configure_Bounds_Event,
) {
	// TODO: Handle
}

@(private)
request_frame_callback :: proc(state: ^State) {
	if cb, err := wayland.wl_surface_frame(&state.conn, state.wl_surface);
	   err == nil {
		state.frame_callback = cb
	} else {
		log.errorf("frame request failed: {}", err)
	}
}

@(private)
handle_frame_callback :: proc(
	state: ^State,
	event: wayland.Wl_Callback_Done_Event,
) {
	request_frame_callback(state)

	// Use frame timestamps to calculate frame rate, but use local clock for
	// `last_frame_time_ns` since it needs to be compared with intra-frame
	// timestamps.
	// TODO: When using wp_presentation, the timestamp from the wayland server can
	// be used, since it also provides a clock ID that lets the client fetch
	// timestamps to comapre against the event timestamps.
	state.last_frame_time_ns = get_perf_counter_wall_ns()

	frame_time_ms := event.callback_data
	frame_dt_ms: u32
	if state.last_cb_time_ms == 0 {
		frame_dt_ms = 0
	} else {
		frame_dt_ms = frame_time_ms - state.last_cb_time_ms
	}
	log.debugf("frame flip: {}ms", frame_dt_ms)

	state.frame_rate_ns = i64(frame_dt_ms) * 1_000_000
	state.last_cb_time_ms = frame_time_ms
}

@(private)
handle_buffer_release :: proc(
	state: ^State,
	buffer_index: int,
	event: wayland.Wl_Buffer_Release_Event,
) {
	state.buffers[buffer_index].state = .Free
}

@(private)
handle_xdg_toplevel_close :: proc(
	state: ^State,
	event: wayland.Xdg_Toplevel_Close_Event,
) {
	state.close_requested = true
}

@(private)
handle_seat_capabilities :: proc(
	state: ^State,
	event: wayland.Wl_Seat_Capabilities_Event,
) {
	if .Keyboard in event.capabilities {
		state.wl_keyboard, _ = wayland.wl_seat_get_keyboard(
			&state.conn,
			state.wl_seat,
		)
	} else {
		log.error("wl_seat keyboard not available")
	}
	if .Pointer in event.capabilities {
		state.wl_pointer, _ = wayland.wl_seat_get_pointer(
			&state.conn,
			state.wl_seat,
		)
	} else {
		log.error("wl_seat pointer not available")
	}
}

@(private)
handle_keyboard_reapeat_info :: proc(
	state: ^State,
	event: wayland.Wl_Keyboard_Repeat_Info_Event,
) {
	// TODO: Handle?
}

@(private)
handle_keyboard_keymap :: proc(
	state: ^State,
	event: wayland.Wl_Keyboard_Keymap_Event,
) {
	// Don't care about the keymap for now
	if event.fd > 0 do posix.close(event.fd)
}

@(private)
scancode_to_game_key :: proc(code: u32) -> (game_api.Key, bool) {
	// TODO: Pull these (and others) from linux EVDEV header
	KEY_Q :: 16
	KEY_W :: 17
	KEY_E :: 18
	KEY_A :: 30
	KEY_S :: 31
	KEY_D :: 32

	KEY_UP :: 103
	KEY_LEFT :: 105
	KEY_DOWN :: 108
	KEY_RIGHT :: 106
	KEY_SPACE :: 57
	KEY_ENTER :: 28
	KEY_BACKSPACE :: 14
	KEY_TAB :: 15

	switch code {
	case KEY_Q:
		return .Q, true
	case KEY_W:
		return .W, true
	case KEY_E:
		return .E, true
	case KEY_A:
		return .A, true
	case KEY_S:
		return .S, true
	case KEY_D:
		return .D, true
	case KEY_UP:
		return .Up, true
	case KEY_LEFT:
		return .Left, true
	case KEY_DOWN:
		return .Down, true
	case KEY_RIGHT:
		return .Right, true
	case KEY_SPACE:
		return .Space, true
	case KEY_ENTER:
		return .Enter, true
	case KEY_BACKSPACE:
		return .Backspace, true
	case KEY_TAB:
		return .Tab, true
	case:
		return {}, false
	}
}

@(private)
scancode_to_engine_key :: proc(code: u32) -> (platform.Engine_Key, bool) {
	KEY_1 :: 2
	KEY_2 :: 3
	KEY_3 :: 4
	KEY_4 :: 5
	KEY_5 :: 6
	KEY_6 :: 7
	KEY_7 :: 8
	KEY_8 :: 9
	KEY_9 :: 10
	KEY_0 :: 11
	KEY_L :: 38
	KEY_P :: 25
	KEY_ESC :: 1
	KEY_F11 :: 87

	switch code {
	case KEY_1:
		return .Num_1, true
	case KEY_2:
		return .Num_2, true
	case KEY_3:
		return .Num_3, true
	case KEY_4:
		return .Num_4, true
	case KEY_5:
		return .Num_5, true
	case KEY_6:
		return .Num_6, true
	case KEY_7:
		return .Num_7, true
	case KEY_8:
		return .Num_8, true
	case KEY_9:
		return .Num_9, true
	case KEY_0:
		return .Num_0, true
	case KEY_L:
		return .L, true
	case KEY_P:
		return .P, true
	case KEY_ESC:
		return .Esc, true
	case KEY_F11:
		return .F11, true
	case:
		return {}, false
	}
}

@(private)
scancode_to_button :: proc(
	state: ^State,
	code: u32,
) -> (
	^game_api.Button_Input,
	bool,
) {
	if k, ok := scancode_to_game_key(code); ok {
		return &state.keyboard_input[k], true
	} else if k, ok := scancode_to_engine_key(code); ok {
		return &state.engine_keyboard_input[k], true
	} else {
		return nil, false
	}
}

@(private)
handle_keyboard_enter :: proc(
	state: ^State,
	event: wayland.Wl_Keyboard_Enter_Event,
) {
	scan_codes := mem.slice_data_cast([]u32, event.keys)
	for code in scan_codes {
		if b, ok := scancode_to_button(state, code); ok {
			game_api.button_input_update(b, pressed = true)
		}
	}
}

@(private)
handle_keyboard_leave :: proc(
	state: ^State,
	event: wayland.Wl_Keyboard_Leave_Event,
) {
	// Releasing all keys when un-focusing makes logic in `enter` easiest
	for &key in state.keyboard_input {
		game_api.button_input_update(&key, pressed = false)
	}
}

@(private)
handle_keyboard_key :: proc(
	state: ^State,
	event: wayland.Wl_Keyboard_Key_Event,
) {
	// TODO: Track event time?
	if b, ok := scancode_to_button(state, event.key); ok {
		game_api.button_input_update(b, pressed = event.state == .Pressed)
	}
}

@(private)
handle_keyboard_modifiers :: proc(
	state: ^State,
	event: wayland.Wl_Keyboard_Modifiers_Event,
) {}

@(private)
setup_pointer_cursor :: proc(state: ^State, event_serial: u32) {
	// Just hide for now
	// TODO: Custom cursor? Hide Wayland's cursor and draw in game code?
	wayland.wl_pointer_set_cursor(
		&state.conn,
		state.wl_pointer,
		event_serial,
		wayland.OBJECT_ID_NIL,
		0,
		0,
	)
}

@(private)
handle_pointer_enter :: proc(
	state: ^State,
	event: wayland.Wl_Pointer_Enter_Event,
) {
	setup_pointer_cursor(state, event.serial)
}

@(private)
handle_pointer_leave :: proc(
	state: ^State,
	event: wayland.Wl_Pointer_Leave_Event,
) {
}

@(private)
handle_pointer_motion :: proc(
	state: ^State,
	event: wayland.Wl_Pointer_Motion_Event,
) {
	state.mouse_input.pos_x = f32(fixed.to_f64(event.surface_x))
	state.mouse_input.pos_y = f32(fixed.to_f64(event.surface_y))
}

// From linux/input-event-codes.h
@(private)
BTN_LEFT :: 0x110
@(private)
BTN_RIGHT :: 0x111
@(private)
BTN_MIDDLE :: 0x112

@(private)
convert_pointer_button :: proc(button: u32) -> (game_api.Mouse_Button, bool) {
	switch button {
	case BTN_LEFT:
		return .Left, true
	case BTN_RIGHT:
		return .Right, true
	case BTN_MIDDLE:
		return .Middle, true
	case:
		return nil, false
	}
}

@(private)
handle_pointer_button :: proc(
	state: ^State,
	event: wayland.Wl_Pointer_Button_Event,
) {
	if btn, ok := convert_pointer_button(event.button); ok {
		game_api.button_input_update(
			&state.mouse_input.buttons[btn],
			event.state == .Pressed,
		)
	} else {
		log.debugf("unhandled pointer button: {}", event.button)
	}
}

@(private)
handle_pointer_axis :: proc(
	state: ^State,
	event: wayland.Wl_Pointer_Axis_Event,
) {
	// TODO: Handle scroll wheel?
}

@(private)
handle_pointer_frame :: proc(
	state: ^State,
	event: wayland.Wl_Pointer_Frame_Event,
) {
	// TODO: Does this need to do anything, like buffer input events in a frame?
}

@(private)
Shm_Error :: posix.Errno

@(private)
create_shm_file :: proc(
	size: uint,
) -> (
	shm_fd: posix.FD,
	shm_buf: []byte,
	err: Shm_Error,
) {
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

@(private)
destroy_shm_mapping :: proc(shm_fd: posix.FD, shm_buf: []byte) {
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

@(private)
get_perf_counter_wall_ns :: proc() -> i64 {
	t: posix.timespec
	if posix.clock_gettime(.MONOTONIC, &t) != .OK {
		return 0
	}
	return i64(t.tv_sec) * 1_000_000_000 + t.tv_nsec
}
