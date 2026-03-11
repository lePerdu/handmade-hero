package game

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"

import "api"

Frame_Buffer :: api.Frame_Buffer

State :: struct {
	// Relies on game memory being 0-initialized
	initialized: bool,
	world: World_Map,
	player_pos: World_Pos,
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
			world = make_static_world_map(&global_tiles),
			player_pos = {
				chunk = {0, 0},
				local = {f32(TILE_MAP_WIDTH) / 2, f32(TILE_MAP_HEIGHT) / 2},
			},
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
	player_dir: [2]f32
	PLAYER_SPEED: f32 : 4 // tile/sec
	player_delta: f32 = PLAYER_SPEED * 1e-9 * f32(input.dt_ns)

	if input.keyboard[.W].end_pressed || input.keyboard[.Up].end_pressed {
		player_dir[1] -= 1
	}
	if input.keyboard[.A].end_pressed || input.keyboard[.Left].end_pressed {
		player_dir[0] -= 1
	}
	if input.keyboard[.S].end_pressed || input.keyboard[.Down].end_pressed {
		player_dir[1] += 1
	}
	if input.keyboard[.D].end_pressed || input.keyboard[.Right].end_pressed {
		player_dir[0] += 1
	}

	// Scale diagonal movement
	coord_delta := player_delta
	if player_dir[0] != 0 && player_dir[1] != 0 {
		coord_delta *= math.sqrt(f32(0.5))
	}

	new_pos := state.player_pos
	new_pos.local += player_dir * coord_delta

	if can_move_in_world(
		   state.world,
		   offset_pos(new_pos, -PLAYER_WIDTH / 2, 0),
	   ) &&
	   can_move_in_world(
		   state.world,
		   offset_pos(new_pos, PLAYER_WIDTH / 2, 0),
	   ) &&
	   can_move_in_world(
		   state.world,
		   offset_pos(new_pos, 0, -PLAYER_COLLISION_HEIGHT_TILES),
	   ) {
		state.player_pos = normalize_pos(new_pos)
	}
}

World_Pos :: struct {
	// Index of of the current tile map (in tile-map-sized chunks)
	chunk: [2]i32,
	// Offset within the tile map
	local: [2]f32,
}

normalize_pos :: proc(pos: World_Pos) -> World_Pos {
	// TODO: Make this resilient to precision errors (unit test?)
	tile_shift := linalg.floor(pos.local / TILE_MAP_SIZE)
	return {
		chunk = pos.chunk + linalg.to_i32(tile_shift),
		local = pos.local - tile_shift * TILE_MAP_SIZE,
	}
}

in_bounds :: proc(
	v: [2]$E,
	bounds: [2]E,
) -> bool where intrinsics.type_is_numeric(E) {
	return 0 <= v[0] && v[0] < bounds[0] && 0 <= v[1] && v[1] < bounds[1]
}

pos_is_normalized :: proc(pos: World_Pos) -> bool {
	return in_bounds(pos.local, TILE_MAP_SIZE)
}

offset_pos :: proc(pos: World_Pos, x, y: f32) -> World_Pos {
	pos := pos
	pos.local[0] += x
	pos.local[1] += y
	return pos
}

Tile :: u8

// TODO: Does tile map size ever need to be dynamic?
Tile_Map :: struct {
	// TODO: Store custom stride to allow taking subset views?
	// Tiles, stored in row-major order
	tiles: ^[TILE_MAP_HEIGHT][TILE_MAP_WIDTH]Tile,
}

Tile_Row :: ^[TILE_MAP_WIDTH]Tile

tile_map_get_row :: proc(
	tile_map: Tile_Map,
	y_offset: int,
) -> (
	Tile_Row,
	bool,
) {
	return slice.get_ptr(tile_map.tiles[:], y_offset)
}

tile_row_get_ptr :: proc(tile_row: Tile_Row, x_offset: int) -> (^Tile, bool) {
	return slice.get_ptr(tile_row[:], x_offset)
}

tile_map_get_ptr :: proc(tile_map: Tile_Map, offset: [2]int) -> (^Tile, bool) {
	if row, ok := tile_map_get_row(tile_map, offset[1]); ok {
		return tile_row_get_ptr(row, offset[0])
	}
	return nil, false
}

tile_map_get :: proc(tile_map: Tile_Map, offset: [2]int) -> (u8, bool) {
	if ptr, ok := tile_map_get_ptr(tile_map, offset); ok {
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

can_move_in_tile_map :: proc(tile_map: Tile_Map, pos: [2]f32) -> bool {
	tile_pos := linalg.to_int(pos)
	tile, ok := tile_map_get(tile_map, tile_pos)
	return ok && tile == 0
}

make_static_tile_map :: proc "contextless" (
	tiles: ^[TILE_MAP_HEIGHT][TILE_MAP_WIDTH]Tile,
) -> Tile_Map {
	return {tiles}
}

// TODO: Move tile size / tile map size here?
// Does it make sense for tile maps to have different sizes?
World_Map :: struct {
	size: [2]i32,
	tile_maps: [^]Tile_Map,
}

world_get_tile :: proc(
	world: World_Map,
	tile_pos: [2]i32,
) -> (
	tile_map: ^Tile_Map,
	ok: bool,
) {
	if !in_bounds(tile_pos, world.size) do return
	tile_index := int(tile_pos[1] * world.size[0] + tile_pos[0])
	return &world.tile_maps[tile_index], true
}

can_move_in_world_norm :: proc(
	world: World_Map,
	pos: World_Pos,
) -> bool {
	assert(pos_is_normalized(pos))
	tile, ok := world_get_tile(world, pos.chunk)
	if !ok do return false
	return can_move_in_tile_map(tile^, pos.local)
}

can_move_in_world :: proc(world: World_Map, pos: World_Pos) -> bool {
	return can_move_in_world_norm(world, normalize_pos(pos))
}

make_static_world_map :: proc "contextless" (
	tile_maps: ^[$N][$M]Tile_Map,
) -> World_Map {
	return {size = {M, N}, tile_maps = ([^]Tile_Map)(tile_maps)}
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

TILE_MAP_WIDTH :: 17
TILE_MAP_HEIGHT :: 9
TILE_MAP_SIZE :: [2]f32{TILE_MAP_WIDTH, TILE_MAP_HEIGHT}

TILE_SIZE_PX: f32 : 60
TILE_OFFSET_PX :: [2]f32{-TILE_SIZE_PX / 2, 0}

PLAYER_WIDTH: f32 : 0.7
PLAYER_HEIGHT: f32 : 1
PLAYER_COLLISION_HEIGHT_TILES: f32 : 0.25

@(export)
handmade_game_render :: proc "contextless" (
	memory: api.Memory,
	fb: Frame_Buffer,
) {
	context = get_game_context(memory)
	state := get_game_state(memory)

	frame_buffer_fill(fb, make_pixel(0xFF00FF))

	assert(pos_is_normalized(state.player_pos))
	cur_tile, ok := world_get_tile(state.world, state.player_pos.chunk)
	if !ok {
		// TODO: ???
		panic("player out of bounds!")
	}

	player_tile := linalg.to_int(linalg.floor(state.player_pos.local))

	row_iter: Tile_Map_Row_Iter
	for row, row_offset in tile_map_next_row(cur_tile^, &row_iter) {
		col_iter: Tile_Row_Col_Iter
		for col, col_offset in tile_row_next_col(row, &col_iter) {
			color: Color
			if col^ == 0 {
				color = make_color_grey(0.1)
			} else {
				color = make_color_grey(0.8)
			}
			// Debug: show current player tile
			if player_tile[0] == col_offset && player_tile[1] == row_offset {
				color = make_color_grey(1.0)
			}
			render_rect_tile(
				fb,
				pos = linalg.to_f32([2]int{col_offset, row_offset}),
				size = 1,
				color = color,
			)
		}
	}

	render_rect_tile(
		fb,
		pos = state.player_pos.local - {PLAYER_WIDTH / 2, PLAYER_HEIGHT},
		size = {PLAYER_WIDTH, PLAYER_HEIGHT},
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

render_rect :: proc(fb: Frame_Buffer, pos, size: [2]f32, color: Color) {
	pixel := make_pixel(color)

	x_min := round_clamp_px(pos[0], fb.width)
	x_max := round_clamp_px(pos[0] + size[0], fb.width)

	y_min := round_clamp_px(pos[1], fb.height)
	y_max := round_clamp_px(pos[1] + size[1], fb.height)

	for y_px in y_min ..< y_max {
		row := frame_buffer_row(fb, y_px)
		row_part := row[x_min:x_max]
		slice.fill(row_part, pixel)
	}
}

render_rect_tile :: proc(fb: Frame_Buffer, pos, size: [2]f32, color: Color) {
	render_rect(
		fb,
		pos = pos * TILE_SIZE_PX + TILE_OFFSET_PX,
		size = size * TILE_SIZE_PX,
		color = color,
	)
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
