package main

import "base:intrinsics"
import "core:c"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

State :: struct {
	display: Display_State,
	audio:   Audio_State,
}

main :: proc() {
	context.logger = log.create_console_logger(lowest = .Info)

	state: State

	if !display_init(&state.display) do os.exit(1)

	if audio_init(&state.audio) != nil do os.exit(1)

	game_loop(&state)
}

game_loop :: proc(state: ^State) {
	last_frame_time: i64
	last_loop_ns: i64

	x_offset, y_offset: f32

	loop: for !state.display.close_requested {
		counter_start_wall_ns := get_perf_counter_wall_ns()
		counter_start_cpu_ns := get_perf_counter_cpu_ns()
		counter_start_cpu_cycles := get_perf_counter_cpu_cycles()

		// Fixed-capacity dynamic array
		// TODO: Use temp_allocator with intial size to avoid pre-allocating a "worst-case"?
		// NOTE: If that is changed, we can't take references to slices of the dynamic array for
		// use after polling, since it may have moved
		poll_fds_buf: [DISPLAY_POLL_FDS + AUDIO_MAX_POLL_FDS]posix.pollfd
		poll_fds := mem.buffer_from_slice(poll_fds_buf[:])

		append(&poll_fds, display_get_poll_descriptor(&state.display) or_break)
		display_poll := &poll_fds[0]

		// TODO: Don't break in case of audio-related failures to consider non-critital?
		// audio_nfds := audio_get_poll_descriptor_count(&state.audio) or_break
		// audio_poll := poll_fds[nfds:][:audio_nfds]
		// audio_get_poll_descriptors(&state.audio, audio_poll) or_break
		// nfds += audio_nfds
		audio_poll := audio_append_poll_descriptors(&state.audio, &poll_fds) or_break

		switch poll_res := posix.poll(&poll_fds[0], posix.nfds_t(len(poll_fds)), -1); poll_res {
		case 0:
			// timeout
			continue loop
		case -1:
			// error
			log.error("failed to poll for updates:", posix.errno())
			break loop
		}

		display_handle_poll(&state.display, display_poll) or_break

		// TODO: Figure out API for handling input
		// TODO: Figure out how to make the audio stream update "immediately"
		// I guess it needs to be "drop"ed and re-filled?
		state.audio.play_sound = state.display.key_states[.Space]

		frame_time := get_perf_counter_wall_ns()
		dt_ns := frame_time - last_frame_time
		last_frame_time = frame_time

		// rate=24p/s
		rate: f32 : 24.0
		x_rate: f32 = 0.0
		y_rate: f32 = 0.0

		// Use +=/-= so that pressing 2 directions at the same time cancels out
		if state.display.key_states[.W] || state.display.key_states[.UP] do y_rate += rate
		if state.display.key_states[.A] || state.display.key_states[.Left] do x_rate += rate
		if state.display.key_states[.S] || state.display.key_states[.Down] do y_rate -= rate
		if state.display.key_states[.D] || state.display.key_states[.Right] do x_rate -= rate
		x_offset += f32(dt_ns) * x_rate / 1_000_000_000.0
		y_offset += f32(dt_ns) * y_rate / 1_000_000_000.0

		game_render(state.display.frame_buffer, int(x_offset), int(y_offset))
		draw(&state.display)

		audio_handle_poll(&state.audio, audio_poll) or_break

		free_all(context.temp_allocator)

		counter_total_wall_ns := get_perf_counter_wall_ns() - counter_start_wall_ns
		counter_total_cpu_ns := get_perf_counter_cpu_ns() - counter_start_cpu_ns
		counter_total_cpu_cycles := get_perf_counter_cpu_cycles() - counter_start_cpu_cycles

		log.infof(
			"perf counter: wall={}ms  cpu={}ms  cycles={}K",
			counter_total_wall_ns / 1_000_000,
			counter_total_cpu_ns / 1_000_000,
			counter_total_cpu_cycles / 1_000_000,
		)
	}
}

// Video


import "vendor/wayland"

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

	// case state.frame_callback:
	// 	switch opcode {
	// 	case wayland.WL_CALLBACK_DONE_EVENT_OPCODE:
	// 		handle_frame_callback(
	// 			state,
	// 			wayland.wl_callback_done_parse(&state.conn, message) or_return,
	// 		)
	// 		return nil
	// 	}
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
	play_sound:  bool,
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
		latency = LATENCY_US,
	); err != 0 {
		log.error("failed to configure audio device:", alsa.strerror(err))
		return .Failed
	}

	if err := alsa.pcm_get_params(state.pcm, &state.buffer_size, &state.period_size); err != 0 {
		log.error("failed to fetch configuration:", alsa.strerror(err))
		return .Failed
	}
	log.debugf(
		"audio device config: buffer_size={} period_size={}",
		state.buffer_size,
		state.period_size,
	)

	// TODO: Is this necessary?
	// if err := alsa.pcm_prepare(state.pcm); err != 0 {
	// 	log.error("failed to prepare audio device:", alsa.strerror(err))
	// 	return .Failed
	// }

	// log.debug("prepared audio device: buf_size={} sbits={}", buf_size, sig_bits)
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

audio_fill_buffer :: proc(state: ^Audio_State) -> Audio_Error {
	// Loop until "would block"
	audio_loop: for {
		need_start: bool
		#partial switch status := alsa.pcm_state(state.pcm); status {
		case .STATE_RUNNING:
			need_start = false
		case .STATE_XRUN:
			if err := alsa.pcm_recover(state.pcm, -posix.EPIPE, alsa.PCM_RECOVER_VERBOSE);
			   err != 0 {
				log.error("failed to recover:", alsa.strerror(err))
				return .Failed
			}
			// TODO: Is this needed? ALSA's example does it, but it seems redundant
			// https://www.alsa-project.org/alsa-doc/alsa-lib/_2test_2alsa.pcm_8c-example.html#example_test_pcm
			continue audio_loop
		case:
			need_start = true
		}

		if avail := alsa.pcm_avail_update(state.pcm); avail < 0 {
			if err := alsa.pcm_recover(state.pcm, c.int(avail), alsa.PCM_RECOVER_VERBOSE);
			   err != 0 {
				log.error(
					"failed to update available space: failed to recover:",
					alsa.strerror(err),
				)
				return .Failed
			}
			continue
		} else if alsa.Pcm_Uframes(avail) < state.period_size {
			// Wait for more data
			return nil
		}

		// TODO: Repeat just this section if possible to avoid re-checking status?

		area: [^]alsa.Pcm_Channel_Area // Multi-pointer for the API
		offset: alsa.Pcm_Uframes
		space: alsa.Pcm_Uframes = state.buffer_size // TODO: Just request max(alsa.Pcm_Uframes)?
		if err := alsa.pcm_mmap_begin(state.pcm, &area, &offset, &space); err != 0 {
			log.error("failed to lock mmap area:", alsa.strerror(err))
			return .Failed
		}

		frame_buf, ok := get_audio_buffer(state.buffer_size, area, offset, space)
		if !ok do return .Failed

		game_render_audio(frame_buf, state.play_sound)

		if err := alsa.pcm_mmap_commit(state.pcm, offset, space); err < 0 {
			log.error("failed to commit mmap area:", alsa.strerror(i32(err)))
			return .Failed
		} else if alsa.Pcm_Uframes(err) != space {
			log.warnf("short commit: expected={} got={}", space, err)
		}

		// Start after putting something in the buffer
		if need_start {
			if err := alsa.pcm_start(state.pcm); err != 0 {
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

// Take from alsa-lib source:
// https://github.com/alsa-project/alsa-lib/blob/3a9771812405be210e760e4e6667f2c023fe82f4/src/pcm/pcm.c#L2974
AUDIO_MAX_POLL_FDS :: 15

audio_get_poll_descriptor_count :: proc(state: ^Audio_State) -> (n: int, ok: bool) {
	if res := alsa.pcm_poll_descriptors_count(state.pcm); res < 0 {
		log.error("failed to determine poll descriptor count:", alsa.strerror(res))
		return 0, false
	} else if res > AUDIO_MAX_POLL_FDS {
		log.errorf("too many poll descriptors (max={}): {}", AUDIO_MAX_POLL_FDS, res)
		return 0, false
	} else {
		return int(res), true
	}
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

audio_append_poll_descriptors :: proc(
	state: ^Audio_State,
	pfds: ^[dynamic]posix.pollfd,
) -> (
	audio_pfds: []posix.pollfd,
	ok: bool,
) {
	nfds := audio_get_poll_descriptor_count(state) or_return
	init_len := len(pfds)
	if err := resize(pfds, init_len + nfds); err != nil do return nil, false
	audio_pfds = pfds[:init_len][:nfds]
	audio_get_poll_descriptors(state, audio_pfds) or_return
	return audio_pfds, true
}

audio_handle_poll :: proc(state: ^Audio_State, pfds: []posix.pollfd) -> Audio_Error {
	revents: posix.Poll_Event
	if err := alsa.pcm_poll_descriptors_revents(state.pcm, &pfds[0], c.uint(len(pfds)), &revents);
	   err != 0 {
		log.error("failed to get poll descriptor revents:", alsa.strerror(err))
		return .Failed
	}

	if .OUT in revents {
		return audio_fill_buffer(state)
	}
	return nil
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
