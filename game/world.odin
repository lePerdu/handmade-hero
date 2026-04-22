package game

import "base:intrinsics"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

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

world_pos_sub_xy :: proc(a, b: World_Pos) -> [2]f32 {
	return linalg.to_f32(a.tile.xy - b.tile.xy) + a.local - b.local
}

world_pos_dist2 :: proc(a, b: World_Pos) -> f32 {
	delta := world_pos_sub(a, b)
	delta_xy := world_pos_xy(delta)
	return linalg.length2([3]f32{delta_xy.x, delta_xy.y, f32(delta.tile.z)})
}

world_pos_dist :: proc(a, b: World_Pos) -> f32 {
	return math.sqrt(world_pos_dist2(a, b))
}

// Positions must be normalized
world_pos_min :: proc(a, b: World_Pos) -> World_Pos {
	assert(pos_is_normalized(a))
	assert(pos_is_normalized(b))

	axis_min :: proc(
		a_tile, b_tile: i32,
		a_local, b_local: f32,
	) -> (
		tile: i32,
		local: f32,
	) {
		if a_tile < b_tile {
			return a_tile, a_local
		}
		if b_tile < a_tile {
			return b_tile, b_local
		}
		return a_tile, min(a_local, b_local)
	}
	tile_x, local_x := axis_min(a.tile.x, b.tile.x, a.local.x, b.local.x)
	tile_y, local_y := axis_min(a.tile.y, b.tile.y, a.local.y, b.local.y)
	tile_z := min(a.tile.z, b.tile.z)
	return {tile = {tile_x, tile_y, tile_z}, local = {local_x, local_y}}
}

// Positions must be normalized
world_pos_max :: proc(a, b: World_Pos) -> World_Pos {
	assert(pos_is_normalized(a))
	assert(pos_is_normalized(b))

	axis_max :: proc(
		a_tile, b_tile: i32,
		a_local, b_local: f32,
	) -> (
		tile: i32,
		local: f32,
	) {
		if a_tile > b_tile {
			return a_tile, a_local
		}
		if b_tile > a_tile {
			return b_tile, b_local
		}
		return a_tile, max(a_local, b_local)
	}
	tile_x, local_x := axis_max(a.tile.x, b.tile.x, a.local.x, b.local.x)
	tile_y, local_y := axis_max(a.tile.y, b.tile.y, a.local.y, b.local.y)
	tile_z := max(a.tile.z, b.tile.z)
	return {tile = {tile_x, tile_y, tile_z}, local = {local_x, local_y}}
}

world_pos_min_max :: proc(a, b: World_Pos) -> (min, max: World_Pos) {
	return world_pos_min(a, b), world_pos_max(a, b)
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
@(test)
test_norm_pos :: proc(t: ^testing.T) {
	testing.expect_value(t, normalize_pos({}), World_Pos{})
	// Not changed within single box
	testing.expect_value(
		t,
		normalize_pos({local = {0.25, -0.4}}),
		World_Pos{local = {0.25, -0.4}},
	)
	// Wrap at +0.5, not at -0.5
	testing.expect_value(
		t,
		normalize_pos({local = {-0.5, +0.5}}),
		World_Pos{tile = {0, 1, 0}, local = {-0.5, -0.5}},
	)

	HALF_MINUS_EPSILON :: (1 - math.F32_EPSILON) / 2
	HALF_PLUS_EPSILON :: (1 + math.F32_EPSILON) / 2

	testing.expect_value(
		t,
		normalize_pos({local = {HALF_MINUS_EPSILON, -HALF_MINUS_EPSILON}}),
		World_Pos{local = {HALF_MINUS_EPSILON, -HALF_MINUS_EPSILON}},
	)

	testing.expect_value(
		t,
		normalize_pos({local = {HALF_PLUS_EPSILON, -HALF_PLUS_EPSILON}}),
		World_Pos{tile = {+1, -1, 0}, local = {-0.5, HALF_MINUS_EPSILON}},
	)

	testing.expect_value(
		t,
		normalize_pos({local = {-4.5, 91.54}}),
		// Not quite -0.5 due to rounding
		// TODO: Make comparison more reliable?
		World_Pos{tile = {-4, 92, 0}, local = {-0.5, -0.45999908}},
	)

	F32_MAX_INT :: 1 << (math.F32_MANT_DIG - 1) - 1
	testing.expect_value(
		t,
		normalize_pos({local = {-F32_MAX_INT - 0.5, F32_MAX_INT}}),
		World_Pos{tile = {-F32_MAX_INT, F32_MAX_INT, 0}, local = {-0.5, 0}},
	)
}

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

// TODO: Add non-normalized version?
offset_pos :: proc(pos: World_Pos, delta: [2]f32) -> World_Pos {
	res := pos
	res.local += delta
	return normalize_pos(res)
}

Entity_Block :: struct {
	next: ^Entity_Block,
	entities: [dynamic; 16]Entity_ID,
}

Tile_Hash :: distinct u32

CHUNK_SIZE_BITS :: 4
CHUNK_SIZE :: 1 << CHUNK_SIZE_BITS
CHUNK_SIZE_MASK :: CHUNK_SIZE - 1

World_Chunk :: struct {
	// TODO: Figure out where/how to ban wrapping
	pos: [3]i32,
	hash: Tile_Hash,
	first_block: ^Entity_Block,
}

// Invalid pointer used to mark deleted entries
CHUNK_BLOCK_TOMBSTONE :: (^Entity_Block)(uintptr(1))

World :: struct {
	len: int,
	chunk_table: [4096]World_Chunk,
}

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

@(private)
chunk_pos_hash :: proc(pos: [3]i32) -> Tile_Hash {
	// TODO: Real hash function
	return 19 * Tile_Hash(pos.x) + 7 * Tile_Hash(pos.y) + 3 * Tile_Hash(pos.z)
}

world_get_chunk :: proc(
	world: ^World,
	chunk_pos: Global_Chunk_Pos,
) -> (
	chunk: ^World_Chunk,
	ok: bool,
) {
	// Hash used for index
	hash := chunk_pos_hash(chunk_pos)
	assert(math.is_power_of_two(len(world.chunk_table)))
	mask := Tile_Hash(len(world.chunk_table) - 1)

	for offset in 0 ..< Tile_Hash(len(world.chunk_table)) {
		index := (hash + offset) & mask
		chunk := &world.chunk_table[index]
		if chunk.first_block == nil {
			return nil, false
		}
		if chunk.hash == hash && chunk.pos == chunk_pos {
			return chunk, true
		}
	}
	return nil, false
}

world_get_or_alloc_chunk :: proc(
	world: ^World,
	chunk_pos: Global_Chunk_Pos,
	allocator := context.allocator,
) -> (
	chunk: ^World_Chunk,
	ok: bool,
) {
	// Hash used for index
	hash := chunk_pos_hash(chunk_pos)
	assert(math.is_power_of_two(len(world.chunk_table)))
	mask := Tile_Hash(len(world.chunk_table) - 1)

	for offset in 0 ..< Tile_Hash(len(world.chunk_table)) {
		index := (hash + offset) & mask
		chunk := &world.chunk_table[index]
		if chunk.first_block == nil ||
		   chunk.first_block == CHUNK_BLOCK_TOMBSTONE {
			new_block, err := new(Entity_Block, allocator)
			if err != nil {
				return nil, false
			}
			chunk^ = {
				pos = chunk_pos,
				hash = hash,
				first_block = new_block,
			}
			world.len += 1
			return chunk, true
		}
		if chunk.hash == hash && chunk.pos == chunk_pos {
			return chunk, true
		}
	}
	return nil, false
}
