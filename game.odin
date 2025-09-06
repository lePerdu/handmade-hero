package main

import "core:log"
import "core:math"
import "core:mem"

game_render :: proc(fb: Frame_Buffer, x_offset, y_offset: int) {
	render_gradient(fb, x_offset, y_offset)
}

Frame_Buffer :: struct {
	base:   rawptr,
	width:  u32,
	height: u32,
	stride: u32,
}

frame_buffer_row :: proc(fb: Frame_Buffer, y: u32) -> []Pixel {
	assert(y < fb.height)
	return mem.slice_ptr((^Pixel)(uintptr(fb.base) + uintptr(y * fb.stride)), int(fb.width))
}

Pixel :: distinct u32

make_pixel :: proc(r, g, b: u8) -> Pixel {
	return Pixel(u32(r) << 16 | u32(g) << 8 | u32(b))
}

render_gradient :: proc(fb: Frame_Buffer, x_offset, y_offset: int) {
	for y in 0 ..< fb.height {
		row := frame_buffer_row(fb, y)
		for x in 0 ..< fb.width {
			// TODO: Is casting to u8 the "proper" way to wrap?
			row[x] = make_pixel(0, u8(int(y) + y_offset), u8(int(x) + x_offset))
		}
	}
}

Audio_Frame :: struct #packed {
	l: i16,
	r: i16,
}

global_phase: f32

game_render_audio :: proc(buffer: []Audio_Frame, play_sound: bool) {
	generate_sine(buffer, freq = 420.0, amp = play_sound ? 0.2 : 0.0, phase = &global_phase)
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
