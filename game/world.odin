package game

import "base:intrinsics"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:testing"

Chunk_Pos :: [3]i32
Local_Pos :: [2]f32

// TODO: Rename to "tiles"?
CHUNK_SIZE_METERS :: 16
// TODO: Rename?
LOCAL_MIN :: -CHUNK_SIZE_METERS / 2
LOCAL_MAX :: CHUNK_SIZE_METERS / 2

// World-relative position
World_Pos :: struct {
	chunk: Chunk_Pos,
	// Position within the chunk, relative to its center, from
	// [0, CHUNK_SIZE_METERS)
	local: Local_Pos,
}

make_world_pos_i32 :: proc(tile_pos: [3]i32) -> World_Pos {
	// TODO: Pre-normalize incoming integer to avoid rounding errors
	// NOTE: tile_pos.z is not handled correctly.
	// TODO: Fix this by making `local` 3D?
	return normalize_pos(
		{
			chunk = {0, 0, tile_pos.z / CHUNK_SIZE_METERS},
			local = linalg.to_f32(tile_pos.xy),
		},
	)
}

make_world_pos_i64 :: proc(tile_pos: [3]i64) -> World_Pos {
	// NOTE: tile_pos.z is not handled correctly.
	// TODO: Fix this by making `local` 3D?
	return normalize_pos(
		{
			chunk = {0, 0, i32(tile_pos.z / CHUNK_SIZE_METERS)},
			local = linalg.to_f32(tile_pos.xy),
		},
	)
}

make_world_pos_f32 :: proc(tile_pos: [3]f32) -> World_Pos {
	// NOTE: tile_pos.z is not handled correctly.
	// TODO: Fix this by making `local` 3D?
	return normalize_pos(
		{
			chunk = {0, 0, i32(tile_pos.z / CHUNK_SIZE_METERS)},
			local = tile_pos.xy,
		},
	)
}

make_world_pos :: proc {
	make_world_pos_i32,
	make_world_pos_i64,
	make_world_pos_f32,
}

// TODO: Return distinct type that can be accepted by world_pos_xy?
world_pos_sub :: proc(a, b: World_Pos) -> World_Pos {
	return {chunk = a.chunk - b.chunk, local = a.local - b.local}
}

world_pos_tile :: proc(pos: World_Pos) -> [3]i64 {
	return(
		CHUNK_SIZE_METERS * linalg.to_i64(pos.chunk) +
		{i64(math.round(pos.local.x)), i64(math.round(pos.local.y)), 0} \
	)
}

world_pos_round :: proc(pos: World_Pos) -> World_Pos {
	return {chunk = pos.chunk, local = linalg.round(pos.local)}
}

// "Flatten" a world coordinate into a single xy coordinate
// `pos.chunk` should be relatively small to avoid precision errors
world_pos_xy :: proc(pos: World_Pos) -> Local_Pos {
	return CHUNK_SIZE_METERS * linalg.to_f32(pos.chunk).xy + pos.local
}

world_pos_sub_xy :: proc(a, b: World_Pos) -> [2]f32 {
	return(
		CHUNK_SIZE_METERS * linalg.to_f32(a.chunk.xy - b.chunk.xy) +
		(a.local - b.local) \
	)
}

world_pos_dist2 :: proc(a, b: World_Pos) -> f32 {
	delta := world_pos_sub(a, b)
	delta_xy := world_pos_xy(delta)
	return linalg.length2(
		[3]f32{delta_xy.x, delta_xy.y, CHUNK_SIZE_METERS * f32(delta.chunk.z)},
	)
}

world_pos_dist :: proc(a, b: World_Pos) -> f32 {
	return math.sqrt(world_pos_dist2(a, b))
}

// Positions must be normalized
world_pos_min :: proc(a, b: World_Pos) -> World_Pos {
	assert(pos_is_normalized(a))
	assert(pos_is_normalized(b))

	axis_min :: proc(
		a_chunk, b_chunk: i32,
		a_local, b_local: f32,
	) -> (
		chunk: i32,
		local: f32,
	) {
		if a_chunk < b_chunk {
			return a_chunk, a_local
		}
		if b_chunk < a_chunk {
			return b_chunk, b_local
		}
		return a_chunk, min(a_local, b_local)
	}
	chunk_x, local_x := axis_min(a.chunk.x, b.chunk.x, a.local.x, b.local.x)
	chunk_y, local_y := axis_min(a.chunk.y, b.chunk.y, a.local.y, b.local.y)
	chunk_z := min(a.chunk.z, b.chunk.z)
	return {chunk = {chunk_x, chunk_y, chunk_z}, local = {local_x, local_y}}
}

// Positions must be normalized
world_pos_max :: proc(a, b: World_Pos) -> World_Pos {
	assert(pos_is_normalized(a))
	assert(pos_is_normalized(b))

	axis_max :: proc(
		a_chunk, b_chunk: i32,
		a_local, b_local: f32,
	) -> (
		chunk: i32,
		local: f32,
	) {
		if a_chunk > b_chunk {
			return a_chunk, a_local
		}
		if b_chunk > a_chunk {
			return b_chunk, b_local
		}
		return a_chunk, max(a_local, b_local)
	}
	chunk_x, local_x := axis_max(a.chunk.x, b.chunk.x, a.local.x, b.local.x)
	chunk_y, local_y := axis_max(a.chunk.y, b.chunk.y, a.local.y, b.local.y)
	chunk_z := max(a.chunk.z, b.chunk.z)
	return {chunk = {chunk_x, chunk_y, chunk_z}, local = {local_x, local_y}}
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
	chunk_shift_xy := linalg.floor(pos.local / CHUNK_SIZE_METERS)
	return {
		chunk = pos.chunk + {i32(chunk_shift_xy.x), i32(chunk_shift_xy.y), 0},
		local = pos.local - chunk_shift_xy * CHUNK_SIZE_METERS,
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
	// Wrap at +max but not at -min
	testing.expect_value(
		t,
		normalize_pos({local = {LOCAL_MIN, +LOCAL_MAX}}),
		World_Pos{chunk = {0, 1, 0}, local = {LOCAL_MIN, LOCAL_MIN}},
	)

	HALF_MINUS_EPSILON :: (1 - math.F32_EPSILON) / 2 * CHUNK_SIZE_METERS
	HALF_PLUS_EPSILON :: (1 + math.F32_EPSILON) / 2 * CHUNK_SIZE_METERS

	testing.expect_value(
		t,
		normalize_pos({local = {HALF_MINUS_EPSILON, -HALF_MINUS_EPSILON}}),
		World_Pos{local = {HALF_MINUS_EPSILON, -HALF_MINUS_EPSILON}},
	)

	testing.expect_value(
		t,
		normalize_pos({local = {HALF_PLUS_EPSILON, -HALF_PLUS_EPSILON}}),
		World_Pos {
			chunk = {+1, -1, 0},
			local = {LOCAL_MIN, HALF_MINUS_EPSILON},
		},
	)

	testing.expect_value(
		t,
		normalize_pos(
			{local = {-4.5 * CHUNK_SIZE_METERS, 91.54 * CHUNK_SIZE_METERS}},
		),
		// Not quite LOCAL_MIN due to rounding
		// TODO: Make comparison more reliable?
		World_Pos{chunk = {-4, 92, 0}, local = {LOCAL_MIN, -0.45999908}},
	)

	F32_MAX_INT :: 1 << (math.F32_MANT_DIG - 1) - 1
	testing.expect_value(
		t,
		normalize_pos({local = {-F32_MAX_INT - LOCAL_MAX, F32_MAX_INT}}),
		World_Pos {
			chunk = {-F32_MAX_INT, F32_MAX_INT, 0},
			local = {LOCAL_MIN, 0},
		},
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
	return in_bounds(pos.local, 0, CHUNK_SIZE_METERS)
}

// TODO: Add non-normalized version?
offset_pos :: proc(pos: World_Pos, delta: [2]f32) -> World_Pos {
	res := pos
	res.local += delta
	return normalize_pos(res)
}

Entity_Block :: struct {
	next: ^Entity_Block,
	// TODO: Don't store length here since every non-head block should always
	// be full?
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

@(private)
chunk_pos_hash :: proc(pos: Chunk_Pos) -> Tile_Hash {
	// TODO: Real hash function
	return 19 * Tile_Hash(pos.x) + 7 * Tile_Hash(pos.y) + 3 * Tile_Hash(pos.z)
}

world_get_chunk :: proc(
	world: ^World,
	chunk_pos: Chunk_Pos,
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
	chunk_pos: Chunk_Pos,
	arena: ^mem.Arena,
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
			new_block, err := new(Entity_Block, mem.arena_allocator(arena))
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

world_chunk_alloc_entity :: proc(
	chunk: ^World_Chunk,
	arena: ^mem.Arena,
) -> (
	id_ref: ^Entity_ID,
	ok: bool,
) {
	if chunk.first_block == nil ||
	   len(chunk.first_block.entities) == cap(chunk.first_block.entities) {
		if new_block, err := new(Entity_Block, mem.arena_allocator(arena));
		   err == nil {
			new_block^ = {
				next = chunk.first_block,
			}
			chunk.first_block = new_block
		} else {
			return
		}
	}
	if _, ok = append_nothing(&chunk.first_block.entities); ok {
		id_ref = &chunk.first_block.entities[len(chunk.first_block.entities) - 1]
		return
	} else {
		panic("expected append to succeed")
	}
}

world_chunk_add_entity :: proc(
	chunk: ^World_Chunk,
	id: Entity_ID,
	arena: ^mem.Arena,
) -> (
	ok: bool,
) {
	id_ref := world_chunk_alloc_entity(chunk, arena) or_return
	id_ref^ = id
	return true
}

world_chunk_remove_entity :: proc(
	chunk: ^World_Chunk,
	id: Entity_ID,
	arena: ^mem.Arena,
) -> (
	ok: bool,
) {
	for block := chunk.first_block; block != nil; block = block.next {
		for test_id, index in block.entities {
			if test_id == id {
				block.entities[index] =
					chunk.first_block.entities[len(chunk.first_block.entities) - 1]
				pop(&chunk.first_block.entities)
				if len(chunk.first_block.entities) == 0 {
					old_block := chunk.first_block
					chunk.first_block = chunk.first_block.next
					// TODO: How to properly "free" blocks?
					free(old_block, mem.arena_allocator(arena))
				}
				return true
			}
		}
	}
	return false
}

world_update_entity_chunk :: proc(
	world: ^World,
	id: Entity_ID,
	old_chunk_pos, new_chunk_pos: Chunk_Pos,
	arena: ^mem.Arena,
) -> (
	ok: bool,
) {
	if old_chunk_pos == new_chunk_pos do return true
	if old_chunk, exists := world_get_chunk(world, old_chunk_pos); exists {
		// Doesn't matter if it doesn't exist
		_ = world_chunk_remove_entity(old_chunk, id, arena)
	}
	new_chunk := world_get_or_alloc_chunk(
		world,
		new_chunk_pos,
		arena,
	) or_return
	return world_chunk_add_entity(new_chunk, id, arena)
}
