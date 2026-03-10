package game

import "base:runtime"
import "core:container/intrusive/list"
import "core:math"
import "core:mem"
import "core:slice"

import "api"

Frame_Buffer :: api.Frame_Buffer

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
			// TODO: Initialize later, once the tile map is known?
			player_x = 8,
			player_y = 5,
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
	// tiles / sec
	player_rate: f32 = 1e-9 * f32(input.dt_ns)

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

	// TODO: Actually look up position
	cur_tile := WORLD_MAP.tile_maps[0]

	new_x := state.player_x + player_dir_x * player_movement
	new_y := state.player_y + player_dir_y * player_movement

	if can_move_in_tile_map(cur_tile, new_x, new_y) {
		state.player_x = new_x
		state.player_y = new_y
	}
}

Tile :: u8

Tile_Map :: struct {
	// TODO: Smaller int size?
	rows, cols: int,
	// TODO: Store custom stride to allow taking subset views?
	// Tiles, stored in row-major order
	tiles: [^]Tile,
}

Tile_Row :: []Tile

tile_map_get_row :: proc(
	tile_map: Tile_Map,
	y_offset: int,
) -> (
	Tile_Row,
	bool,
) {
	if y_offset < 0 || tile_map.rows <= y_offset {
		return nil, false
	}
	return tile_map.tiles[y_offset * tile_map.cols:][:tile_map.cols], true
}

tile_row_get_ptr :: proc(tile_row: Tile_Row, x_offset: int) -> (^Tile, bool) {
	return slice.get_ptr(tile_row[:], x_offset)
}

tile_map_get_ptr :: proc(
	tile_map: Tile_Map,
	x_offset, y_offset: int,
) -> (
	^Tile,
	bool,
) {
	if row, ok := tile_map_get_row(tile_map, y_offset); ok {
		return tile_row_get_ptr(row, x_offset)
	}
	return nil, false
}

tile_map_get :: proc(
	tile_map: Tile_Map,
	x_offset, y_offset: int,
) -> (
	u8,
	bool,
) {
	if ptr, ok := tile_map_get_ptr(tile_map, x_offset, y_offset); ok {
		return ptr^, true
	}
	return 0, false
}

Tile_Map_Row_Iter :: struct {
	offset: int,
}

Tile_Row_Col_Iter :: struct {
	offset: int,
}

tile_map_next_row :: proc(
	tile_map: Tile_Map,
	iter: ^Tile_Map_Row_Iter,
) -> (
	row: Tile_Row,
	offset: int,
	ok: bool,
) {
	row, ok = tile_map_get_row(tile_map, iter.offset)
	if !ok do return
	offset = iter.offset
	iter.offset += 1
	return
}

tile_row_next_col :: proc(
	tile_row: Tile_Row,
	iter: ^Tile_Row_Col_Iter,
) -> (
	tile: ^Tile,
	offset: int,
	ok: bool,
) {
	tile, ok = tile_row_get_ptr(tile_row, iter.offset)
	if !ok do return
	offset = iter.offset
	iter.offset += 1
	return
}

can_move_in_tile_map :: proc(tile_map: Tile_Map, x, y: f32) -> bool {
	tile_x := int(x)
	tile_y := int(y)
	tile, ok := tile_map_get(tile_map, tile_x, tile_y)
	return ok && tile == 0
}

make_static_tile_map :: proc "contextless" (tiles: ^[$N][$M]Tile) -> Tile_Map {
	return {rows = N, cols = M, tiles = ([^]Tile)(tiles)}
}

// TODO: Move tile size / tile map size here?
// Does it make sense for tile maps to have different sizes?
World_Map :: struct {
	rows, cols: int,
	tile_maps: [^]Tile_Map,
}

world_resolve_tile_map :: proc(
	world: World_Map,
	x, y: f32,
) -> (
	tile_map: ^Tile_Map,
	local_x, local_y: f32,
	ok: bool,
) {
	// TODO: Make sure these work with negative coordinates?
	tile_x := int(x / TILE_MAP_WIDTH)
	tile_y := int(y / TILE_MAP_HEIGHT)

	if tile_y < 0 ||
	   world.rows <= tile_y ||
	   tile_x < 0 ||
	   world.cols <= tile_x {
		return
	}

	tile_map = &world.tile_maps[tile_y * world.cols + tile_x]
	local_x = math.mod(x, TILE_MAP_WIDTH)
	local_y = math.mod(y, TILE_MAP_HEIGHT)
	ok = true
	return
}

make_static_world_map :: proc "contextless" (
	tile_maps: ^[$N][$M]Tile_Map,
) -> World_Map {
	// TODO: Allow heterogenous tile maps?
	for y in 0 ..< N {
		for x in 0 ..< M {
			assert_contextless(tile_maps[y][x].cols == TILE_MAP_WIDTH)
			assert_contextless(tile_maps[y][x].rows == TILE_MAP_HEIGHT)
		}
	}
	return {rows = N, cols = M, tile_maps = ([^]Tile_Map)(tile_maps)}
}

TILE_MAP00 := make_static_tile_map(
	&[TILE_MAP_HEIGHT][TILE_MAP_WIDTH]Tile {
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1},
		{1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1},
		{1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0},
		{1, 1, 0, 1, 0, 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1},
	},
)

TILE_MAP01 := make_static_tile_map(
	&[TILE_MAP_HEIGHT][TILE_MAP_WIDTH]Tile {
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
	},
)

TILE_MAP10 := make_static_tile_map(
	&[TILE_MAP_HEIGHT][TILE_MAP_WIDTH]Tile {
		{1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		{1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
	},
)

TILE_MAP11 := make_static_tile_map(
	&[TILE_MAP_HEIGHT][TILE_MAP_WIDTH]Tile {
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
	},
)

// NOTE: If this is defined before the sub-components, it will be
// zero-initialized
// TODO: Report that as a bug?
global_tiles := [2][2]Tile_Map {
	{TILE_MAP00, TILE_MAP01},
	{TILE_MAP10, TILE_MAP11},
}

// TODO: This leads to a compiler error if `global_tiles` is inlined. Make a
// minimal reproduction and report the error
WORLD_MAP := make_static_world_map(&global_tiles)

TILE_MAP_WIDTH :: 17
TILE_MAP_HEIGHT :: 9

TILE_WIDTH: f32 : 60
TILE_X_OFFSET: f32 : TILE_WIDTH / -2
TILE_HEIGHT: f32 : 60
TILE_Y_OFFSET: f32 : 0

@(export)
handmade_game_render :: proc "contextless" (
	memory: api.Memory,
	fb: Frame_Buffer,
) {
	context = get_game_context(memory)
	state := get_game_state(memory)

	frame_buffer_fill(fb, make_pixel(0xFF00FF))

	cur_tile := WORLD_MAP.tile_maps[0]

	row_iter: Tile_Map_Row_Iter
	for row, row_offset in tile_map_next_row(cur_tile, &row_iter) {
		col_iter: Tile_Row_Col_Iter
		for col, col_offset in tile_row_next_col(row, &col_iter) {
			color: Color
			if col^ == 0 {
				color = make_color_grey(0.1)
			} else {
				color = make_color_grey(0.8)
			}
			render_rect(
				fb,
				x = f32(col_offset) * TILE_WIDTH + TILE_X_OFFSET,
				y = f32(row_offset) * TILE_HEIGHT + TILE_Y_OFFSET,
				w = TILE_WIDTH,
				h = TILE_HEIGHT,
				color = color,
			)
		}
	}

	player_width := 0.6 * TILE_WIDTH
	player_height := 0.75 * TILE_HEIGHT

	render_rect(
		fb,
		x = state.player_x * TILE_WIDTH + TILE_X_OFFSET - player_width / 2.0,
		y = state.player_y * TILE_HEIGHT + TILE_Y_OFFSET - player_height,
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

frame_buffer_row :: proc(fb: Frame_Buffer, y: int) -> []Pixel {
	assert(y >= 0)
	assert(y < int(fb.height))
	return mem.slice_ptr(
		(^Pixel)(uintptr(fb.base) + uintptr(y * int(fb.stride))),
		int(fb.width),
	)
}

frame_buffer_px :: proc(fb: Frame_Buffer, x, y: int) -> ^Pixel {
	assert(x >= 0)
	assert(x < int(fb.width))
	return &frame_buffer_row(fb, y)[x]
}

frame_buffer_get :: proc(fb: Frame_Buffer, x, y: int) -> Pixel {
	return frame_buffer_px(fb, x, y)^
}

frame_buffer_set :: proc(fb: Frame_Buffer, x, y: int, p: Pixel) {
	frame_buffer_px(fb, x, y)^ = p
}

frame_buffer_fill :: proc(fb: Frame_Buffer, p: Pixel) {
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

render_rect :: proc(fb: Frame_Buffer, x, y, w, h: f32, color: Color) {
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
