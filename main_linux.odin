package main

import "base:intrinsics"
import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/fixed"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

import game_api "game/api"

State :: struct {
	display: Display_State,
	audio: Audio_State,
	running: bool,
	paused: bool,
	game_memory: game_api.Memory,
	exec_dir: string,
	data_dir: string,
	dynlib_path: string,
	dynlib_load_mod_time: time.Time,
	game_symbols: game_api.Symbol_Table,
	recorder: Recorder,
}

Recorder :: struct {
	state: Record_State,
	index: int,
	playback_offset: int,
	playback_timestamp_ns: i64,
	recordings: [len(ENGINE_NUM_KEYS)]Recording,
}

Record_State :: enum {
	None = 0,
	Wait_Index,
	Recording,
	Playing,
}

INIT_RECORDING_FRAME_COUNT :: 10 * 30

Recording :: struct {
	game_mem_snapshot: []byte,
	frames: [dynamic]game_api.Input,
}

GAME_MEMORY_SIZE :: 1 << 20
GAME_TEMP_MEMORY_SIZE :: 1 << 30
// Fixed address, so that it's possible to save/restore game state across
// processes
// TODO: Change this for 32-bit platforms
GAME_PERSIST_MEM_ADDR: uintptr : 0x0000_1000_0000_0000

main :: proc() {
	context.logger = log.create_console_logger(lowest = .Info)

	state: State
	setup_paths(&state)

	TOTAL_MEM_SIZE :: GAME_MEMORY_SIZE + GAME_TEMP_MEMORY_SIZE
	if ptr, err := linux.mmap(
		GAME_PERSIST_MEM_ADDR,
		TOTAL_MEM_SIZE,
		{.READ, .WRITE},
		{.FIXED_NOREPLACE, .PRIVATE, .NORESERVE, .ANONYMOUS},
	); err == nil {
		block := mem.byte_slice(ptr, TOTAL_MEM_SIZE)
		state.game_memory.persistent = block[:GAME_MEMORY_SIZE]
		state.game_memory.temporary = block[GAME_MEMORY_SIZE:]
	} else {
		log.panic("failed to allocate game memory", err)
	}

	// Start with dummy symbols
	state.game_symbols = game_api.dummy_symbol_table

	reload_game_symbols(&state)

	if !display_init(&state.display) do os.exit(1)

	if audio_init(&state.audio) != nil do os.exit(1)

	game_loop(&state)
}

setup_paths :: proc(state: ^State) {
	if dir, err := os.get_executable_directory(context.allocator); err == nil {
		state.exec_dir = dir
	} else {
		log.panic("failed to get executable directory:", err)
	}

	if path, err := filepath.join(
		{state.exec_dir, "..", "data"},
		context.allocator,
	); err == nil {
		state.data_dir = path
	} else {
		log.panic("failed to get data directory:", err)
	}

	if path, err := filepath.join(
		{state.exec_dir, GAME_DYNLIB_PATH},
		context.allocator,
	); err == nil {
		state.dynlib_path = path
	} else {
		log.panic("failed to build dynlib path:", err)
	}
}

MIN_UPDATE_PERIOD_NS :: 1_000_000_000 / 30

GAME_DYNLIB_PATH :: "game.so"

reload_game_symbols :: proc(state: ^State) {
	mod_time, err := os.modification_time_by_path(state.dynlib_path)
	if err == nil {
		if time.diff(state.dynlib_load_mod_time, mod_time) == 0 {
			// Not modified
			return
		}
	} else {
		log.errorf(
			"failed to check dynamic library timestamp: {}: {}",
			state.dynlib_path,
			err,
		)
		return
	}

	if count, ok := dynlib.initialize_symbols(
		&state.game_symbols,
		state.dynlib_path,
		"handmade_game_",
	); ok {
		log.infof("reloaded dynamic library: {}", state.dynlib_path)
		// Only update the timestamp on successful load
		state.dynlib_load_mod_time = mod_time
	} else {
		log.errorf(
			"failed to load dynamic library: {}: {}",
			state.dynlib_path,
			dynlib.last_error(),
		)
		state.game_symbols = game_api.dummy_symbol_table
	}
}

game_loop :: proc(state: ^State) {
	poll_fds: []posix.pollfd
	display_poll_fd: ^posix.pollfd
	audio_poll_fds: []posix.pollfd
	{
		audio_poll_fd_count := audio_get_poll_descriptor_count(&state.audio)
		display_poll_fd_count := 1
		poll_fds = make(
			[]posix.pollfd,
			display_poll_fd_count + audio_poll_fd_count,
		)
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

	last_update_time_ns: i64 = get_perf_counter_cpu_ns()
	last_render_time_ns: i64

	if fb, ok := display_get_back_buffer(&state.display); ok {
		state.game_symbols.render(state.game_memory, fb)
		last_render_time_ns = get_perf_counter_wall_ns()
		display_submit_first_frame(&state.display)
	} else {
		log.error(
			"back buffer not ready for initial rendering:",
			state.display.buffers[state.display.back_buffer_index].wl_buffer,
		)
		return
	}

	state.running = true
	for state.running && !state.display.close_requested {
		free_all(context.temp_allocator)

		reload_game_symbols(state)

		if poll_fd, ok := display_get_poll_descriptor(&state.display); ok {
			display_poll_fd^ = poll_fd
		} else {
			log.error("failed to setup display file descriptors")
			return
		}

		// Set timeout at next simulation frame boundary in case there are no
		// display/audio events to process
		next_update_time_ns := last_update_time_ns + MIN_UPDATE_PERIOD_NS
		max_wait_time_ms := i32(
			max(next_update_time_ns - get_perf_counter_cpu_ns(), 0) /
			1_000_000,
		)
		if poll_res := posix.poll(
			&poll_fds[0],
			posix.nfds_t(len(poll_fds)),
			max_wait_time_ms,
		); poll_res == -1 {
			// error
			log.error("failed to poll for updates:", posix.errno())
			return
		}

		display_handle_poll(&state.display, display_poll_fd) or_break

		handle_engine_input(state)

		if state.paused {
			continue
		}

		// Game update/render code

		if state.recorder.state == .Playing {
			for {
				input_frame := playback_peek_frame(state)

				next_update_time_ns = last_update_time_ns + input_frame.dt_ns
				if now := get_perf_counter_wall_ns();
				   now >= next_update_time_ns {
					state.game_symbols.update(state.game_memory, input_frame)
					playback_advance_frame(state)
					last_update_time_ns = now
				} else {
					break
				}
			}
		} else {
			// TODO: Simulate at fixed DT? Would require running this potentially
			// multiple times if the render loop takes longer than MIN_UPDATE_PERIOD_NS
			if now := get_perf_counter_wall_ns(); now >= next_update_time_ns {
				input := game_api.Input {
					dt_ns = now - last_update_time_ns,
					keyboard = state.display.keyboard_input,
					mouse = state.display.mouse_input,
				}
				record_input_frame(&state.recorder, input)
				state.game_symbols.update(state.game_memory, input)
				reset_game_input(state)
				last_update_time_ns = now
			}
		}

		// Only render after the previous frame is presented
		// TODO: Render at a fixed rate even if some frames won't be presented?
		if state.display.last_frame_time_ns > last_render_time_ns {
			if fb, ok := display_get_back_buffer(&state.display); ok {
				state.game_symbols.render(state.game_memory, fb)
				last_render_time_ns = get_perf_counter_wall_ns()
				// TODO: Fix/remove time for first frame, since it is incorrect
				log.debugf(
					"render time: {}ms",
					f64(
						last_render_time_ns - state.display.last_frame_time_ns,
					) /
					1_000_000.0,
				)
				display_submit_frame(&state.display)
			} else {
				log.warn(
					"back buffer not ready for rendering:",
					state.display.buffers[state.display.back_buffer_index].wl_buffer,
				)
			}
		}

		audio_handle_poll(state, audio_poll_fds) or_break
	}
}

reset_game_input :: proc(state: ^State) {
	game_api.keyboard_input_reset(&state.display.keyboard_input)
	game_api.mouse_input_reset(&state.display.mouse_input)
}

handle_engine_input :: proc(state: ^State) {
	// Handle engine control inputs
	if game_api.button_input_pressed(
		state.display.engine_keyboard_input[.Esc],
	) {
		state.running = false
		return
	}
	if game_api.button_input_toggled(state.display.engine_keyboard_input[.P]) {
		if state.paused {
			state.paused = false
			audio_resume(&state.audio)
			reset_game_input(state)
		} else {
			state.paused = true
			audio_pause(&state.audio)
		}
	}
	if game_api.button_input_toggled(state.display.engine_keyboard_input[.L]) {
		record_toggle(state)
	}
	for k, index in ENGINE_NUM_KEYS {
		if game_api.button_input_pressed(
			state.display.engine_keyboard_input[k],
		) {
			record_select_index(state, index)
			break
		}
	}
	game_api.keyboard_input_reset(&state.display.engine_keyboard_input)
}

record_toggle :: proc(state: ^State) {
	recorder := &state.recorder
	switch recorder.state {
	case .None:
		recorder.state = .Wait_Index
	case .Recording:
		record_end(state)
		playback_begin(state, recorder.index)
	case .Playing:
		playback_end(state)
	case .Wait_Index:
		log.infof("cancel recording")
		recorder.state = .None
	}
}

record_select_index :: proc(state: ^State, index: int) {
	recorder := &state.recorder
	#partial switch recorder.state {
	case .Wait_Index:
		record_begin(state, index)
	case .None:
		playback_begin(state, index)
	case .Recording: // No-op?
	}
}

record_input_frame :: proc(recorder: ^Recorder, input: game_api.Input) {
	if recorder.state != .Recording do return
	_, err := append(&recorder.recordings[recorder.index].frames, input)
	assert(err == nil)
}

record_begin :: proc(state: ^State, index: int) {
	log.infof("start recording #{}", index)
	recorder := &state.recorder
	recorder.index = index
	recorder.state = .Recording
	rec := &recorder.recordings[recorder.index]
	recording_destroy(rec)
	rec^ = {
		game_mem_snapshot = slice.clone(state.game_memory.persistent),
		frames = make([dynamic]game_api.Input, 0, INIT_RECORDING_FRAME_COUNT),
	}
}

record_end :: proc(state: ^State) {
	assert(state.recorder.state == .Recording)
	log.infof("stop recording #{}", state.recorder.index)
	state.recorder.state = .None

	if ok := save_recording(
		state.data_dir,
		state.recorder.index,
		state.recorder.recordings[state.recorder.index],
	); ok {
		log.infof("saved recording #{} to disk", state.recorder.index)
	}
}

playback_begin :: proc(state: ^State, index: int) {
	recorder := &state.recorder
	rec := &recorder.recordings[index]

	// TODO: Prefer in-memory copy or the one on disk?
	if loaded, ok := load_recording(state.data_dir, index); ok {
		log.infof("loaded recording #{} from disk", index)
		recording_destroy(rec)
		rec^ = loaded
	} else if rec.frames == nil || rec.game_mem_snapshot == nil {
		log.warnf(
			"cannot start playback #{}: " +
			"recording not initialized and not found on disk",
			index,
		)
		return
	}

	log.infof("start playback #{}", index)
	recorder.index = index
	recorder.state = .Playing
	recorder.playback_offset = 0
	copy(state.game_memory.persistent, rec.game_mem_snapshot)
}

playback_end :: proc(state: ^State) {
	assert(state.recorder.state == .Playing)
	log.infof("stop playback #{}", state.recorder.index)
	state.recorder.state = .None
	reset_game_input(state)
}

playback_peek_frame :: proc(state: ^State) -> game_api.Input {
	recorder := &state.recorder
	assert(recorder.state == .Playing)
	rec := recorder.recordings[recorder.index]
	return rec.frames[recorder.playback_offset]
}

playback_advance_frame :: proc(state: ^State) {
	recorder := &state.recorder
	assert(recorder.state == .Playing)
	recorder.playback_offset += 1

	rec := recorder.recordings[recorder.index]
	if recorder.playback_offset >= len(rec.frames) {
		log.infof("loop playback #{}", recorder.index)
		recorder.playback_offset = 0
		copy(state.game_memory.persistent, rec.game_mem_snapshot)
	}
}

save_recording :: proc(
	data_dir: string,
	index: int,
	rec: Recording,
) -> (
	ok: bool,
) {
	// TODO: Use mmap'd files instead of manual serializing?

	LOG_PREFIX :: "cannot save recording: "
	err: os.Error
	if !os.exists(data_dir) {
		if err = os.make_directory_all(data_dir); err != nil {
			log.error(LOG_PREFIX + "failed to create data directory:", err)
			return
		}
	}

	file_path: string
	if file_path, err = get_recording_file_path(data_dir, index); err != nil {
		log.error(LOG_PREFIX + "failed to build file path:", err)
		return
	}

	file: ^os.File
	if file, err = os.create(file_path); err != nil {
		log.error(LOG_PREFIX + "failed to create file:", err)
		return
	}
	defer os.close(file)

	// Might as well reserve the size first
	total_size := len(rec.game_mem_snapshot) + slice.size(rec.frames[:])
	if err = os.truncate(file, i64(total_size)); err != nil {
		log.error(LOG_PREFIX + "failed to set file size:", err)
		return
	}

	// TODO: Write some metadata in the file so that the parser can detect when
	// the game memory size / input frame size changes
	if _, err = os.write(file, rec.game_mem_snapshot); err != nil {
		log.error(LOG_PREFIX + "failed to write game memory:", err)
		return
	}
	if _, err = os.write_slice(file, rec.frames[:]); err != nil {
		log.error(LOG_PREFIX + "failed to write input frames:", err)
		return
	}
	end_pos: i64
	if end_pos, err = os.seek(file, 0, .Current); err != nil {
		end_pos = 0
	}
	if end_pos != i64(total_size) {
		log.error(
			LOG_PREFIX + "unexpected file size: expected={} actual={}",
			total_size,
			end_pos,
		)
		return
	}

	ok = true
	return
}

load_recording :: proc(
	data_dir: string,
	index: int,
) -> (
	rec: Recording,
	ok: bool,
) {
	LOG_PREFIX :: "cannot load recording: "
	err: os.Error

	file_path: string
	if file_path, err = get_recording_file_path(data_dir, index); err != nil {
		log.error(LOG_PREFIX + "failed to build file path:", err)
		return
	}

	file: ^os.File
	if file, err = os.open(file_path); err != nil {
		return
	}
	defer os.close(file)

	total_size: i64
	if total_size, err = os.file_size(file); err != nil {
		total_size = 0
	}

	if total_size < GAME_MEMORY_SIZE {
		log.warnf(
			LOG_PREFIX + "file too small: expected>={}, got={}",
			GAME_MEMORY_SIZE,
			total_size,
		)
		return
	}

	frames_size := total_size - GAME_MEMORY_SIZE
	if frames_size % size_of(game_api.Input) != 0 {
		log.warnf(
			LOG_PREFIX +
			"file size not aligned to input frames: total={} frames={}",
			total_size,
			frames_size,
		)
		return
	}
	frames_len := int(frames_size / size_of(game_api.Input))

	rec.game_mem_snapshot = make([]byte, GAME_MEMORY_SIZE)
	rec.frames = make([dynamic]game_api.Input, frames_len)
	// These should be freed on failure to avoid leaking memory

	if _, err = os.read(file, rec.game_mem_snapshot); err != nil {
		log.error(LOG_PREFIX + "failed to read game memory:", err)
		recording_destroy(&rec)
		return
	}
	if _, err = os.read_slice(file, rec.frames[:]); err != nil {
		log.error(LOG_PREFIX + "failed to read input frames:", err)
		recording_destroy(&rec)
		return
	}

	ok = true
	return
}

get_recording_file_path :: proc(
	data_dir: string,
	index: int,
) -> (
	path: string,
	err: os.Error,
) {
	file_name := fmt.tprintf("input_recording_{}.hmi", index)
	return filepath.join({data_dir, file_name}, context.temp_allocator)
}

recording_destroy :: proc(rec: ^Recording) {
	delete(rec.game_mem_snapshot)
	delete(rec.frames)
	rec^ = {}
}

// Video

import "vendor/wayland"

BUFFER_COUNT :: 2

Buffer_State :: enum {
	// Ready to render into
	Free,
	// In-use by the compositor and shouldn't be touched
	Attached,
}

Display_Buffer :: struct {
	wl_buffer: wayland.Wl_Buffer,
	state: Buffer_State,
	frame_buffer: game_api.Frame_Buffer,
}

Engine_Key :: enum {
	P,
	L,
	Esc,
	Num_0,
	Num_1,
	Num_2,
	Num_3,
	Num_4,
	Num_5,
	Num_6,
	Num_7,
	Num_8,
	Num_9,
}

ENGINE_NUM_KEYS :: [?]Engine_Key {
	.Num_0,
	.Num_1,
	.Num_2,
	.Num_3,
	.Num_4,
	.Num_5,
	.Num_6,
	.Num_7,
	.Num_8,
	.Num_9,
}

Display_State :: struct {
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

	// Keyboard
	wl_keyboard: wayland.Wl_Keyboard,
	// Keys that are only used for the engine, not passed to the game code
	engine_keyboard_input: [Engine_Key]game_api.Button_Input,

	// Pointer
	wl_pointer: wayland.Wl_Pointer,

	// Input events buffered since the last update.
	keyboard_input: game_api.Keyboard_Input,
	mouse_input: game_api.Mouse_Input,

	// Frame state
	frame_callback: wayland.Wl_Callback,
	frame_rate_ns: i64,
	last_frame_time_ns: i64,
	last_cb_time_ms: u32,
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
	_ = wayland.wl_surface_commit(&state.conn, state.wl_surface)

	display_setup_buffers(state, 960, 540)

	return true
}

display_setup_buffers :: proc(state: ^Display_State, width, height: u32) {
	stride := width * COLOR_CHANNELS
	buffer_size := stride * height

	// Free current allocations
	// TODO: Re-use current SHM allocation when possible
	// TODO: Look into wl_shm_pool_resize when growing the pool

	for buf in state.buffers {
		if buf.wl_buffer != wayland.OBJECT_ID_NIL {
			// TODO: Should destroying the buffer wait until the buffer is released?
			// That could get tricky since events are async...
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
		buf.frame_buffer.base = &state.shm_data[offset]

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

display_get_back_buffer :: proc(
	state: ^Display_State,
) -> (
	fb: game_api.Frame_Buffer,
	ok: bool,
) {
	b := &state.buffers[state.back_buffer_index]
	if b.state == .Attached {
		return {}, false
	} else {
		return b.frame_buffer, true
	}
}

display_get_poll_descriptor :: proc(
	state: ^Display_State,
) -> (
	poll: posix.pollfd,
	ok: bool,
) {
	return posix.pollfd {
			fd = state.conn.socket_fd,
			events = wayland.connection_needs_flush(&state.conn) ? {.IN, .OUT} : {.IN},
		},
		true
}

display_handle_poll :: proc(
	state: ^Display_State,
	poll: ^posix.pollfd,
) -> (
	ok: bool,
) {
	if poll.revents & {.IN, .OUT} == {} {
		return true
	}
	process_wayland_messages(state)
	return true
}

// Submit the current frame, rendered in the back-buffer, and swap buffers to
// prepare for the next frame
display_submit_frame :: proc(state: ^Display_State) {
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

	if serial, ok := state.xdg_configure_serial.?; ok {
		_ = wayland.xdg_surface_ack_configure(
			&state.conn,
			state.xdg_surface,
			serial,
		)
		state.xdg_configure_serial = nil
	}
	wayland.wl_surface_commit(&state.conn, state.wl_surface)
	back_buffer.state = .Attached

	state.back_buffer_index = (state.back_buffer_index + 1) % BUFFER_COUNT
}

display_submit_first_frame :: proc(state: ^Display_State) {
	state.last_frame_time_ns = get_perf_counter_wall_ns()
	request_frame_callback(state)
	display_submit_frame(state)
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

handle_event :: proc(
	state: ^Display_State,
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

	log.debugf(
		"<- unhandled message: target={} opcode={} size={}",
		message.header.target,
		message.header.opcode,
		message.header.size,
	)
	return nil
}

handle_wl_display_error :: proc(
	state: ^Display_State,
	event: wayland.Wl_Display_Error_Event,
) {
	log.errorf(
		"error from compositor: object_id={} code={} message={}",
		event.object_id,
		event.code,
		event.message,
	)
}

handle_wl_registry_global :: proc(
	state: ^Display_State,
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

handle_xdg_wm_base_ping :: proc(
	state: ^Display_State,
	event: wayland.Xdg_Wm_Base_Ping_Event,
) {
	_ = wayland.xdg_wm_base_pong(&state.conn, state.xdg_wm_base, event.serial)
}

handle_xdg_surface_configure :: proc(
	state: ^Display_State,
	event: wayland.Xdg_Surface_Configure_Event,
) {
	state.xdg_configure_serial = event.serial
}

handle_xdg_toplevel_configure :: proc(
	state: ^Display_State,
	event: wayland.Xdg_Toplevel_Configure_Event,
) {
	states := mem.slice_data_cast(
		[]wayland.Xdg_Toplevel_State_Enum,
		event.states,
	)
	log.debug("xdg_toplevel.configure: states={}", states)
	// TODO: Actually handle the requests
}

request_frame_callback :: proc(state: ^Display_State) {
	if cb, err := wayland.wl_surface_frame(&state.conn, state.wl_surface);
	   err == nil {
		state.frame_callback = cb
	} else {
		log.errorf("frame request failed: {}", err)
	}
}

handle_frame_callback :: proc(
	state: ^Display_State,
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

handle_buffer_release :: proc(
	state: ^Display_State,
	buffer_index: int,
	event: wayland.Wl_Buffer_Release_Event,
) {
	state.buffers[buffer_index].state = .Free
}

handle_xdg_toplevel_close :: proc(
	state: ^Display_State,
	event: wayland.Xdg_Toplevel_Close_Event,
) {
	state.close_requested = true
}

handle_seat_capabilities :: proc(
	state: ^Display_State,
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

handle_keyboard_keymap :: proc(
	state: ^Display_State,
	event: wayland.Wl_Keyboard_Keymap_Event,
) {
	// Don't care about the keymap for now
	if event.fd > 0 do posix.close(event.fd)
}

scancode_to_game_key :: proc(code: u32) -> (game_api.Key, bool) {
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
		return .Up, true
	case KEY_LEFT:
		return .Left, true
	case KEY_DOWN:
		return .Down, true
	case KEY_RIGHT:
		return .Right, true
	case KEY_SPACE:
		return .Space, true
	case:
		return {}, false
	}
}

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

scancode_to_engine_key :: proc(code: u32) -> (Engine_Key, bool) {
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
	case:
		return {}, false
	}
}

scancode_to_button :: proc(
	state: ^Display_State,
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

handle_keyboard_enter :: proc(
	state: ^Display_State,
	event: wayland.Wl_Keyboard_Enter_Event,
) {
	scan_codes := mem.slice_data_cast([]u32, event.keys)
	for code in scan_codes {
		if b, ok := scancode_to_button(state, code); ok {
			game_api.button_input_update(b, pressed = true)
		}
	}
}

handle_keyboard_leave :: proc(
	state: ^Display_State,
	event: wayland.Wl_Keyboard_Leave_Event,
) {
	// Releasing all keys when un-focusing makes logic in `enter` easiest
	for &key in state.keyboard_input {
		game_api.button_input_update(&key, pressed = false)
	}
}

handle_keyboard_key :: proc(
	state: ^Display_State,
	event: wayland.Wl_Keyboard_Key_Event,
) {
	// TODO: Track event time?
	if b, ok := scancode_to_button(state, event.key); ok {
		game_api.button_input_update(b, pressed = event.state == .Pressed)
	}
}

handle_keyboard_modifiers :: proc(
	state: ^Display_State,
	event: wayland.Wl_Keyboard_Modifiers_Event,
) {}

setup_pointer_cursor :: proc(state: ^Display_State, event_serial: u32) {
	// TODO: Custom cursor? Hide Wayland's cursor and draw in game code?
}

handle_pointer_enter :: proc(
	state: ^Display_State,
	event: wayland.Wl_Pointer_Enter_Event,
) {
	setup_pointer_cursor(state, event.serial)
}

handle_pointer_leave :: proc(
	state: ^Display_State,
	event: wayland.Wl_Pointer_Leave_Event,
) {
}

handle_pointer_motion :: proc(
	state: ^Display_State,
	event: wayland.Wl_Pointer_Motion_Event,
) {
	state.mouse_input.pos_x = f32(fixed.to_f64(event.surface_x))
	state.mouse_input.pos_y = f32(fixed.to_f64(event.surface_y))
}

// From linux/input-event-codes.h
BTN_LEFT :: 0x110
BTN_RIGHT :: 0x111
BTN_MIDDLE :: 0x112

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

handle_pointer_button :: proc(
	state: ^Display_State,
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

handle_pointer_axis :: proc(
	state: ^Display_State,
	event: wayland.Wl_Pointer_Axis_Event,
) {
	// TODO: Handle scroll wheel?
}

handle_pointer_frame :: proc(
	state: ^Display_State,
	event: wayland.Wl_Pointer_Frame_Event,
) {
	// TODO: Does this need to do anything, like buffer input events in a frame?
}

Shm_Error :: posix.Errno

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

// Audio

import "vendor/alsa"

Alsa_Config :: struct {
	device: cstring,
	access_mode: alsa.Pcm_Access,
}

PULSEAUDIO_CONFIG :: Alsa_Config {
	device = "pulse",
	access_mode = .RW_INTERLEAVED,
}

DEFAULT_MMAP_CONFIG :: Alsa_Config {
	device = "default",
	access_mode = .MMAP_INTERLEAVED,
}

// Using "default" or "pipewire" leads to buzzing sound and blocks system
// audio while paused in the debugger. Pulse audio forces using
// RW_INTERLEAVED, but that's alright for now
ALSA_CONFIG :: PULSEAUDIO_CONFIG

when ALSA_CONFIG.access_mode == .RW_INTERLEAVED {
	_Audio_Buffer_Field :: []game_api.Audio_Frame
} else {
	_Audio_Buffer_Field :: struct {}
}

Audio_State :: struct {
	config: Alsa_Config,
	pcm: alsa.Pcm,
	buffer_size: alsa.Pcm_Uframes,
	period_size: alsa.Pcm_Uframes,
	buffer: _Audio_Buffer_Field,
	sample_rate: uint,
	supports_pause: bool,
}

Audio_Error :: enum {
	None = 0,
	Failed,
}

audio_init :: proc(state: ^Audio_State) -> Audio_Error {
	if err := alsa.pcm_open(
		&state.pcm,
		ALSA_CONFIG.device,
		.Playback,
		.Nonblock,
	); err != 0 {
		log.error("failed to open audio device:", alsa.strerror(err))
		return .Failed
	}

	TARGET_SAMPLE_RATE :: 48000
	TARGET_FRAME_US :: 1_000_000 / 30

	// TODO: Error handling
	// TODO: Alignment?
	hw_params := alsa.pcm_hw_params_alloc(context.temp_allocator)
	if err := alsa.pcm_hw_params_any(state.pcm, hw_params); err < 0 {
		log.error("audio: failed to get HW arams:", alsa.strerror(err))
		return .Failed
	}
	// Based on pcm_set_params, but with some customizations
	if err := alsa.pcm_hw_params_set_rate_resample(
		state.pcm,
		hw_params,
		.Enable,
	); err != 0 {
		log.error("audio: failed to set rate resample:", alsa.strerror(err))
		return .Failed
	}
	if err := alsa.pcm_hw_params_set_access(
		state.pcm,
		hw_params,
		ALSA_CONFIG.access_mode,
	); err != 0 {
		log.error("audio: failed to set access mode:", alsa.strerror(err))
		return .Failed
	}
	if err := alsa.pcm_hw_params_set_format(state.pcm, hw_params, .S16);
	   err != 0 {
		log.error("audio: failed to set format:", alsa.strerror(err))
		return .Failed
	}
	if err := alsa.pcm_hw_params_set_channels(state.pcm, hw_params, 2);
	   err != 0 {
		log.error("audio: failed to set channels:", alsa.strerror(err))
		return .Failed
	}

	sample_rate: c.uint = TARGET_SAMPLE_RATE
	if err := alsa.pcm_hw_params_set_rate_near(
		state.pcm,
		hw_params,
		&sample_rate,
		nil,
	); err != 0 {
		log.error("audio: failed to set rate:", alsa.strerror(err))
		return .Failed
	}
	state.sample_rate = uint(sample_rate)

	// TODO: Play around with period/buffer time settings

	period_time_us: c.uint = TARGET_FRAME_US / 2
	if err := alsa.pcm_hw_params_set_period_time_near(
		state.pcm,
		hw_params,
		&period_time_us,
		nil,
	); err != 0 {
		log.error("audio: failed to set period time:", alsa.strerror(err))
		return .Failed
	}
	buffer_time_us: c.uint = TARGET_FRAME_US * 2
	if err := alsa.pcm_hw_params_set_buffer_time_near(
		state.pcm,
		hw_params,
		&buffer_time_us,
		nil,
	); err != 0 {
		log.error("audio: failed to set buffer time:", alsa.strerror(err))
		return .Failed
	}

	state.supports_pause =
		alsa.pcm_hw_params_can_pause(hw_params) == 1 &&
		alsa.pcm_hw_params_can_resume(hw_params) == 1

	if err := alsa.pcm_hw_params_get_buffer_size(
		hw_params,
		&state.buffer_size,
	); err != 0 {
		log.error("audio: failed to get buffer size:", alsa.strerror(err))
		return .Failed
	}
	if err := alsa.pcm_hw_params_get_period_size(
		hw_params,
		&state.period_size,
	); err != 0 {
		log.error("audio: failed to get period size:", alsa.strerror(err))
		return .Failed
	}

	if err := alsa.pcm_hw_params(state.pcm, hw_params); err != 0 {
		log.error("audio: failed to set HW params:", alsa.strerror(err))
		return .Failed
	}

	sw_params, _ := alsa.pcm_sw_params_alloc(context.temp_allocator)
	if err := alsa.pcm_sw_params_current(state.pcm, sw_params); err != 0 {
		log.error("audio: failed to get SW params:", alsa.strerror(err))
		return .Failed
	}

	if err := alsa.pcm_sw_params_set_avail_min(
		state.pcm,
		sw_params,
		state.period_size,
	); err != 0 {
		log.error("audio: failed to set avail min:", alsa.strerror(err))
		return .Failed
	}
	if err := alsa.pcm_sw_params_set_start_threshold(
		state.pcm,
		sw_params,
		max(alsa.Pcm_Uframes),
	); err != 0 {
		log.error("audio: failed to set start threshold:", alsa.strerror(err))
		return .Failed
	}

	if err := alsa.pcm_sw_params(state.pcm, sw_params); err != 0 {
		log.error("audio: failed to set SW params:", alsa.strerror(err))
		return .Failed
	}

	when ALSA_CONFIG.access_mode == .RW_INTERLEAVED {
		state.buffer = make([]game_api.Audio_Frame, state.buffer_size)
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
	buf: []game_api.Audio_Frame,
	ok: bool,
) {
	// TODO: Add more generic Audio_Buffer type if first and step have padding
	// TODO: Just assert?
	if area.first != 0 {
		log.errorf(
			"channel offset not byte-aligned: first_bits={}",
			area.first,
		)
		return
	}
	if area.step != 8 * size_of(game_api.Audio_Frame) {
		log.errorf("channel offset not Frame: step_bits={}", area.step)
		return
	}

	// Make sure the API doesn't expect me to handle wrap-around
	assert(offset + space <= buffer_size)

	full_buffer := mem.slice_ptr(
		(^game_api.Audio_Frame)(area.addr),
		int(buffer_size),
	)
	return full_buffer[offset:][:space], true
}

audio_fill_buffer :: proc(state: ^State) -> Audio_Error {
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
			if err := alsa.pcm_recover(
				audio.pcm,
				-posix.EPIPE,
				alsa.PCM_RECOVER_VERBOSE,
			); err != 0 {
				log.error("failed to recover:", alsa.strerror(err))
				return .Failed
			}
			// TODO: Is this needed? ALSA's example does it, but it seems redundant to
			// re-check the status
			continue audio_loop
		case:
			need_start = true
		}

		// TODO: Repeat just this section if possible to avoid re-checking status?
		avail: alsa.Pcm_Sframes
		delay: alsa.Pcm_Sframes
		if err := alsa.pcm_avail_delay(audio.pcm, &avail, &delay); err != 0 {
			log.error("failed to update available space:", alsa.strerror(err))
			if err := alsa.pcm_recover(
				audio.pcm,
				err,
				alsa.PCM_RECOVER_VERBOSE,
			); err != 0 {
				log.error(
					"failed to update available space: failed to recover:",
					alsa.strerror(err),
				)
				return .Failed
			}
			continue
		}
		delay_ns := i64(delay) * 1_000_000_000 / i64(audio.sample_rate)
		write_timestamp_ns := get_perf_counter_wall_ns() + delay_ns

		log.debugf("audio state: delay={}frames avail={}frames", delay, avail)
		if avail == 0 {
			return nil
		}

		timings := game_api.Audio_Timings {
			write_timestamp_ns = write_timestamp_ns,
			sample_rate = audio.sample_rate,
		}

		when ALSA_CONFIG.access_mode == .RW_INTERLEAVED {
			frame_buf := audio.buffer[:avail]
			state.game_symbols.render_audio(
				state.game_memory,
				timings,
				frame_buf,
			)

			// Should always return avail since we just asked how much space
			// there is
			if res := alsa.pcm_writei(
				audio.pcm,
				raw_data(frame_buf),
				alsa.Pcm_Uframes(avail),
			); res < 0 {
				log.error("failed to write samples:", alsa.strerror(i32(res)))
				return .Failed
			} else if res != avail {
				log.warnf(
					"write too few samples: expected={} got={}",
					avail,
					res,
				)
			}
		} else {
			area: [^]alsa.Pcm_Channel_Area // Multi-pointer for the API
			offset: alsa.Pcm_Uframes
			space := alsa.Pcm_Uframes(avail)
			if err := alsa.pcm_mmap_begin(audio.pcm, &area, &offset, &space);
			   err != 0 {
				log.error("failed to lock mmap area:", alsa.strerror(err))
				return .Failed
			}

			frame_buf, ok := get_audio_buffer(
				audio.buffer_size,
				area,
				offset,
				space,
			)
			if !ok do return .Failed

			state.game_symbols.render_audio(
				state.game_memory,
				timings,
				frame_buf,
			)

			if err := alsa.pcm_mmap_commit(audio.pcm, offset, space); err < 0 {
				log.error(
					"failed to commit mmap area:",
					alsa.strerror(i32(err)),
				)
				return .Failed
			} else if alsa.Pcm_Uframes(err) != space {
				log.warnf("short commit: expected={} got={}", space, err)
			}
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

audio_get_poll_descriptors :: proc(
	state: ^Audio_State,
	pfds: []posix.pollfd,
) -> (
	ok: bool,
) {
	if res := alsa.pcm_poll_descriptors(
		state.pcm,
		&pfds[0],
		c.uint(len(pfds)),
	); res == c.int(len(pfds)) {
		return true
	} else if res < 0 {
		log.error("failed to get poll descriptors:", alsa.strerror(res))
		return false
	} else {
		log.warnf("got too few poll FDs: expected={} got={}", len(pfds), res)
		return true
	}
}

audio_pause :: proc(state: ^Audio_State) {
	if state.supports_pause {
		if err := alsa.pcm_pause(state.pcm, .Pause); err == 0 {
			return
		} else {
			log.warn("failed to pause audio stream:", alsa.strerror(err))
		}
	}

	// Fallback
	if err := alsa.pcm_drain(state.pcm); err != 0 {
		log.warn("failed to drain audio stream:", alsa.strerror(err))
	}
}

audio_resume :: proc(state: ^Audio_State) {
	if state.supports_pause {
		if err := alsa.pcm_pause(state.pcm, .Resume); err == 0 {
			return
		} else {
			log.warn("failed to resume audio stream:", alsa.strerror(err))
		}
	}

	// Fallback
	if err := alsa.pcm_prepare(state.pcm); err != 0 {
		log.warn(
			"failed to prepare audio stream for resuming:",
			alsa.strerror(err),
		)
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
		return audio_fill_buffer(state)
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
