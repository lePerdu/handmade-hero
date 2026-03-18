package game

import "base:intrinsics"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:testing"

// World-relative position. Each `[2]T` is a pair of `x` and `y`, with positive
// going to the right and up.
World_Pos :: struct {
	// Position of of the tile
	tile: [2]i32,
	// Position within the tile, relative to its center, from [-0.5, 0.5)
	local: [2]f32,
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
	local_from_corner := pos.local + 0.5
	tile_shift := linalg.floor(local_from_corner)
	return {
		tile = pos.tile + linalg.to_i32(tile_shift),
		local = linalg.fract(local_from_corner) - 0.5,
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

@(private = "file")
in_bounds :: proc(
	v: [2]$E,
	lower_incl: [2]E,
	upper_excl: [2]E,
) -> bool where intrinsics.type_is_numeric(E) {
	return(
		lower_incl[0] <= v[0] &&
		v[0] < upper_excl[0] &&
		lower_incl[1] <= v[1] &&
		v[1] < upper_excl[1] \
	)
}

pos_is_normalized :: proc(pos: World_Pos) -> bool {
	return in_bounds(pos.local, -0.5, 0.5)
}

offset_pos :: proc(pos: World_Pos, x, y: f32) -> World_Pos {
	pos := pos
	pos.local[0] += x
	pos.local[1] += y
	return pos
}

Tile :: u8

// TODO: Does tile map size ever need to be dynamic?
Tile_Chunk :: struct {
	// TODO: Store custom stride to allow taking subset views?
	// Tiles, stored in row-major order
	tiles: ^[CHUNK_SIZE][CHUNK_SIZE]Tile,
}

Tile_Row :: ^[CHUNK_SIZE]Tile

tile_map_get_row :: proc(
	tile_map: Tile_Chunk,
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

tile_map_get_ptr :: proc(
	tile_map: Tile_Chunk,
	offset: [2]i32,
) -> (
	^Tile,
	bool,
) {
	if row, ok := tile_map_get_row(tile_map, offset[1]); ok {
		return tile_row_get_ptr(row, offset[0])
	}
	return nil, false
}

tile_map_get :: proc(tile_map: Tile_Chunk, offset: [2]i32) -> (u8, bool) {
	if ptr, ok := tile_map_get_ptr(tile_map, offset); ok {
		return ptr^, true
	}
	return 0, false
}

make_static_tile_chunk :: proc "contextless" (
	tiles: ^[CHUNK_SIZE][CHUNK_SIZE]Tile,
) -> Tile_Chunk {
	return {tiles}
}

// TODO: Move tile size / tile map size here?
// Does it make sense for tile maps to have different sizes?
Tile_Map :: struct {
	size: [2]i32,
	chunks: [^]Tile_Chunk,
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

tile_map_get_chunk :: proc(
	tile_map: Tile_Map,
	chunk_pos: [2]i32,
) -> (
	chunk: ^Tile_Chunk,
	ok: bool,
) {
	if !in_bounds(chunk_pos, 0, tile_map.size) do return
	tile_index := int(chunk_pos[1] * tile_map.size[0] + chunk_pos[0])
	return &tile_map.chunks[tile_index], true
}

tile_map_get_tile_in_chunk :: proc(
	tile_map: Tile_Map,
	chunk_pos: [2]i32,
	// TODO: Naming convention to distinguish between global and chunk-local
	// tile positions
	tile_pos: [2]i32,
) -> (
	tile: ^Tile,
	ok: bool,
) {
	tile_map := tile_map_get_chunk(tile_map, chunk_pos) or_return
	return tile_map_get_ptr(tile_map^, tile_pos)
}

tile_map_get_tile :: proc(
	tile_map: Tile_Map,
	tile_pos: [2]i32,
) -> (
	^Tile,
	bool,
) {
	chunk_pos, tile_pos := world_pos_split_chunk(tile_pos)
	return tile_map_get_tile_in_chunk(tile_map, chunk_pos, tile_pos)
}

can_move_in_tile_map_norm :: proc(tile_map: Tile_Map, pos: World_Pos) -> bool {
	assert(pos_is_normalized(pos))
	tile, ok := tile_map_get_tile(tile_map, pos.tile)
	return ok && tile^ == 0
}

can_move_in_tile_map :: proc(tile_map: Tile_Map, pos: World_Pos) -> bool {
	return can_move_in_tile_map_norm(tile_map, normalize_pos(pos))
}

make_static_tile_map :: proc "contextless" (
	tile_maps: ^[$N][$M]Tile_Chunk,
) -> Tile_Map {
	return {size = {M, N}, chunks = ([^]Tile_Chunk)(tile_maps)}
}

TILE_MAP00 := make_static_tile_chunk(
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

TILE_MAP01 := make_static_tile_chunk(
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

TILE_MAP10 := make_static_tile_chunk(
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

TILE_MAP11 := make_static_tile_chunk(
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
global_tiles := [2][2]Tile_Chunk {
	{TILE_MAP00, TILE_MAP01},
	{TILE_MAP10, TILE_MAP11},
}
