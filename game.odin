package main

import "core:math"
import "core:mem"

Game_State :: struct {
	x_offset:   int,
	y_offset:   int,

	// Audio
	play_sound: bool,
	freq:       f32,
	phase:      f32,
}

Frame_Buffer :: struct {
	base:   rawptr,
	width:  u32,
	height: u32,
	stride: u32,
}

Pixel :: u32

make_pixel :: proc(r, g, b: u8) -> Pixel {
	return u32(r) << 16 | u32(g) << 8 | u32(b)
}

render :: proc(state: ^Game_State, fb: Frame_Buffer) {
	for y in 0 ..< fb.height {
		row_ptr := rawptr(uintptr(fb.base) + uintptr(y * fb.stride))
		row := mem.slice_ptr((^Pixel)(row_ptr), int(fb.width))
		for x in 0 ..< fb.width {
			// TODO: Is casting to u8 the "proper" way to wrap?
			row[x] = make_pixel(0, u8(int(y) + state.y_offset), u8(int(x) + state.x_offset))
		}
	}
}

Audio_Frame :: struct {
	l: i16,
	r: i16,
}

generate_sine :: proc(frame_buf: []Audio_Frame, freq: f32, amp: f32, phase: ^f32) {
	sample_amp := f32(max(i16)) * amp
	dt := math.TAU / SAMPLE_RATE * freq

	t: f32 = phase^
	for _, index in frame_buf {
		sample := sample_amp * math.sin(t)
		frame_buf[index] = {i16(sample), i16(sample)}
		t += dt
		if t > math.TAU do t -= math.TAU
	}
	phase^ = t
}

render_audio :: proc(state: ^Game_State, frame_buf: []Audio_Frame) {
	generate_sine(
		frame_buf,
		freq = state.freq,
		amp = state.play_sound ? 1.0 : 0.0,
		phase = &state.phase,
	)
}
