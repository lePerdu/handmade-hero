package main

import "core:log"
import "core:os"
import "core:sys/posix"

import "wayland"

Game_State :: struct {
	display: Display_State,
	audio:   Audio_State,
}

event_loop :: proc(state: ^Game_State) {
	loop: for !state.display.close_requested {
		poll_fds: [DISPLAY_POLL_FDS + AUDIO_MAX_POLL_FDS]posix.pollfd
		nfds := 0 // Actual number

		#assert(DISPLAY_POLL_FDS == 1)
		poll_fds[0] = display_get_poll_descriptor(&state.display) or_break
		display_poll := &poll_fds[0]
		nfds += DISPLAY_POLL_FDS

		// TODO: Don't break in case of failures?
		audio_nfds := audio_get_poll_descriptor_count(&state.audio) or_break
		audio_poll := poll_fds[nfds:][:audio_nfds]
		audio_get_poll_descriptors(&state.audio, audio_poll) or_break
		nfds += audio_nfds

		switch poll_res := posix.poll(&poll_fds[0], posix.nfds_t(nfds), -1); poll_res {
		case 0:
			// timeout
			continue loop
		case -1:
			// error
			log.error("failed to poll for updates:", posix.errno())
			break loop
		}

		display_handle_poll(&state.display, display_poll) or_break

		// TODO: Figure out how to make the audio stream update "immediately"
		// I guess it needs to be "drop"ed and re-filled?
		state.audio.amp = state.display.key_states[.Space] ? 0.2 : 0.0

		audio_handle_poll(&state.audio, audio_poll) or_break

		free_all(context.temp_allocator)
	}
}

main :: proc() {
	context.logger = log.create_console_logger(lowest = .Info)

	state: Game_State

	if !display_init(&state.display) do os.exit(1)

	if audio_init(&state.audio) != nil do os.exit(1)
	state.audio.freq = 420.0
	// defer audio_destroy(&state.audio)

	event_loop(&state)
}
