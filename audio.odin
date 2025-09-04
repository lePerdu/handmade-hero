package main

import "core:c"
import "core:log"
import "core:math"
import "core:sys/posix"

foreign import asound "system:libasound.so.2"

Pcm :: distinct rawptr
Pcm_Stream :: enum c.int {
	Playback = 0,
	Capture,
}
Pcm_Mode :: enum c.int {
	Block    = 0,
	Nonblock = 1,
	Async    = 2,
}

Pcm_Hw_Params :: distinct rawptr

Pcm_Access :: enum c.int {
	MMAP_INTERLEAVED = 0,
	MMAP_NONINTERLEAVED,
	MMAP_COMPLEX,
	RW_INTERLEAVED,
	RW_NONINTERLEAVED,
}

Pcm_Format :: enum c.int {
	UNKNOWN = -1,
	S8 = 0,
	U8,
	S16_LE,
	S16_BE,
	U16_LE,
	U16_BE,
	S24_LE,
	S24_BE,
	U24_LE,
	U24_BE,
	S32_LE,
	S32_BE,
	U32_LE,
	U32_BE,
	FLOAT_LE,
	FLOAT_BE,
	FLOAT64_LE,
	FLOAT64_BE,
	IEC958_SUBFRAME_LE,
	IEC958_SUBFRAME_BE,
	MU_LAW,
	A_LAW,
	IMA_ADPCM,
	MPEG,
	GSM,
	S20_LE,
	S20_BE,
	U20_LE,
	U20_BE,
	SPECIAL = 31,
	S24_3LE = 32,
	S24_3BE,
	U24_3LE,
	U24_3BE,
	S20_3LE,
	S20_3BE,
	U20_3LE,
	U20_3BE,
	S18_3LE,
	S18_3BE,
	U18_3LE,
	U18_3BE,
	/* G.723 (ADPCM) 24 kbit/s, 8 samples in 3 bytes */
	G723_24,
	/* G.723 (ADPCM) 24 kbit/s, 1 sample in 1 byte */
	G723_24_1B,
	/* G.723 (ADPCM) 40 kbit/s, 8 samples in 3 bytes */
	G723_40,
	/* G.723 (ADPCM) 40 kbit/s, 1 sample in 1 byte */
	G723_40_1B,
	/* Direct Stream Digital (DSD) in 1-byte samples (x8) */
	DSD_U8,
	/* Direct Stream Digital (DSD) in 2-byte samples (x16) */
	DSD_U16_LE,
	/* Direct Stream Digital (DSD) in 4-byte samples (x32) */
	DSD_U32_LE,
	/* Direct Stream Digital (DSD) in 2-byte samples (x16) */
	DSD_U16_BE,
	/* Direct Stream Digital (DSD) in 4-byte samples (x32) */
	DSD_U32_BE,
	S16 = S16_LE,
	U16 = U16_LE,
	S24 = S24_LE,
	U24 = U24_LE,
	S32 = S32_LE,
	U32 = U32_LE,
	FLOAT = FLOAT_LE,
	FLOAT64 = FLOAT64_LE,
	IEC958_SUBFRAME = IEC958_SUBFRAME_LE,
	S20 = S20_LE,
	U20 = U20_LE,

	// S16 = S16_BE,
	// U16 = U16_BE,
	// S24 = S24_BE,
	// U24 = U24_BE,
	// S32 = S32_BE,
	// U32 = U32_BE,
	// FLOAT = FLOAT_BE,
	// FLOAT64 = FLOAT64_BE,
	// IEC958_SUBFRAME = IEC958_SUBFRAME_BE,
	// S20 = S20_BE,
	// U20 = U20_BE,
}

Pcm_Resample :: enum c.uint {
	Disable = 0,
	Enable  = 1,
}

PCM_WAIT_INDEFINITE: c.int : -1
PCM_WAIT_IO: c.int : -10001
PCM_WAIT_DRAIN: c.int : -10002

PCM_WAIT_READY: c.int : 1
PCM_WAIT_TIMEOUT: c.int : 0

// TODO: Are these swapped?
PCM_RECOVER_VERBOSE: c.int : 0
PCM_RECOVER_SILENT: c.int : 1

Pcm_Uframes :: c.ulong
Pcm_Sframes :: c.long

// PCM area specification
Pcm_Channel_Area :: struct {
	// base address of channel samples
	addr:  rawptr,
	// offset to first sample in bits
	first: c.uint,
	// samples distance in bits
	step:  c.uint,
}

Pcm_State :: enum c.int {
	// Open
	STATE_OPEN = 0,
	// Setup installed
	STATE_SETUP,
	// Ready to start
	STATE_PREPARED,
	// Running
	STATE_RUNNING,
	// Stopped: underrun (playback) or overrun (capture) detected
	STATE_XRUN,
	// Draining: running (playback) or stopped (capture)
	STATE_DRAINING,
	// Paused
	STATE_PAUSED,
	// Hardware is suspended
	STATE_SUSPENDED,
	// Hardware is disconnected
	STATE_DISCONNECTED,
}

@(default_calling_convention = "c")
foreign asound {
	@(link_prefix = "snd_")
	strerror :: proc(err: c.int) -> cstring ---

	@(link_prefix = "snd_")
	pcm_open :: proc(pcm: ^Pcm, name: cstring, stream: Pcm_Stream, mode: Pcm_Mode) -> c.int ---

	@(link_prefix = "snd_")
	pcm_close :: proc(pcm: Pcm) -> c.int ---

	@(link_prefix = "snd_")
	pcm_state :: proc(pcm: Pcm) -> Pcm_State ---

	@(link_prefix = "snd_")
	pcm_prepare :: proc(pcm: Pcm) -> c.int ---

	@(link_prefix = "snd_")
	pcm_start :: proc(pcm: Pcm) -> c.int ---

	@(link_prefix = "snd_")
	pcm_get_params :: proc(pcm: Pcm, buffer_size: ^Pcm_Uframes, period_size: ^Pcm_Uframes) -> c.int ---

	@(link_prefix = "snd_")
	pcm_set_params :: proc(pcm: Pcm, format: Pcm_Format, access: Pcm_Access, channels: c.uint, rate: c.uint, soft_resample: Pcm_Resample, latency: c.uint) -> c.int ---

	@(link_prefix = "snd_")
	pcm_writei :: proc(pcm: Pcm, buffer: rawptr, size: Pcm_Uframes) -> Pcm_Sframes ---

	@(link_prefix = "snd_")
	pcm_drain :: proc(pcm: Pcm) -> c.int ---

	@(link_prefix = "snd_")
	pcm_recover :: proc(pcm: Pcm, err: c.int, silent: c.int) -> c.int ---

	@(link_prefix = "snd_")
	pcm_drop :: proc(pcm: Pcm) -> c.int ---

	@(link_prefix = "snd_")
	pcm_avail_update :: proc(pcm: Pcm) -> Pcm_Sframes ---

	@(link_prefix = "snd_")
	pcm_mmap_begin :: proc(pcm: Pcm, areas: ^[^]Pcm_Channel_Area, offset: ^Pcm_Uframes, frames: ^Pcm_Uframes) -> c.int ---

	@(link_prefix = "snd_")
	pcm_mmap_commit :: proc(pcm: Pcm, offset: Pcm_Uframes, frames: Pcm_Uframes) -> Pcm_Sframes ---

	@(link_prefix = "snd_")
	pcm_wait :: proc(pcm: Pcm, timeout: c.int) -> c.int ---

	// More complex APIs if needed
	// @(link_prefix = "snd_")
	// pcm_hw_params_sizeof :: proc() -> c.size_t ---

	// @(link_prefix = "snd_")
	// pcm_hw_params_any :: proc(pcm: Pcm, params: Pcm_Hw_Params) -> c.int ---

	// @(link_prefix = "snd_")
	// pcm_hw_params :: proc(pcm: Pcm, params: Pcm_Hw_Params) -> c.int ---

	// @(link_prefix = "snd_")
	// pcm_hw_params_set_access :: proc(pcm: Pcm, params: Pcm_Hw_Params, access: Pcm_Access) -> c.int ---

	// @(link_prefix = "snd_")
	// pcm_hw_params_set_channels :: proc(pcm: Pcm, params: Pcm_Hw_Params, val: c.uint) -> c.int ---

	// @(link_prefix = "snd_")
	// pcm_hw_params_set_format :: proc(pcm: Pcm, params: Pcm_Hw_Params, format: Pcm_Format) -> c.int ---

	// @(link_prefix = "snd_")
	// pcm_hw_params_set_rate :: proc(pcm: Pcm, params: Pcm_Hw_Params, val: c.uint, dir: c.int) -> c.int ---

	// @(link_prefix = "snd_")
	// pcm_hw_params_set_rate_resample :: proc(pcm: Pcm, params: Pcm_Hw_Params, val: Pcm_Resample) -> c.int ---

	@(link_prefix = "snd_")
	pcm_hw_params_get_sbits :: proc(params: Pcm_Hw_Params) -> c.int ---

	@(link_prefix = "snd_")
	pcm_hw_params_get_buffer_size :: proc(pcm: Pcm, params: Pcm_Hw_Params, val: ^Pcm_Uframes) -> c.int ---

	@(link_prefix = "snd_")
	pcm_poll_descriptors_count :: proc(pcm: Pcm) -> c.int ---

	@(link_prefix = "snd_")
	pcm_poll_descriptors :: proc(pcm: Pcm, pfds: [^]posix.pollfd, size: c.uint) -> c.int ---

	@(link_prefix = "snd_")
	pcm_poll_descriptors_revents :: proc(pcm: Pcm, pfds: [^]posix.pollfd, nfds: c.uint, revents: ^posix.Poll_Event) -> c.int ---
}

SAMPLE_RATE :: 48000
BUF_DURATION_SEC :: 2
BUF_FRAME_COUNT :: BUF_DURATION_SEC * SAMPLE_RATE

Frame :: struct #packed {
	l: i16,
	r: i16,
}

Audio_State :: struct {
	pcm:         Pcm,
	buffer_size: Pcm_Uframes,
	period_size: Pcm_Uframes,

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
	if err := pcm_open(&state.pcm, "default", .Playback, .Block); err != 0 {
		log.error("failed to open audio device:", strerror(err))
		return .Failed
	}

	if err := pcm_set_params(
		state.pcm,
		format = .S16,
		access = .MMAP_INTERLEAVED,
		channels = 2,
		rate = SAMPLE_RATE,
		soft_resample = .Enable,
		latency = 500_000,
	); err != 0 {
		log.error("failed to configure audio device:", strerror(err))
		return .Failed
	}

	if err := pcm_get_params(state.pcm, &state.buffer_size, &state.period_size); err != 0 {
		log.error("failed to fetch configuration:", strerror(err))
		return .Failed
	}
	log.debugf(
		"audio device config: buffer_size={} period_size={}",
		state.buffer_size,
		state.period_size,
	)

	// TODO: Is this necessary?
	// if err := pcm_prepare(state.pcm); err != 0 {
	// 	log.error("failed to prepare audio device:", strerror(err))
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
	buffer_size: Pcm_Uframes,
	area: ^Pcm_Channel_Area,
	offset: Pcm_Uframes,
	space: Pcm_Uframes,
) -> (
	iter: Dual_Channel_Iterator,
	ok: bool,
) {
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
	assert(Pcm_Uframes(iter.init_frame_offset + iter.init_frame_space) <= buffer_size)
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

generate_sine :: proc(
	buffer_size: Pcm_Uframes,
	area: ^Pcm_Channel_Area,
	offset: Pcm_Uframes,
	space: Pcm_Uframes,
	freq: f32,
	amp: f32,
	phase: ^f32,
) -> (
	frames: Pcm_Uframes,
	ok: bool,
) {
	iter := dual_channel_iterator(buffer_size, area, offset, space) or_return

	dt: f32 : 1.0 / SAMPLE_RATE
	sample_amp := f32(max(i16)) * amp
	scalar := math.TAU * freq * dt

	ph: f32 = phase^
	for frame, index in dual_channel_next(&iter) {
		sample := sample_amp * math.sin(ph)
		frame^ = {i16(sample), i16(sample)}
		ph += scalar
		if ph > math.TAU do ph -= math.TAU
	}
	// phase^ = math.mod(phase^ + scalar * f32(iter.frame_count), math.TAU)
	phase^ = ph
	return Pcm_Uframes(iter.frame_count), true
}

audio_write_sine_wave :: proc(state: ^Audio_State) -> Audio_Error {
	// Loop until "would block"
	audio_loop: for {
		need_start: bool
		#partial switch status := pcm_state(state.pcm); status {
		case .STATE_RUNNING:
			need_start = false
		case .STATE_XRUN:
			if err := pcm_recover(state.pcm, -posix.EPIPE, PCM_RECOVER_VERBOSE); err != 0 {
				log.error("failed to recover:", strerror(err))
				return .Failed
			}
			// TODO: Is this needed? ALSA's example does it, but it seems redundant
			// https://www.alsa-project.org/alsa-doc/alsa-lib/_2test_2pcm_8c-example.html#example_test_pcm
			continue audio_loop
		case:
			need_start = true
		}

		if avail := pcm_avail_update(state.pcm); avail < 0 {
			if err := pcm_recover(state.pcm, c.int(avail), PCM_RECOVER_VERBOSE); err != 0 {
				log.error("failed to update available space: failed to recover:", strerror(err))
				return .Failed
			}
			continue
		} else if Pcm_Uframes(avail) < state.period_size {
			// Wait for more data
			return nil
		}

		// TODO: Repeat just this section if possible to avoid re-checking status?

		area: [^]Pcm_Channel_Area // Multi-pointer for the API
		offset: Pcm_Uframes
		space: Pcm_Uframes = state.buffer_size // TODO: Just request max(Pcm_Uframes)?
		if err := pcm_mmap_begin(state.pcm, &area, &offset, &space); err != 0 {
			log.error("failed to lock mmap area:", strerror(err))
			return .Failed
		}

		frames_written, ok := generate_sine(
			state.buffer_size,
			area,
			offset,
			space,
			freq = state.freq,
			amp = state.amp,
			phase = &state.phase,
		)
		if !ok {
			log.error("failed to generate sine wave")
			return .Failed
		}

		if err := pcm_mmap_commit(state.pcm, offset, frames_written); err < 0 {
			log.error("failed to commit mmap area:", strerror(i32(err)))
			return .Failed
		} else if Pcm_Uframes(err) != frames_written {
			log.warnf("short commit: expected={} got={}", frames_written, err)
		}

		// Start after putting something in the buffer
		if need_start {
			if err := pcm_start(state.pcm); err != 0 {
				log.error("failed to start audio device:", strerror(err))
				return .Failed
			}
		}
	}
}

audio_destroy :: proc(state: ^Audio_State) -> Audio_Error {
	if err := pcm_close(state.pcm); err != 0 {
		log.error("failed to close audio device:", strerror(err))
		return .Failed
	}
	return nil
}

// Take from alsa-lib source:
// https://github.com/alsa-project/alsa-lib/blob/3a9771812405be210e760e4e6667f2c023fe82f4/src/pcm/pcm.c#L2974
AUDIO_MAX_POLL_FDS :: 15

audio_get_poll_descriptor_count :: proc(state: ^Audio_State) -> (n: int, ok: bool) {
	if res := pcm_poll_descriptors_count(state.pcm); res < 0 {
		log.error("failed to determine poll descriptor count:", strerror(res))
		return 0, false
	} else if res > AUDIO_MAX_POLL_FDS {
		log.errorf("too many poll descriptors (max={}): {}", AUDIO_MAX_POLL_FDS, res)
		return 0, false
	} else {
		return int(res), true
	}
}

audio_get_poll_descriptors :: proc(state: ^Audio_State, pfds: []posix.pollfd) -> (ok: bool) {
	if res := pcm_poll_descriptors(state.pcm, &pfds[0], c.uint(len(pfds)));
	   res == c.int(len(pfds)) {
		return true
	} else if res < 0 {
		log.error("failed to get poll descriptors:", strerror(res))
		return false
	} else {
		log.warnf("got too few poll FDs: expected={} got={}", len(pfds), res)
		return true
	}
}

audio_handle_poll :: proc(state: ^Audio_State, pfds: []posix.pollfd) -> Audio_Error {
	revents: posix.Poll_Event
	if err := pcm_poll_descriptors_revents(state.pcm, &pfds[0], c.uint(len(pfds)), &revents);
	   err != 0 {
		log.error("failed to get poll descriptor revents:", strerror(err))
		return .Failed
	}

	if .OUT in revents {
		return audio_write_sine_wave(state)
	}
	return nil
}
