package game

import "base:intrinsics"
import "core:math/linalg"
import "core:slice"

Global_Chunk_Pos :: [3]i32
Global_Tile_Pos :: [3]i32
Chunk_Tile_Pos :: [2]i32
Local_Tile_Pos :: [2]f32

// World-relative position. Each `[2]T` is a pair of `x` and `y`, with positive
// going to the right and up.
World_Pos :: struct {
	// Position of of the tile
	tile: Global_Tile_Pos,
	// Position within the tile, relative to its center, from [-0.5, 0.5)
	local: Local_Tile_Pos,
	// TODO: Store `local` as f16 when packing?
}

world_pos_sub :: proc(a, b: World_Pos) -> World_Pos {
	return {tile = a.tile - b.tile, local = a.local - b.local}
}

// "Flatten" a world coordinate into a single xy coordinate
// `pos.tile` should be relatively small to avoid precision errors
world_pos_xy :: proc(pos: World_Pos) -> [2]f32 {
	return linalg.to_f32(pos.tile).xy + pos.local
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
	tile_shift_2 := linalg.to_i32(linalg.floor(local_from_corner))
	tile_shift := Global_Tile_Pos{tile_shift_2[0], tile_shift_2[1], 0}
	return {
		tile = pos.tile + tile_shift,
		local = linalg.fract(local_from_corner) - 0.5,
	}
}

// TODO: Fix test cases
/*
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
		World_Pos{tile = {0, 12, 0}, local = {8, 0.5}},
	)

	// TODO: These currently fail due to rounding errors

	testing.expect_value(
		t,
		normalize_pos({local = {-5e-7, 0}}),
		// TODO: Should this go to `CHUNK_SIZE - epsilon` or just round `local` to 0?
		World_Pos {
			tile = {-1, 0, 0},
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
*/

@(private = "file")
in_bounds :: proc(
	v: [$N]$E,
	lower_incl: [N]E,
	upper_excl: [N]E,
) -> bool where intrinsics.type_is_numeric(E) {
	// TODO: Unroll since N is always small?
	for i in 0 ..< N {
		if v[i] < lower_incl[i] || upper_excl[i] <= v[i] {
			return false
		}
	}
	return true
}

pos_is_normalized :: proc(pos: World_Pos) -> bool {
	return in_bounds(pos.local, -0.5, 0.5)
}

offset_pos :: proc(pos: World_Pos, x, y: f32) -> World_Pos {
	pos := pos
	pos.local.x += x
	pos.local.y += y
	return pos
}

Tile :: enum u8 {
	Empty = 0,
	Wall,
	Door,
	Stair_Up,
	Stair_Down,
}

// TODO: Does tile map size ever need to be dynamic?
Tile_Chunk :: struct {
	// TODO: Store custom stride to allow taking subset views?
	// Tiles, stored in row-major order
	tiles: ^[CHUNK_SIZE][CHUNK_SIZE]Tile,
}

Tile_Row :: ^[CHUNK_SIZE]Tile

tile_chunk_get_row :: proc(
	tile_map: Tile_Chunk,
	y_offset: i32,
) -> (
	Tile_Row,
	bool,
) {
	if tile_map.tiles == nil {
		return nil, false
	}
	return slice.get_ptr(tile_map.tiles[:], int(y_offset))
}

tile_row_get_ptr :: proc(tile_row: Tile_Row, x_offset: i32) -> (^Tile, bool) {
	return slice.get_ptr(tile_row[:], int(x_offset))
}

tile_chunk_get_ptr :: proc(
	tile_map: Tile_Chunk,
	offset: [2]i32,
) -> (
	^Tile,
	bool,
) {
	if row, ok := tile_chunk_get_row(tile_map, offset[1]); ok {
		return tile_row_get_ptr(row, offset[0])
	}
	return nil, false
}

tile_chunk_get :: proc(tile_map: Tile_Chunk, offset: [2]i32) -> (Tile, bool) {
	if ptr, ok := tile_chunk_get_ptr(tile_map, offset); ok {
		return ptr^, true
	}
	return .Empty, false
}

make_static_tile_chunk :: proc "contextless" (
	tiles: ^[CHUNK_SIZE][CHUNK_SIZE]Tile,
) -> Tile_Chunk {
	return {tiles}
}

// TODO: Move tile size / tile map size here?
// Does it make sense for tile maps to have different sizes?
Tile_Map :: struct {
	// x,y,z
	size: [3]i32,
	chunks: [^]Tile_Chunk,
}

CHUNK_SIZE_BITS :: 4
CHUNK_SIZE :: 1 << CHUNK_SIZE_BITS
CHUNK_SIZE_MASK :: CHUNK_SIZE - 1

world_pos_split_chunk :: proc(
	tile_pos: Global_Tile_Pos,
) -> (
	Global_Chunk_Pos,
	Chunk_Tile_Pos,
) {
	// TODO: Report issue for supporting `>>` on arrays?
	return [?]i32 {
			tile_pos.x >> CHUNK_SIZE_BITS,
			tile_pos.y >> CHUNK_SIZE_BITS,
			tile_pos.z,
		},
		tile_pos.xy & CHUNK_SIZE_MASK
}

tile_map_get_chunk :: proc(
	tile_map: Tile_Map,
	chunk_pos: Global_Chunk_Pos,
) -> (
	chunk: ^Tile_Chunk,
	ok: bool,
) {
	if !in_bounds(chunk_pos, 0, tile_map.size) do return
	tile_index := int(
		(chunk_pos.z * tile_map.size.y + chunk_pos.y) * tile_map.size.x +
		chunk_pos.x,
	)
	return &tile_map.chunks[tile_index], true
}

tile_map_get_tile_in_chunk :: proc(
	tile_map: Tile_Map,
	chunk_pos: Global_Chunk_Pos,
	// TODO: Naming convention to distinguish between global and chunk-local
	// tile positions
	tile_pos: Chunk_Tile_Pos,
) -> (
	tile: ^Tile,
	ok: bool,
) {
	tile_map := tile_map_get_chunk(tile_map, chunk_pos) or_return
	return tile_chunk_get_ptr(tile_map^, tile_pos)
}

tile_map_get_tile_ptr :: proc(
	tile_map: Tile_Map,
	tile_pos: [3]i32,
) -> (
	^Tile,
	bool,
) {
	chunk_pos, tile_pos := world_pos_split_chunk(tile_pos)
	return tile_map_get_tile_in_chunk(tile_map, chunk_pos, tile_pos)
}

tile_map_get_tile_or_default :: proc(
	tile_map: Tile_Map,
	tile_pos: [3]i32,
	default := Tile.Wall,
) -> Tile {
	if ptr, ok := tile_map_get_tile_ptr(tile_map, tile_pos); ok {
		return ptr^
	} else {
		return default
	}
}

tile_map_get_tile_or_alloc_chunk :: proc(
	tile_map: Tile_Map,
	tile_pos: Global_Tile_Pos,
	allocator := context.allocator,
) -> (
	tile: ^Tile,
	ok: bool,
) {
	chunk_pos, tile_pos := world_pos_split_chunk(tile_pos)
	if tile, ok = tile_map_get_tile_in_chunk(tile_map, chunk_pos, tile_pos);
	   ok {
		return
	}

	chunk: ^Tile_Chunk
	if chunk, ok = tile_map_get_chunk(tile_map, chunk_pos); !ok {
		return
	}

	if new_tiles, err := new(type_of(chunk.tiles^)); err == nil {
		chunk.tiles = new_tiles
	} else {
		return nil, false
	}
	return tile_chunk_get_ptr(chunk^, tile_pos)
}

can_move_in_tile_map_norm :: proc(tile_map: Tile_Map, pos: World_Pos) -> bool {
	assert(pos_is_normalized(pos))
	tile, ok := tile_map_get_tile_ptr(tile_map, pos.tile)
	return ok && tile^ != .Wall
}

can_move_in_tile_map :: proc(tile_map: Tile_Map, pos: World_Pos) -> bool {
	return can_move_in_tile_map_norm(tile_map, normalize_pos(pos))
}

make_static_tile_map :: proc "contextless" (
	tile_maps: ^[$N][$M]Tile_Chunk,
) -> Tile_Map {
	return {size = {M, N}, chunks = ([^]Tile_Chunk)(tile_maps)}
}
