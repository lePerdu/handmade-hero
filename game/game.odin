package game

import "base:runtime"
import "core:math"
import "core:mem"

import "api"

State :: struct {
	x_offset, y_offset: f32,
	play_sound: bool,
	audio_vol: f32,
	audio_phase: f32,
	game_context: runtime.Context,
}

handmade_game_init :: proc "c" (memory: api.Memory, memory_len: int) {
	// TODO: Return error code instead
	assert_contextless(memory_len >= size_of(State))
	state := (^State)(memory)
	state^ = {
		game_context = runtime.default_context(),
	}
	// TODO: Configure these to allocate from passed in memory block
	state.game_context.allocator = runtime.nil_allocator()
	state.game_context.temp_allocator = runtime.nil_allocator()
}

handmade_game_update :: proc "c" (
	memory: api.Memory,
	input: ^api.Input,
	dt_ns: i64,
) {
	state := (^State)(memory)
	context = state.game_context

	// rate=24p/s
	rate: f32 : 24.0
	x_rate: f32 = 0.0
	y_rate: f32 = 0.0

	// Use +=/-= so that pressing 2 directions at the same time cancels out
	if input.keyboard[.W].end_pressed || input.keyboard[.UP].end_pressed do y_rate += rate
	if input.keyboard[.A].end_pressed || input.keyboard[.Left].end_pressed do x_rate += rate
	if input.keyboard[.S].end_pressed || input.keyboard[.Down].end_pressed do y_rate -= rate
	if input.keyboard[.D].end_pressed || input.keyboard[.Right].end_pressed do x_rate -= rate
	state.x_offset += f32(dt_ns) * x_rate / 1_000_000_000.0
	state.y_offset += f32(dt_ns) * y_rate / 1_000_000_000.0

	state.play_sound = input.keyboard[.Space].end_pressed
}

handmade_game_render :: proc "c" (memory: api.Memory, fb: ^api.Frame_Buffer) {
	state := (^State)(memory)
	context = state.game_context
	render_gradient(fb^, int(state.x_offset), int(state.y_offset))
}

Pixel :: distinct u32

make_pixel :: proc(r, g, b: u8) -> Pixel {
	return Pixel(u32(r) << 16 | u32(g) << 8 | u32(b))
}

frame_buffer_row :: proc(fb: api.Frame_Buffer, y: u32) -> []Pixel {
	assert(y < fb.height)
	return mem.slice_ptr(
		(^Pixel)(uintptr(fb.base) + uintptr(y * fb.stride)),
		int(fb.width),
	)
}

render_gradient :: proc(fb: api.Frame_Buffer, x_offset, y_offset: int) {
	for y in 0 ..< fb.height {
		row := frame_buffer_row(fb, y)
		for x in 0 ..< fb.width {
			// TODO: Is casting to u8 the "proper" way to wrap?
			row[x] = make_pixel(
				0,
				u8(int(y) + y_offset),
				u8(int(x) + x_offset),
			)
		}
	}
}

VOLUME :: 0.2
ATTACK_MS :: 50.0

handmade_game_render_audio :: proc "c" (
	memory: api.Memory,
	timings: ^api.Audio_Timings,
	buffer: [^]api.Audio_Frame,
	buffer_len: int,
) {
	state := (^State)(memory)
	context = state.game_context

	generate_sine(
		timings^,
		buffer[0:buffer_len],
		freq = 420.0,
		amp = &state.audio_vol,
		amp_target = state.play_sound ? VOLUME : 0.0,
		phase = &state.audio_phase,
	)
}

generate_sine :: proc(
	timings: api.Audio_Timings,
	frame_buf: []api.Audio_Frame,
	freq: f32,
	amp: ^f32,
	amp_target: f32,
	phase: ^f32,
) {
	dt := math.TAU / f32(timings.sample_rate) * freq
	// amplitude increment for each sample in order to go from 0->VOLUME in
	// ATTACK_MS
	amp_inc := VOLUME / (ATTACK_MS / 1000.0) / f32(timings.sample_rate)

	// TODO: Does not modifying the pointers in the loop actually matter?
	t: f32 = phase^
	cur_amp: f32 = amp^
	for &frame, index in frame_buf {
		if cur_amp <= amp_target {
			cur_amp = min(cur_amp + amp_inc, amp_target)
		} else {
			cur_amp = max(cur_amp - amp_inc, amp_target)
		}
		sample_amp := f32(max(i16)) * cur_amp
		sample := sample_amp * math.sin(t)
		frame = {i16(sample), i16(sample)}
		t += dt
		if t > math.TAU do t -= math.TAU
	}
	phase^ = t
	amp^ = cur_amp
}
