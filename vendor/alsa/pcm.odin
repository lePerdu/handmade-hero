package alsa

// Incomplete bindings for alsa-lib PCM (mostly just what I needed)

import "core:c"
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
