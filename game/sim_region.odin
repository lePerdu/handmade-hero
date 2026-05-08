package game

import "core:mem"

Entity_Common :: struct {
	type: Entity_Type,
	vel: [3]f32,
	face_dir: Direction,
	dim: [2]f32,
	hp_max: i8,
	hp: i8,
	anim_t: f32,
	weapon: Entity_ID,
}

Sim_Region :: struct {
	origin: World_Pos,
	dim: [2]f32,
	entities: []Sim_Entity,
	// TODO: Use custom hash nodes stored inside `Sim_Entity`?
	id_to_sim_map: map[Entity_ID]^Sim_Entity,
}

/// Active, simulated entity
Sim_Entity :: struct {
	using common: Entity_Common,
	storage_id: Entity_ID,
	// Local position, only meaningful for comparisons within a `Sim_Region`
	local_pos: [3]f32,
	// Flag to indicate removal from world chunk storage when the `Sim_Region`
	// ends
	remove: bool,
}

sim_region_begin :: proc(
	state: ^State,
	origin: World_Pos,
	dim: [2]f32,
	allocator := context.temp_allocator,
) -> Sim_Region {
	// TODO: Set upper bound on allocation?
	sim_entities: [dynamic]Sim_Entity
	sim_entities.allocator = allocator

	// For checking positions relative to sim_origin
	sim_rect := make_rect_center_dim([2]f32{}, dim)

	// Min/max tile to search, found by extending the player's position by
	// the collision box

	// TODO: Handle or disallow coordinate wrapping
	// Search for collisions in the rectangle bounding the current and target
	// positions
	min_chunk := offset_pos(origin, -dim / 2).chunk.xy
	max_chunk := offset_pos(origin, dim / 2).chunk.xy

	entity_iter := world_entity_xy_iter(min_chunk, max_chunk, origin.chunk.z)
	for entity_id in world_entity_xy_next(&state.world, &entity_iter) {
		entity := get_entity(state, entity_id) or_continue
		rel_pos := world_pos_sub_xy(entity.pos, origin)
		if rect_contains(sim_rect, rel_pos) {
			_, err := append(
				&sim_entities,
				Sim_Entity {
					common = entity.common,
					storage_id = entity_id,
					local_pos = {rel_pos.x, rel_pos.y, entity.z},
				},
			)
			assert(err == nil)
		}
	}
	shrink(&sim_entities)

	id_to_sim_map, err := make(
		map[Entity_ID]^Sim_Entity,
		len(sim_entities),
		allocator,
	)
	assert(err == nil)
	for &ent in sim_entities {
		id_to_sim_map[ent.storage_id] = &ent
	}

	return {
		origin = origin,
		dim = dim,
		entities = sim_entities[:],
		id_to_sim_map = id_to_sim_map,
	}
}

sim_region_get_by_id :: proc(
	region: Sim_Region,
	id: Entity_ID,
) -> (
	^Sim_Entity,
	bool,
) {
	return region.id_to_sim_map[id]
}

sim_region_end :: proc(state: ^State, region: ^Sim_Region) {
	for sim_ent in region.entities {
		// TODO: Panic if the ID is missing?
		stored_entity := get_entity(state, sim_ent.storage_id) or_continue
		old_chunk := stored_entity.pos.chunk
		stored_entity^ = {
			common = sim_ent.common,
			pos = offset_pos(region.origin, sim_ent.local_pos.xy),
			z = sim_ent.local_pos.z,
		}

		if sim_ent.remove {
			stored_entity.pos = WORLD_POS_INVALID
		}

		if !world_update_entity_chunk(
			&state.world,
			sim_ent.storage_id,
			old_chunk,
			stored_entity.pos.chunk,
			&state.world_arena,
		) {
			panic("failed to migrate entity chunk")
		}
	}
	// Empty the region so that sim_region_end is idempotent
	region^ = {}
}
