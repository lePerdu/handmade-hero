package main

import "core:c"
import "core:log"
import "core:math"
import "core:sys/posix"

import "alsa"

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
	pcm:         alsa.Pcm,
	buffer_size: alsa.Pcm_Uframes,
	period_size: alsa.Pcm_Uframes,

	// Sound state
	freq:        f32,
	// 0-1
	amp:         f32,
	phase:       f32,
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

Dual_Channel_Iterator :: struct {
	base:              rawptr,
	step_bytes:        uint,
	init_frame_offset: uint,
	init_frame_space:  uint,
	// Frames written
	frame_count:       uint,
}

dual_channel_iterator :: proc(
	buffer_size: alsa.Pcm_Uframes,
	area: ^alsa.Pcm_Channel_Area,
	offset: alsa.Pcm_Uframes,
	space: alsa.Pcm_Uframes,
) -> (
	iter: Dual_Channel_Iterator,
	ok: bool,
) {
	// TODO: Just assert?
	if area.first % 8 != 0 {
		log.errorf("channel offset not byte-aligned: first_bits={}", area.first)
		return
	}
	if area.step % size_of(Frame) != 0 {
		log.errorf("channel offset not Frame: step_bits={}", area.step)
		return
	}

	iter.base = rawptr(uintptr(area.addr) + uintptr(area.first / 8))
	iter.step_bytes = uint(area.step / 8)
	iter.init_frame_offset = uint(offset)
	iter.init_frame_space = uint(space)
	// Make sure the API doesn't expect me to handle wrap-around
	assert(alsa.Pcm_Uframes(iter.init_frame_offset + iter.init_frame_space) <= buffer_size)
	ok = true
	return
}

dual_channel_next :: proc(iter: ^Dual_Channel_Iterator) -> (^Frame, uint, bool) {
	if iter.frame_count == iter.init_frame_space {
		return nil, 0, false
	}

	frame_offset := iter.init_frame_offset + iter.frame_count
	byte_offset := frame_offset * iter.step_bytes
	ptr := (^Frame)(uintptr(iter.base) + uintptr(byte_offset))
	iter.frame_count += 1
	return ptr, frame_offset, true
}

generate_sine :: proc(frame_iter: ^Dual_Channel_Iterator, freq: f32, amp: f32, phase: ^f32) {
	sample_amp := f32(max(i16)) * amp
	dt := math.TAU / SAMPLE_RATE * freq

	t: f32 = phase^
	for frame, index in dual_channel_next(frame_iter) {
		sample := sample_amp * math.sin(t)
		frame^ = {i16(sample), i16(sample)}
		t += dt
		if t > math.TAU do t -= math.TAU
	}
	phase^ = t
}

audio_write_sine_wave :: proc(state: ^Audio_State) -> Audio_Error {
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

		frame_iter, ok := dual_channel_iterator(state.buffer_size, area, offset, space)
		if !ok do return .Failed

		generate_sine(&frame_iter, freq = state.freq, amp = state.amp, phase = &state.phase)

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

audio_handle_poll :: proc(state: ^Audio_State, pfds: []posix.pollfd) -> Audio_Error {
	revents: posix.Poll_Event
	if err := alsa.pcm_poll_descriptors_revents(state.pcm, &pfds[0], c.uint(len(pfds)), &revents);
	   err != 0 {
		log.error("failed to get poll descriptor revents:", alsa.strerror(err))
		return .Failed
	}

	if .OUT in revents {
		return audio_write_sine_wave(state)
	}
	return nil
}
