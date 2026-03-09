package game

import "base:runtime"
import "core:math"
import "core:mem"
import "core:slice"

import "api"

State :: struct {
	// Relies on game memory being 0-initialized
	initialized: bool,
	player_x: f32,
	player_y: f32,
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
			player_x = 100,
			player_y = 100,
		}
	}
	return state
}

@(export)
handmade_game_update :: proc "contextless" (
	memory: api.Memory,
	input: api.Input,
) {
	context = get_game_context(memory)
	state := get_game_state(memory)

	// Sign of the movement: -1, 0, +1
	player_dir_x, player_dir_y: f32
	player_rate: f32 = 120e-9 * f32(input.dt_ns)

	if input.keyboard[.W].end_pressed || input.keyboard[.Up].end_pressed {
		player_dir_y -= 1
	}
	if input.keyboard[.A].end_pressed || input.keyboard[.Left].end_pressed {
		player_dir_x -= 1
	}
	if input.keyboard[.S].end_pressed || input.keyboard[.Down].end_pressed {
		player_dir_y += 1
	}
	if input.keyboard[.D].end_pressed || input.keyboard[.Right].end_pressed {
		player_dir_x += 1
	}

	// Scale diagonal movement
	player_movement: f32 = player_rate
	if player_dir_x != 0 && player_dir_y != 0 {
		player_movement *= math.sqrt(f32(0.5))
	}

	state.player_x += player_dir_x * player_movement
	state.player_y += player_dir_y * player_movement
}

TILE_MAP := [9][17]u8 {
	{1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1},
	{1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1},
	{1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1},
	{1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1},
	{1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0},
	{1, 1, 0, 1, 0, 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1},
	{1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1},
	{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1},
	{1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1},
}

@(export)
handmade_game_render :: proc "contextless" (
	memory: api.Memory,
	fb: api.Frame_Buffer,
) {
	context = get_game_context(memory)
	state := get_game_state(memory)

	frame_buffer_fill(fb, make_pixel(0xFF00FF))

	tile_width := f32(fb.width) / (len(TILE_MAP[0]) - 1)
	tile_x_offset: f32 = tile_width / -2.0

	tile_height := f32(fb.height) / len(TILE_MAP)
	tile_y_offset: f32 = 0

	for row, y in TILE_MAP {
		for col, x in row {
			color: Color
			if col == 0 {
				color = make_color_grey(0.1)
			} else {
				color = make_color_grey(0.8)
			}
			render_rect(
				fb,
				x = f32(x) * tile_width + tile_x_offset,
				y = f32(y) * tile_height + tile_y_offset,
				w = tile_width,
				h = tile_height,
				color = color,
			)
		}
	}

	player_width := 0.6 * tile_width
	player_height := 0.75 * tile_height
	render_rect(
		fb,
		x = state.player_x - player_width / 2.0,
		y = state.player_y - player_height,
		w = player_width,
		h = player_height,
		color = {r = 0.8, g = 0.1, b = 0.1},
	)
}

Color :: struct {
	r, g, b: f32,
}

make_color_grey :: proc(v: f32) -> Color {
	return {r = v, g = v, b = v}
}

Pixel :: struct #packed {
	b, g, r, _: u8,
}

make_pixel :: proc {
	make_pixel_bits,
	make_pixel_rgb_u8,
	make_pixel_rgb_f32,
	make_pixel_color,
}

make_pixel_rgb_u8 :: proc(r, g, b: u8) -> Pixel {
	return Pixel{r = r, g = g, b = b}
}

make_pixel_rgb_f32 :: proc(r, g, b: f32) -> Pixel {
	to_u8 :: proc(v: f32) -> u8 {
		assert(v >= 0.0)
		assert(v <= 1.0)
		return u8(255 * v)
	}
	return make_pixel_rgb_u8(to_u8(r), to_u8(g), to_u8(b))
}

make_pixel_color :: proc(color: Color) -> Pixel {
	return make_pixel_rgb_f32(color.r, color.g, color.b)
}

make_pixel_bits :: proc(bits: Pixel_Bits) -> Pixel {
	return {
		b = u8(bits & 0xFF),
		g = u8((bits >> 8) & 0xFF),
		r = u8((bits >> 16) & 0xFF),
	}
}

Pixel_Bits :: distinct u32

pixel_bits :: proc(p: Pixel) -> Pixel_Bits {
	// TODO: Check endianness of the machine?
	// TODO: transmute?
	return Pixel_Bits(p.b) | (Pixel_Bits(p.g) << 8) | (Pixel_Bits(p.r) << 16)
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

render_rect :: proc(fb: api.Frame_Buffer, x, y, w, h: f32, color: Color) {
	pixel := make_pixel(color)
	y_min := round_clamp_px(y, fb.height)
	y_max := round_clamp_px(y + h, fb.height)

	x_min := round_clamp_px(x, fb.width)
	x_max := round_clamp_px(x + w, fb.width)

	for y_px in y_min ..< y_max {
		row := frame_buffer_row(fb, y_px)
		row_part := row[x_min:x_max]
		slice.fill(row_part, pixel)
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

// Try to construct the symbol table to make sure the types are correct
typecheck_symbol_table :: api.Symbol_Table {
	update = handmade_game_update,
	render = handmade_game_render,
	render_audio = handmade_game_render_audio,
}
