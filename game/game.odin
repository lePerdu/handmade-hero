package game

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:testing"

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
			player_pos = {tile = WINDOW_CENTER, local = 0.5},
		}
	}
	// Re-initialize every time to make it easier to change
	state.world = make_static_world_map(&global_tiles)
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
		player_dir[1] += 1
	}
	if input.keyboard[.A].end_pressed || input.keyboard[.Left].end_pressed {
		player_dir[0] -= 1
	}
	if input.keyboard[.S].end_pressed || input.keyboard[.Down].end_pressed {
		player_dir[1] -= 1
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
		   offset_pos(new_pos, 0, PLAYER_COLLISION_HEIGHT_TILES),
	   ) {
		state.player_pos = normalize_pos(new_pos)
	}
}

// World-relative position. Each `[2]T` is a pair of `x` and `y`, with positive
// going to the right and up.
World_Pos :: struct {
	// Position of of the tile
	tile: [2]i32,
	// Position within the tile, from [0-1)
	local: [2]f32,
	// TODO: Make `local` relative to the center of the tile?
	// TODO: Store `local` as f16 when packing?
}

normalize_pos :: proc(pos: World_Pos) -> World_Pos {
	// TODO: Make this resilient to precision errors (unit test?)
	// - Just have pos_is_normalized compare against epsilon? Might be fine to
	//   let positions be slightly "out of bounds" in most cases.
	// - Do some comparison against epsilon here?
	// - Just run the process multiple times until it's OK? (maybe 2 times would
	//   be always sufficient?)
	// - Temporarily use fixed point?
	// - What about wrap-around? Just wrap to the other side of the world?
	tile_shift := linalg.floor(pos.local)
	return {
		tile = pos.tile + linalg.to_i32(tile_shift),
		local = linalg.fract(pos.local),
	}
}

// TODO: Fix test cases
@(test)
test_norm_pos :: proc(t: ^testing.T) {
	testing.expect_value(t, normalize_pos({}), World_Pos{})
	testing.expect_value(
		t,
		normalize_pos({local = {5e-7, 0}}),
		World_Pos{local = {5e-7, 0}},
	)
	testing.expect_value(
		t,
		normalize_pos({local = {8, 12 * CHUNK_SIZE + 0.5}}),
		World_Pos{tile = {0, 12}, local = {8, 0.5}},
	)

	// TODO: These currently fail due to rounding errors

	testing.expect_value(
		t,
		normalize_pos({local = {-5e-7, 0}}),
		// TODO: Should this go to `CHUNK_SIZE - epsilon` or just round `local` to 0?
		World_Pos {
			tile = {-1, 0},
			local = {CHUNK_SIZE * (1 - math.F32_EPSILON), 0},
		},
	)

	testing.expect_value(
		t,
		normalize_pos({local = {CHUNK_SIZE * (1 + math.F32_EPSILON), 5}}),
		// TODO: Should this go to `CHUNK_SIZE - epsilon` or just round `local` to 0?
		World_Pos{tile = {1, 0}, local = {CHUNK_SIZE * math.F32_EPSILON, 5}},
	)
}

in_bounds :: proc(
	v: [2]$E,
	bounds: [2]E,
) -> bool where intrinsics.type_is_numeric(E) {
	return 0 <= v[0] && v[0] < bounds[0] && 0 <= v[1] && v[1] < bounds[1]
}

pos_is_normalized :: proc(pos: World_Pos) -> bool {
	return in_bounds(pos.local, 1)
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
	tiles: ^[CHUNK_SIZE][CHUNK_SIZE]Tile,
}

Tile_Row :: ^[CHUNK_SIZE]Tile

tile_map_get_row :: proc(
	tile_map: Tile_Map,
	y_offset: i32,
) -> (
	Tile_Row,
	bool,
) {
	return slice.get_ptr(tile_map.tiles[:], int(y_offset))
}

tile_row_get_ptr :: proc(tile_row: Tile_Row, x_offset: i32) -> (^Tile, bool) {
	return slice.get_ptr(tile_row[:], int(x_offset))
}

tile_map_get_ptr :: proc(tile_map: Tile_Map, offset: [2]i32) -> (^Tile, bool) {
	if row, ok := tile_map_get_row(tile_map, offset[1]); ok {
		return tile_row_get_ptr(row, offset[0])
	}
	return nil, false
}

tile_map_get :: proc(tile_map: Tile_Map, offset: [2]i32) -> (u8, bool) {
	if ptr, ok := tile_map_get_ptr(tile_map, offset); ok {
		return ptr^, true
	}
	return 0, false
}

make_static_tile_map :: proc "contextless" (
	tiles: ^[CHUNK_SIZE][CHUNK_SIZE]Tile,
) -> Tile_Map {
	return {tiles}
}

// TODO: Move tile size / tile map size here?
// Does it make sense for tile maps to have different sizes?
World_Map :: struct {
	size: [2]i32,
	tile_maps: [^]Tile_Map,
}

CHUNK_SIZE_BITS :: 4
CHUNK_SIZE :: 1 << CHUNK_SIZE_BITS
CHUNK_SIZE_MASK :: CHUNK_SIZE - 1

world_pos_split_chunk :: proc(tile_pos: [2]i32) -> ([2]i32, [2]i32) {
	// TODO: Report issue for supporting `>>` on arrays?
	return [2]i32 {
			tile_pos[0] >> CHUNK_SIZE_BITS,
			tile_pos[1] >> CHUNK_SIZE_BITS,
		},
		tile_pos & CHUNK_SIZE_MASK
}

world_get_chunk :: proc(
	world: World_Map,
	chunk_pos: [2]i32,
) -> (
	tile_map: ^Tile_Map,
	ok: bool,
) {
	if !in_bounds(chunk_pos, world.size) do return
	tile_index := int(chunk_pos[1] * world.size[0] + chunk_pos[0])
	return &world.tile_maps[tile_index], true
}

world_get_tile_in_chunk :: proc(
	world: World_Map,
	chunk_pos: [2]i32,
	// TODO: Naming convention to distinguish between global and chunk-local
	// tile positions
	tile_pos: [2]i32,
) -> (
	tile: ^Tile,
	ok: bool,
) {
	tile_map := world_get_chunk(world, chunk_pos) or_return
	return tile_map_get_ptr(tile_map^, tile_pos)
}

world_get_tile :: proc(world: World_Map, tile_pos: [2]i32) -> (^Tile, bool) {
	chunk_pos, tile_pos := world_pos_split_chunk(tile_pos)
	return world_get_tile_in_chunk(world, chunk_pos, tile_pos)
}

can_move_in_world_norm :: proc(world: World_Map, pos: World_Pos) -> bool {
	assert(pos_is_normalized(pos))
	tile, ok := world_get_tile(world, pos.tile)
	return ok && tile^ == 0
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
	&[CHUNK_SIZE][CHUNK_SIZE]Tile {
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0},
		{1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1},
		{1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0},
		{1, 1, 0, 1, 0, 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0},
		{1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		{1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0},
	},
)

TILE_MAP01 := make_static_tile_map(
	&[CHUNK_SIZE][CHUNK_SIZE]Tile {
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 0, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1},
	},
)

TILE_MAP10 := make_static_tile_map(
	&[CHUNK_SIZE][CHUNK_SIZE]Tile {
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
	},
)

TILE_MAP11 := make_static_tile_map(
	&[CHUNK_SIZE][CHUNK_SIZE]Tile {
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
	},
)

// NOTE: If this is defined before the sub-components, it will be
// zero-initialized
// TODO: Report that as a bug?
global_tiles := [2][2]Tile_Map {
	{TILE_MAP00, TILE_MAP01},
	{TILE_MAP10, TILE_MAP11},
}

TILE_SIZE_PX :: 60
TILE_OFFSET_PX :: [2]f32{-TILE_SIZE_PX / 2, 0}

PLAYER_WIDTH: f32 : 0.7
PLAYER_HEIGHT: f32 : 1
PLAYER_COLLISION_HEIGHT_TILES: f32 : 0.25

WINDOW_TILES_WIDTH :: 17
WINDOW_TILES_HEIGHT :: 9
WINDOW_CENTER :: [2]i32{WINDOW_TILES_WIDTH / 2, WINDOW_TILES_HEIGHT / 2}

@(export)
handmade_game_render :: proc "contextless" (
	memory: api.Memory,
	fb: Frame_Buffer,
) {
	context = get_game_context(memory)
	state := get_game_state(memory)

	frame_buffer_fill(fb, make_pixel(0xFF00FF))

	assert(pos_is_normalized(state.player_pos))

	window_tile_offset := state.player_pos.tile - WINDOW_CENTER

	for row in 0 ..< i32(WINDOW_TILES_HEIGHT) {
		for col in 0 ..< i32(WINDOW_TILES_WIDTH) {
			window_pos := [2]i32{col, row}
			tile_pos := window_pos + window_tile_offset
			tile_val, ok := world_get_tile(state.world, tile_pos)
			if !ok {
				// Leave the tile blank for now? Wrap the coordinate?
				continue
			}

			color: Color
			if tile_val^ == 0 {
				color = make_color_grey(0.1)
			} else {
				color = make_color_grey(0.8)
			}
			// Debug: show current player tile
			if state.player_pos.tile == tile_pos {
				color = make_color_grey(1.0)
			}
			render_rect_tile(
				fb,
				pos = linalg.to_f32(window_pos),
				size = 1,
				color = color,
			)
		}
	}

	render_rect_tile(
		fb,
		pos = (linalg.to_f32(WINDOW_CENTER) +
			state.player_pos.local -
			{PLAYER_WIDTH / 2, 0}),
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

	// Flip y axis
	y_flipped := f32(fb.height) - pos[1]
	y_max := round_clamp_px(y_flipped, fb.height)
	y_min := round_clamp_px(y_flipped - size[1], fb.height)

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
