package main

import "core:math"
import "core:mem"

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

game_update_and_render :: proc(fb: Frame_Buffer, x_offset, y_offset: int) {
	render_gradient(fb, x_offset, y_offset)
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
