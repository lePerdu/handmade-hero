package main

import "core:c"
import "core:log"
import "core:math"
import "core:mem"
import "core:sys/posix"

import "vendor/alsa"

SAMPLE_RATE :: 48000
BUF_DURATION_SEC :: 2
BUF_FRAME_COUNT :: BUF_DURATION_SEC * SAMPLE_RATE

// 15 FPS
LATENCY_US :: 1_000_000 / 15

Frame :: struct #packed {
	l: i16,
	r: i16,
}

Audio_State :: struct {
	game_ref:    ^Game_State,
	pcm:         alsa.Pcm,
	buffer_size: alsa.Pcm_Uframes,
	period_size: alsa.Pcm_Uframes,
}

Audio_Error :: enum {
	None = 0,
	Failed,
}

audio_init :: proc(state: ^Audio_State, game_ref: ^Game_State) -> Audio_Error {
	state.game_ref = game_ref
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

		render_audio(state.game_ref, frame_buf)

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
