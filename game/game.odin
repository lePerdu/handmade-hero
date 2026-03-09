package game

import "base:runtime"
import "core:math"
import "core:mem"
import "core:slice"

import "api"

State :: struct {
	// Relies on game memory being 0-initialized
	initialized: bool,
}

get_game_context :: proc "contextless" (
	memory: api.Memory,
) -> runtime.Context {
	context = runtime.default_context()
	context.allocator = runtime.panic_allocator()

	temp_arena := (^mem.Arena)(raw_data(memory.temporary))
	remaining_temp_mem := memory.temporary[size_of(type_of(temp_arena^)):]
	mem.arena_init(temp_arena, remaining_temp_mem)
	context.temp_allocator = mem.arena_allocator(temp_arena)
	return context
}

get_game_state :: proc(memory: api.Memory) -> ^State {
	assert(len(memory.persistent) >= size_of(State))
	state := (^State)(raw_data(memory.persistent))
	if !state.initialized {
		state^ = {
			initialized = true,
		}
	}
	return state
}

@(export)
handmade_game_update :: proc "contextless" (
	memory: api.Memory,
	input: api.Input,
	dt_ns: i64,
) {
	context = get_game_context(memory)
	state := get_game_state(memory)
}

@(export)
handmade_game_render :: proc "contextless" (
	memory: api.Memory,
	fb: api.Frame_Buffer,
) {
	context = get_game_context(memory)
	state := get_game_state(memory)

	frame_buffer_fill(fb, 0x00FF00FF)
	render_rect(fb, 100, 100, 50, 160, 0x0000FFFF)
}

Pixel :: distinct u32

make_pixel :: proc(r, g, b: u8) -> Pixel {
	return Pixel(u32(r) << 16 | u32(g) << 8 | u32(b))
}

frame_buffer_row :: proc(fb: api.Frame_Buffer, y: int) -> []Pixel {
	assert(y >= 0)
	assert(y < int(fb.height))
	return mem.slice_ptr(
		(^Pixel)(uintptr(fb.base) + uintptr(y * int(fb.stride))),
		int(fb.width),
	)
}

frame_buffer_px :: proc(fb: api.Frame_Buffer, x, y: int) -> ^Pixel {
	assert(x >= 0)
	assert(x < int(fb.width))
	return &frame_buffer_row(fb, y)[x]
}

frame_buffer_get :: proc(fb: api.Frame_Buffer, x, y: int) -> Pixel {
	return frame_buffer_px(fb, x, y)^
}

frame_buffer_set :: proc(fb: api.Frame_Buffer, x, y: int, p: Pixel) {
	frame_buffer_px(fb, x, y)^ = p
}

frame_buffer_fill :: proc(fb: api.Frame_Buffer, p: Pixel) {
	// TODO: Is it OK to to write over gaps in the stride?
	for y in 0 ..< fb.height {
		row := frame_buffer_row(fb, int(y))
		slice.fill(row, p)
	}
}

round_px :: #force_inline proc(v: f32) -> int {
	return int(math.round(v))
}

round_clamp_px :: #force_inline proc(v: f32, #any_int fb_dim: int) -> int {
	return clamp(round_px(v), 0, fb_dim)
}

render_rect :: proc(fb: api.Frame_Buffer, x, y, w, h: f32, color: Pixel) {
	y_min := round_clamp_px(y, fb.height)
	y_max := round_clamp_px(y + h, fb.height)

	x_min := round_clamp_px(x, fb.width)
	x_max := round_clamp_px(x + w, fb.width)

	for y_px in y_min ..< y_max {
		row := frame_buffer_row(fb, y_px)
		row_part := row[x_min:x_max]
		slice.fill(row_part, color)
	}
}

@(export)
handmade_game_render_audio :: proc "contextless" (
	memory: api.Memory,
	timings: api.Audio_Timings,
	buffer: []api.Audio_Frame,
) {
	context = get_game_context(memory)
	state := get_game_state(memory)

	// Silence
	slice.fill(buffer, api.Audio_Frame{0, 0})
}
