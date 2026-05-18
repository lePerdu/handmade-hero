package main

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

import game_api "game/api"
import "platform"
import display "platform/wayland"

Display_State :: display.State

State :: struct {
	display: Display_State,
	audio: Audio_State,
	running: bool,
	paused: bool,
	game_memory: game_api.Memory,
	exec_dir: string,
	proj_dir: string,
	data_dir: string,
	dynlib_path: string,
	dynlib_load_mod_time: time.Time,
	game_symbols: game_api.Symbol_Table,
	recorder: Recorder,
	debug_context: runtime.Context,
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

GAME_MEMORY_SIZE :: 10 << 20
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
	state.debug_context = context
	state.game_memory.debug.data = &state
	state.game_memory.debug.read_file = debug_read_file
	state.game_memory.debug.free_file = debug_free_file

	// Start with dummy symbols
	state.game_symbols = game_api.dummy_symbol_table

	reload_game_symbols(&state)

	if !display.init(&state.display) do os.exit(1)

	if audio_init(&state.audio) != nil do os.exit(1)

	game_loop(&state)
}

setup_paths :: proc(state: ^State) {
	if dir, err := os.get_executable_directory(context.allocator); err == nil {
		state.exec_dir = dir
	} else {
		log.panic("failed to get executable directory:", err)
	}

	if path, err := filepath.join({state.exec_dir, ".."}, context.allocator);
	   err == nil {
		state.proj_dir = path
	} else {
		log.panic("failed to get project directory:", err)
	}

	if path, err := filepath.join({state.proj_dir, "data"}, context.allocator);
	   err == nil {
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

	last_update_time_ns: i64 = get_perf_counter_wall_ns()
	last_render_time_ns: i64

	if fb, ok := display.get_back_buffer(&state.display); ok {
		state.game_symbols.render(state.game_memory, fb)
		last_render_time_ns = get_perf_counter_wall_ns()
		display.submit_first_frame(&state.display)
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

		if poll_fd, ok := display.get_poll_descriptor(&state.display); ok {
			display_poll_fd^ = poll_fd
		} else {
			log.error("failed to setup display file descriptors")
			return
		}

		// Set timeout at next simulation frame boundary in case there are no
		// display/audio events to process
		next_update_time_ns := last_update_time_ns + MIN_UPDATE_PERIOD_NS
		max_wait_time_ms := i32(
			max(next_update_time_ns - get_perf_counter_wall_ns(), 0) /
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

		display.handle_poll(&state.display, display_poll_fd) or_break

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
			if fb, ok := display.get_back_buffer(&state.display); ok {
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
				display.submit_frame(&state.display)
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
	if game_api.button_input_toggled(
		state.display.engine_keyboard_input[.F11],
	) {
		display.toggle_fullscreen(&state.display)
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

ENGINE_NUM_KEYS :: [?]platform.Engine_Key {
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

// On some systems, using "default" or "pipewire" leads to buzzing sound and
// blocks system audio while paused in the debugger. Pulse audio forces using
// RW_INTERLEAVED, but that's alright for now
ALSA_CONFIG :: DEFAULT_MMAP_CONFIG

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

debug_read_file :: proc "contextless" (
	state_raw: rawptr,
	filename: string,
) -> []byte {
	state := (^State)(state_raw)
	context = state.debug_context

	full_path: string
	if path, err := filepath.join(
		{state.proj_dir, filename},
		context.temp_allocator,
	); err == nil {
		full_path = path
	} else {
		log.panicf(
			"failed to build debug file path: {}/{}: {}",
			state.proj_dir,
			filename,
			err,
		)
	}

	if contents, err := os.read_entire_file(full_path, context.allocator);
	   err == nil {
		return contents
	} else {
		log.panicf("failed to read debug file: {}: {}", full_path, err)
	}
}

debug_free_file :: proc "contextless" (state_raw: rawptr, contents: []byte) {
	state := (^State)(state_raw)
	context = state.debug_context
	delete(contents)
}
