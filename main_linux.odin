package main

import "base:intrinsics"
import "core:log"
import "core:mem"
import "core:os"
import "core:sys/posix"

State :: struct {
	game:    Game_State,
	display: Display_State,
	audio:   Audio_State,
}

main :: proc() {
	context.logger = log.create_console_logger(lowest = .Info)

	state: State

	if !display_init(&state.display, &state.game) do os.exit(1)

	if audio_init(&state.audio, &state.game) != nil do os.exit(1)

	state.game.freq = 440
	// defer audio_destroy(&state.audio)

	game_loop(&state)
}

game_loop :: proc(state: ^State) {
	last_loop_ns: i64

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
		state.game.play_sound = state.display.key_states[.Space]

		audio_handle_poll(&state.audio, audio_poll) or_break

		free_all(context.temp_allocator)

		counter_total_wall_ns := get_perf_counter_wall_ns() - counter_start_wall_ns
		counter_total_cpu_ns := get_perf_counter_cpu_ns() - counter_start_cpu_ns
		counter_total_cpu_cycles := get_perf_counter_cpu_cycles() - counter_start_cpu_cycles

		log.infof(
			"perf counter: wall={}ms  cpu={}ms  cycles={}K",
			counter_total_wall_ns / 1000,
			counter_total_cpu_ns / 1000,
			counter_total_cpu_cycles / 1000,
		)
	}
}

get_perf_counter_wall_ns :: proc() -> u64 {
	t: posix.timespec
	if posix.clock_gettime(.MONOTONIC, &t) != .OK {
		return 0
	}
	return u64(t.tv_sec) * 1_000_000_000 + u64(t.tv_nsec)
}

get_perf_counter_cpu_ns :: proc() -> u64 {
	t: posix.timespec
	if posix.clock_gettime(.PROCESS_CPUTIME_ID, &t) != .OK {
		return 0
	}
	return u64(t.tv_sec) * 1_000_000_000 + u64(t.tv_nsec)
}

get_perf_counter_cpu_cycles :: intrinsics.read_cycle_counter
