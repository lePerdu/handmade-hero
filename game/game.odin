package game

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:slice"

import "api"

Frame_Buffer :: api.Frame_Buffer

State :: struct {
	// Relies on game memory being 0-initialized
	initialized: bool,
	world: World,
	camera_pos: World_Pos,
	camera_follow_entity_index: Entity_ID,
	controller_to_player_entity: [VIRT_CONTROLLER_COUNT]Entity_ID,
	world_arena: mem.Arena,
	background_texture: Bmp_Image,
	tree_texture: Bmp_Image,
	hero_textures: [Direction]Player_Textures,
	hero_shadow_texture: Bmp_Image,
	// Entities in a region near the camera that are being simulated, checked
	// for collisions, and rendered
	// TODO: Store sim region in temp memory?
	sim_entities: [dynamic]Sim_Entity,
	entities: [dynamic; MAX_ENTITY_COUNT]Entity,
}

MAX_ENTITY_COUNT :: 15_000
MAX_SIM_ENTITY_COUNT :: 256

Entity_ID :: distinct u32
ENTITY_NIL: Entity_ID : 0

Entity_Type :: enum {
	None = 0,
	Hero,
	Wall,
	Monster,
	Familiar,
}

entity_can_collide :: proc(t: Entity_Type) -> bool {
	#partial switch t {
	case .Hero, .Monster, .Familiar, .Wall:
		return true
	case:
		return false
	}
}

Entity :: struct {
	type: Entity_Type,
	pos: World_Pos,
	vel: [3]f32,
	// TODO: Integrate this into `pos`
	z: f32,
	face_dir: Direction,
	dim: [2]f32,
	hp_max: i8,
	hp: i8,
	bob_phase: f32,
}

/// Active, simulated entity
Sim_Entity :: struct {
	id: Entity_ID,
}

Player_Textures :: struct {
	head: Bmp_Image,
	torso: Bmp_Image,
	cape: Bmp_Image,
	align_px: [2]f32,
}

Direction :: enum {
	Right,
	Back,
	Left,
	Front,
}

Rect :: struct($T: typeid) where intrinsics.type_is_numeric(T) {
	min: [2]T,
	dim: [2]T,
}

make_rect_min_dim :: proc(min, dim: [2]$T) -> Rect(T) {
	assert(dim.x >= 0 && dim.y >= 0)
	return {min = min, dim = dim}
}

make_rect_min_max :: proc(min, max: [2]$T) -> Rect(T) {
	assert(max.x >= min.x && max.y >= min.y)
	return {min = min, dim = max - min}
}

// TODO: This seems dangerous for integer types...
make_rect_center_dim :: proc(center, dim: [2]$T) -> Rect(T) {
	assert(dim.x >= 0 && dim.y >= 0)
	return {min = center - dim / 2, dim = dim}
}

rect_min :: proc(r: Rect($T)) -> [2]T {
	return r.min
}

rect_max :: proc(r: Rect($T)) -> [2]T {
	return r.min + r.dim
}

rect_min_max :: proc(r: Rect($T)) -> (min, max: [2]T) {
	return rect_min(r), rect_max(r)
}

rect_dim :: proc(r: Rect($T)) -> [2]T {
	return r.dim
}

rect_center :: proc(r: Rect($T)) -> [2]T {
	return r.min + r.dim / 2
}

rect_scale :: proc(r: Rect($T), scalar: T) -> Rect(T) {
	return {min = r.min * scalar, dim = r.dim * scalar}
}

rect_offset :: proc(r: Rect($T), offset: [2]T) -> Rect(T) {
	return {min = r.min + offset, dim = r.dim}
}

rect_contains :: proc(r: Rect($T), pos: [2]T) -> bool {
	min, max := rect_min_max(r)
	return(
		(min.x <= pos.x && pos.x < max.x) &&
		(min.y <= pos.y && pos.y < max.y) \
	)
}

// Include full/left/right keyboard virtual controllers
KEYBOARD_FULL_INDEX :: len(api.Input{}.controllers)
KEYBOARD_LEFT_INDEX :: KEYBOARD_FULL_INDEX + 1
KEYBOARD_RIGHT_INDEX :: KEYBOARD_FULL_INDEX + 2
VIRT_CONTROLLER_COUNT :: len(api.Input{}.controllers) + 3

Controller :: struct {
	// TODO: Store pointer to avoid copying?
	using _: api.Controller,
	index: int,
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

debug_load_bmp :: proc(memory: api.Memory, file_path: string) -> Bmp_Image {
	contents := memory.debug.read_file(memory.debug.data, file_path)

	background: Bmp_Image
	if img, ok := load_bmp(contents); ok {
		return img
	} else {
		panic("failed to load background")
	}
}

get_game_state :: proc(memory: api.Memory) -> ^State {
	assert(len(memory.persistent) >= size_of(State))
	state := (^State)(raw_data(memory.persistent))
	if !state.initialized {
		state^ = {}
		mem.arena_init(&state.world_arena, memory.persistent[size_of(State):])
		state.camera_pos = {}

		// TODO: Why is this necessary?
		nil_entity, nil_entity_id :=
			add_entity(state) or_else panic("failed to create nil entity")
		assert(nil_entity_id == ENTITY_NIL)
		assert(nil_entity.type == .None)

		gen_world(state)

		player_entity, player_id, ok := add_entity(state)
		if ok {
			player_entity^ = {
				type = .Hero,
				face_dir = .Front,
				pos = make_world_pos_f32(
					{VIEW_TILES_WIDTH / 3, VIEW_TILES_HEIGHT / 3, 0},
				),
				dim = PLAYER_COLLISION_SIZE,
				hp_max = 3,
				hp = 3,
			}
			if ok := world_add_entity(
				&state.world,
				player_id,
				player_entity.pos.chunk,
				&state.world_arena,
			); !ok {
				panic("failed to add player to world chunk")
			}
			state.controller_to_player_entity[KEYBOARD_FULL_INDEX] = player_id
			state.camera_follow_entity_index = player_id
		} else {
			panic("failed to add player entity")
		}

		if monster_entity, monster_id, ok := add_entity(state); ok {
			monster_entity^ = {
				type = .Monster,
				face_dir = .Front,
				pos = make_world_pos_f32(
					{VIEW_TILES_WIDTH * 2 / 3, VIEW_TILES_HEIGHT * 2 / 3, 0},
				),
				dim = PLAYER_COLLISION_SIZE,
				hp_max = 3,
				hp = 3,
			}
			if ok := world_add_entity(
				&state.world,
				monster_id,
				monster_entity.pos.chunk,
				&state.world_arena,
			); !ok {
				panic("failed to add player to monster chunk")
			}
		} else {
			panic("failed to add monster entity")
		}

		add_familiar :: proc(state: ^State, pos: [2]f32) {
			if familiar_entity, familiar_id, ok := add_entity(state); ok {
				familiar_entity^ = {
					type = .Familiar,
					face_dir = .Front,
					pos = make_world_pos_f32({pos.x, pos.y, 0}),
					dim = PLAYER_COLLISION_SIZE,
				}
				if ok := world_add_entity(
					&state.world,
					familiar_id,
					familiar_entity.pos.chunk,
					&state.world_arena,
				); !ok {
					panic("failed to add player to familiar chunk")
				}
			} else {
				panic("failed to add familiar entity")
			}
		}
		add_familiar(
			state,
			{
				rand.float32_range(1, WINDOW_TILES_WIDTH - 1),
				rand.float32_range(1, WINDOW_TILES_WIDTH - 1),
			},
		)

		state.background_texture = debug_load_bmp(
			memory,
			"assets/early_data/test/test_background.bmp",
		)
		state.tree_texture = debug_load_bmp(
			memory,
			"assets/early_data/test2/tree01.bmp",
		)

		state.hero_textures[.Right] = load_hero_textures(memory, "right")
		state.hero_textures[.Back] = load_hero_textures(memory, "back")
		state.hero_textures[.Left] = load_hero_textures(memory, "left")
		state.hero_textures[.Front] = load_hero_textures(memory, "front")
		state.hero_shadow_texture = debug_load_bmp(
			memory,
			"assets/early_data/test/test_hero_shadow.bmp",
		)

		state.initialized = true
	}
	return state
}

load_hero_textures :: proc(
	memory: api.Memory,
	dir: string,
) -> Player_Textures {
	head := debug_load_bmp(
		memory,
		fmt.tprintf("assets/early_data/test/test_hero_{}_head.bmp", dir),
	)
	cape := debug_load_bmp(
		memory,
		fmt.tprintf("assets/early_data/test/test_hero_{}_cape.bmp", dir),
	)
	torso := debug_load_bmp(
		memory,
		fmt.tprintf("assets/early_data/test/test_hero_{}_torso.bmp", dir),
	)
	return {
		head = head,
		cape = cape,
		torso = torso,
		align_px = {f32(torso.width) / 2, 35},
	}
}

gen_world :: proc(state: ^State) {
	SCREENS_X :: 128
	SCREENS_Y :: 128
	// SCREEN_COUNT :: 2

	mem.arena_free_all(&state.world_arena)
	context.allocator = mem.arena_allocator(&state.world_arena)

	state.world = {}

	rand.reset(2)
	screen_x, screen_y, screen_z: i32
	door_left, door_right, door_bottom, door_top, stair, stair_exit: bool
	// NOTE: This may generate partial worlds if it runs out of memory
	gen_loop: for cap(state.entities) - len(state.entities) >=
	    16 + (VIEW_TILES_WIDTH + VIEW_TILES_HEIGHT * 2) {
		// TODO: Custom RNG
		// Can't add a stair if there is already a stair exit here
		r := rand.uint_max(stair_exit ? 2 : 2)
		switch r {
		case 0:
			door_right = true
		case 1:
			door_top = true
		case 2:
			stair = true
		}
		door_up := (stair || stair_exit) && screen_z == 0
		door_down := (stair || stair_exit) && screen_z == 1

		for y in 0 ..< i32(VIEW_TILES_HEIGHT) {
			for x in 0 ..< i32(VIEW_TILES_WIDTH) {
				pos := [3]i32 {
					screen_x * VIEW_TILES_WIDTH + x,
					screen_y * VIEW_TILES_HEIGHT + y,
					screen_z,
				}
				chunk_pos := make_world_pos(pos).chunk
				chunk, ok := world_get_or_alloc_chunk(
					&state.world,
					chunk_pos,
					&state.world_arena,
				)
				if !ok do break gen_loop
				tile: Entity_Type

				// TODO: Add door and stair entities
				if x == 0 {
					if y == VIEW_TILES_HEIGHT / 2 && door_left {
						// tile = .Door
					} else {
						tile = .Wall
					}
				} else if x == VIEW_TILES_WIDTH - 1 {
					if y == VIEW_TILES_HEIGHT / 2 && door_right {
						// tile = .Door
					} else {
						tile = .Wall
					}
				} else if y == 0 {
					if x == VIEW_TILES_WIDTH / 2 && door_bottom {
						// tile = .Door
					} else {
						tile = .Wall
					}
				} else if y == VIEW_TILES_HEIGHT - 1 {
					if x == VIEW_TILES_WIDTH / 2 && door_top {
						// tile = .Door
					} else {
						tile = .Wall
					}
				} else if x == VIEW_TILES_WIDTH / 2 &&
				   y == VIEW_TILES_HEIGHT / 2 {
					if door_up {
						// tile = .Stair_Up
					} else if door_down {
						// tile = .Stair_Down
					}
				}

				// TODO: Add other types of entities
				if tile == .Wall {
					add_wall(state, chunk, pos) or_break gen_loop
				}
			}
		}

		door_left = door_right
		door_bottom = door_top
		stair_exit = stair
		door_right = false
		door_top = false
		stair = false

		switch r {
		case 0:
			screen_x += 1
		case 1:
			screen_y += 1
		case 2:
			screen_z = (screen_z + 1) % 2
		}
	}
}

add_wall :: proc(
	state: ^State,
	chunk: ^World_Chunk,
	tile_pos: [3]i32,
) -> (
	entity: ^Entity,
	id: Entity_ID,
	ok: bool,
) {
	chunk_id_ref := world_chunk_alloc_entity(
		chunk,
		&state.world_arena,
	) or_return
	entity, id = add_entity(state) or_return
	chunk_id_ref^ = id
	entity^ = {
		type = .Wall,
		pos = make_world_pos(tile_pos),
		dim = 1,
	}
	ok = true
	return
}

keyboard_controller_full :: proc(
	keyboard: api.Keyboard_Input,
) -> api.Controller {
	return {
		buttons = {
			.Move_Up = keyboard[.W],
			.Move_Left = keyboard[.A],
			.Move_Down = keyboard[.S],
			.Move_Right = keyboard[.D],
			.Action_Up = keyboard[.Up],
			.Action_Left = keyboard[.Left],
			.Action_Down = keyboard[.Down],
			.Action_Right = keyboard[.Right],
			.Back = keyboard[.Backspace],
			.Start = keyboard[.Space],
			.Shoulder_Left = keyboard[.Q],
			.Shoulder_Right = keyboard[.E],
		},
	}
}

keyboard_controller_left :: proc(
	keyboard: api.Keyboard_Input,
) -> api.Controller {
	return {
		buttons = {
			.Move_Up = keyboard[.W],
			.Move_Left = keyboard[.A],
			.Move_Down = keyboard[.S],
			.Move_Right = keyboard[.D],
			.Back = keyboard[.Tab],
			.Start = keyboard[.Space],
			.Action_Up = {},
			.Action_Left = {},
			.Action_Down = {},
			.Action_Right = {},
			.Shoulder_Left = {},
			.Shoulder_Right = {},
		},
	}
}

keyboard_controller_right :: proc(
	keyboard: api.Keyboard_Input,
) -> api.Controller {
	return {
		buttons = {
			.Move_Up = keyboard[.Up],
			.Move_Left = keyboard[.Left],
			.Move_Down = keyboard[.Down],
			.Move_Right = keyboard[.Right],
			.Back = keyboard[.Backspace],
			.Start = keyboard[.Enter],
			.Action_Up = {},
			.Action_Left = {},
			.Action_Down = {},
			.Action_Right = {},
			.Shoulder_Left = {},
			.Shoulder_Right = {},
		},
	}
}

@(export)
handmade_game_update :: proc "contextless" (
	memory: api.Memory,
	input: api.Input,
) {
	context = get_game_context(memory)
	state := get_game_state(memory)

	if camera_follow_target, ok := get_entity(
		state,
		state.camera_follow_entity_index,
	); ok {
		MOVE_CAMERA_IN_CHUNKS :: true
		when MOVE_CAMERA_IN_CHUNKS {
			target_tile := world_pos_tile(camera_follow_target.pos)
			VIEW_TILES_DIMS: [3]i64 : {VIEW_TILES_WIDTH, VIEW_TILES_HEIGHT, 1}
			state.camera_pos = make_world_pos(
				(target_tile / VIEW_TILES_DIMS) * VIEW_TILES_DIMS,
			)
			state.camera_pos = offset_pos(
				state.camera_pos,
				{VIEW_TILES_WIDTH - 1, VIEW_TILES_HEIGHT - 1} / 2,
			)
		} else {
			state.camera_pos = camera_follow_target.pos
		}
	}

	{
		state.sim_entities.allocator = context.temp_allocator
		clear(&state.sim_entities)

		// TODO: Make a square?
		SIM_DIM :: [2]f32{WINDOW_TILES_WIDTH * 3, WINDOW_TILES_HEIGHT * 3}

		sim_origin := state.camera_pos
		// For checking positions relative to sim_origin
		sim_rect := make_rect_center_dim([2]f32{}, SIM_DIM)

		// Min/max tile to search, found by extending the player's position by
		// the collision box

		// TODO: Handle or disallow coordinate wrapping
		// Search for collisions in the rectangle bounding the current and target
		// positions
		min_chunk := offset_pos(sim_origin, -SIM_DIM / 2).chunk.xy
		max_chunk := offset_pos(sim_origin, SIM_DIM / 2).chunk.xy

		entity_iter := world_entity_xy_iter(
			min_chunk,
			max_chunk,
			sim_origin.chunk.z,
		)
		for entity_id in world_entity_xy_next(&state.world, &entity_iter) {
			entity := get_entity(state, entity_id) or_continue
			rel_pos := world_pos_sub_xy(entity.pos, sim_origin)
			if rect_contains(sim_rect, rel_pos) {
				n := append(&state.sim_entities, Sim_Entity{id = entity_id})
				assert(n != 0)
			}
		}
	}

	dt_sec := f32(input.dt_ns) * 1e-9

	// For now, just support 1 keyboard
	handle_player_input(
		state,
		dt_sec,
		KEYBOARD_FULL_INDEX,
		keyboard_controller_full(input.keyboard),
	)
	// for controller, index in input.controllers {
	// 	handle_controller_input(state, dt_sec, index, controller)
	// }
	// handle_controller_input(
	// 	state,
	// 	dt_sec,
	// 	KEYBOARD_LEFT_INDEX,
	// 	keyboard_controller_left(input.keyboard),
	// )
	// handle_controller_input(
	// 	state,
	// 	dt_sec,
	// 	KEYBOARD_RIGHT_INDEX,
	// 	keyboard_controller_right(input.keyboard),
	// )

	for sim in state.sim_entities {
		update_entity(state, sim.id, dt_sec)
	}
}

add_entity :: proc(
	state: ^State,
) -> (
	entity: ^Entity,
	id: Entity_ID,
	ok: bool,
) {
	id = Entity_ID(len(state.entities))
	if _, ok := append_nothing(&state.entities); !ok {
		return
	}

	ok = true
	entity = &state.entities[id]
	// Clear out for good measure
	entity^ = {}
	return
}

get_entity :: proc(
	state: ^State,
	id: Entity_ID,
) -> (
	entity: ^Entity,
	ok: bool,
) {
	entity = slice.get_ptr(state.entities[:], int(id)) or_return
	if entity.type == .None do return nil, false
	return entity, true
}

handle_player_input :: proc(
	state: ^State,
	dt_sec: f32,
	controller_index: int,
	controller: api.Controller,
) {
	entity_id := state.controller_to_player_entity[controller_index]
	if entity_id == ENTITY_NIL {
		return
	}

	player := &state.entities[entity_id]

	// TODO: Support analog sticks

	// Sign of the movement: -1, 0, +1
	player_move_dir: [2]f32

	if controller.buttons[.Move_Up].end_pressed {
		player_move_dir.y += 1
	}
	if controller.buttons[.Move_Left].end_pressed {
		player_move_dir.x -= 1
	}
	if controller.buttons[.Move_Down].end_pressed {
		player_move_dir.y -= 1
	}
	if controller.buttons[.Move_Right].end_pressed {
		player_move_dir.x += 1
	}

	if api.button_input_pressed(controller.buttons[.Action_Up]) {
		if player.z == 0 {
			player.vel.z = PLAYER_JUMP_VEL
		}
	}

	// Base face_dir on the input accel rather than total accel so it doesn't + r.dim / 2
	// flip back and forth when bouncing
	if player_move_dir == 0 {
		// Leave face_dir as-is
	} else if abs(player_move_dir.x) >= abs(player_move_dir.y) {
		// Prefer x accel if
		player.face_dir = player_move_dir.x > 0 ? .Right : .Left
	} else {
		player.face_dir = player_move_dir.y > 0 ? .Back : .Front
	}

	max_speed := PLAYER_MAX_SPEED
	if controller.buttons[.Action_Right].end_pressed {
		max_speed *= 3
	}
	if controller.buttons[.Action_Left].end_pressed {
		max_speed /= 3
	}

	player_move_acc := PLAYER_MOVE_ACC * linalg.normalize0(player_move_dir)

	update_entity_motion(state, entity_id, player_move_acc, max_speed, dt_sec)
}

update_entity :: proc(state: ^State, id: Entity_ID, dt_sec: f32) {
	// Missing handled by type switch
	entity, _ := get_entity(state, id)
	#partial switch (entity.type) {
	case .Familiar:
		update_following_motion(
			state,
			id,
			FAMILIAR_MOVE_ACC,
			FAMILIAR_MAX_SPEED,
			FAMILIAR_FOLLOW_DIST2,
			dt_sec,
		)
		// Set after moving so that it ignores gravity
		entity.bob_phase += math.TAU / FAMILIAR_BOB_PERIOD * dt_sec
		entity.bob_phase = math.mod(entity.bob_phase, math.TAU)
		entity.z = FAMILIAR_BOB_HEIGHT * math.sin(entity.bob_phase)
	case .Monster:
		update_following_motion(
			state,
			id,
			FAMILIAR_MOVE_ACC,
			FAMILIAR_MAX_SPEED,
			FAMILIAR_FOLLOW_DIST2,
			dt_sec,
		)
	}
}

update_following_motion :: proc(
	state: ^State,
	id: Entity_ID,
	move_acc: f32,
	max_speed: f32,
	follow_dist2: f32,
	dt_sec: f32,
) {
	entity, exists := get_entity(state, id)
	if !exists do return

	// Search for nearest hero to follow
	closest_dist2: f32 = math.INF_F32
	follow_target: ^Entity
	for sim_entity in state.sim_entities {
		test_entity := get_entity(state, sim_entity.id) or_continue
		if test_entity.type == .Hero {
			dist2 := world_pos_dist2(entity.pos, test_entity.pos)
			if dist2 < closest_dist2 {
				closest_dist2 = dist2
				follow_target = test_entity
			}
		}
	}

	acc_vec: [2]f32
	if follow_target != nil && closest_dist2 > follow_dist2 {
		delta := world_pos_sub_xy(follow_target.pos, entity.pos)
		if delta == 0 {
			// Leave face_dir as-is
		} else if abs(delta.x) >= abs(delta.y) {
			// Prefer x accel if
			entity.face_dir = delta.x > 0 ? .Right : .Left
		} else {
			entity.face_dir = delta.y > 0 ? .Back : .Front
		}

		acc_vec = move_acc * linalg.normalize0(delta)
	}
	update_entity_motion(state, id, acc_vec, max_speed, dt_sec)
}

update_entity_motion :: proc(
	state: ^State,
	id: Entity_ID,
	acc: [2]f32,
	max_speed: f32,
	dt_sec: f32,
) {
	entity := &state.entities[id]
	orig_chunk := entity.pos.chunk

	// TODO: Make gravity + friction configurable

	if entity.vel.xy != 0 {
		// v' = v - F*v/|v| = v * (1 - F/|v|)
		friction_scale := min(
			PLAYER_FRICTION * dt_sec / linalg.length(entity.vel.xy),
			1,
		)
		entity.vel.xy *= 1 - friction_scale
	}
	entity.vel.xy += dt_sec * acc
	entity.vel.xy = linalg.clamp_length(entity.vel.xy, max_speed)

	if entity.z > 0 {
		entity.vel.z -= GRAVITY_ACC * dt_sec
	} else if entity.vel.z < 0 {
		// Not really necessary, but reset this for consistency
		entity.vel.z = 0
	}
	entity.z = max(entity.z + entity.vel.z * dt_sec, 0)

	remaining_dt_sec := dt_sec

	collision_iters := 0
	for remaining_dt_sec > 0 {
		target_dp := entity.vel.xy * remaining_dt_sec

		closest_t: f32 = 1
		collide_norm: [2]f32
		collide_entity: ^Entity

		for test_sim in state.sim_entities {
			if test_sim.id == id do continue

			test_entity :=
				get_entity(state, test_sim.id) or_else panic(
					"invalid entity ID in chunk block",
				)

			if !entity_can_collide(test_entity.type) do continue

			rel_target_origin := world_pos_sub_xy(test_entity.pos, entity.pos)
			coll_rect := make_rect_center_dim(
				rel_target_origin,
				test_entity.dim + entity.dim,
			)

			// TODO: Remove parameter and always pass the relative position
			// of the "target" object?
			if t, norm, coll := collides_axis_aligned_rect(
				0,
				target_dp,
				coll_rect,
			); coll && t < closest_t {
				closest_t = t
				collide_norm = norm
				// TODO: Track index instead?
				collide_entity = test_entity
			}
		}

		step_dt_sec: f32
		if closest_t < 1 {
			// TODO: Use distance-based epsilon so it's velocity-independent
			T_EPSILON :: 0.0001
			step_dt_sec = max(remaining_dt_sec * closest_t - T_EPSILON, 0)
		} else {
			step_dt_sec = remaining_dt_sec
		}
		remaining_dt_sec -= step_dt_sec

		step_dp := entity.vel.xy * step_dt_sec
		entity.pos = offset_pos(entity.pos, step_dp)
		// No-op if collide_norm == 0
		entity.vel.xy -=
			(1 + PLAYER_COLLIDE_COEF) *
			linalg.dot(collide_norm, entity.vel.xy) *
			collide_norm

		MAX_COLLISION_ITERS :: 10
		collision_iters += 1
		if collision_iters > MAX_COLLISION_ITERS {
			panic("possible infinite collision detection loop")
		}
	}

	if !world_update_entity_chunk(
		&state.world,
		id,
		orig_chunk,
		entity.pos.chunk,
		&state.world_arena,
	) {
		panic("failed to migrate entity chunk")
	}
}

Axis :: enum {
	X = 0,
	Y = 1,
}

collides_axis_aligned_line :: proc(
	pos: [2]f32,
	dp: [2]f32,
	line_base: [2]f32,
	line_len: f32,
	$AXIS: Axis,
) -> (
	t: f32,
	collides: bool,
) {
	CONST_AXIS :: 1 - int(AXIS)
	LEN_AXIS :: int(AXIS)
	// Position of `line_base` relative to `pos`
	delta := line_base - pos
	// TODO: Remove this check since it's done outside?
	if math.sign(delta[CONST_AXIS]) != math.sign(dp[CONST_AXIS]) ||
	   math.sign(dp[CONST_AXIS]) == 0 {
		return
	}

	t = delta[CONST_AXIS] / dp[CONST_AXIS]

	// Position along the segment at the point of collision with the
	// extended line
	other_delta := -delta[LEN_AXIS] + t * dp[LEN_AXIS]
	collides = 0 <= other_delta && other_delta <= line_len
	return
}

collides_axis_aligned_rect :: proc(
	pos: [2]f32,
	dp: [2]f32,
	rect: Rect(f32),
) -> (
	t: f32 = 1.0,
	norm: [2]f32,
	collides: bool,
) {
	rect_bottom_left := rect_min(rect)
	rect_size := rect_dim(rect)
	// bottom
	if dp.y > 0 {
		wall_t, wall_collides := collides_axis_aligned_line(
			pos,
			dp,
			rect_bottom_left,
			rect_size.x,
			.X,
		)
		if wall_collides && wall_t < t {
			t = wall_t
			collides = wall_collides
			norm = {0, -1}
		}
	}
	// top
	if dp.y < 0 {
		wall_t, wall_collides := collides_axis_aligned_line(
			pos,
			dp,
			rect_bottom_left + {0, rect_size.y},
			rect_size.x,
			.X,
		)
		if wall_collides && wall_t < t {
			t = wall_t
			collides = wall_collides
			norm = {0, +1}
		}
	}
	// left
	if dp.x > 0 {
		wall_t, wall_collides := collides_axis_aligned_line(
			pos,
			dp,
			rect_bottom_left,
			rect_size.y,
			.Y,
		)
		if wall_collides && wall_t < t {
			t = wall_t
			collides = wall_collides
			norm = {-1, 0}
		}
	}
	// right
	if dp.x < 0 {
		wall_t, wall_collides := collides_axis_aligned_line(
			pos,
			dp,
			rect_bottom_left + {rect_size.x, 0},
			rect_size.y,
			.Y,
		)
		if wall_collides && wall_t < t {
			t = wall_t
			collides = wall_collides
			norm = {+1, 0}
		}
	}
	return
}

//
// CONSTANTS
//

TILE_SIZE_PX :: 60
TILE_OFFSET_PX :: [2]f32{-TILE_SIZE_PX / 2, 0}
Z_TO_Y_RATIO :: 0.75

PLAYER_COLLISION_SIZE: [2]f32 : {0.8, 0.5}
PLAYER_MAX_SPEED: f32 : 6 // tile/sec
PLAYER_FRICTION: f32 : 40 // tile/sec^2
// Include friction, since it is always acting against movement acceleration
// TODO: Only apply friction in non-movement direction?
// TODO: Use drag force instead of constant friction?
PLAYER_MOVE_ACC: f32 : 70 // tile/sec^2
// TODO: Figure out how to avoid stuttering when pressing against a wall when
// this is non-0
PLAYER_COLLIDE_COEF: f32 : 0
PLAYER_JUMP_VEL :: 4
GRAVITY_ACC: f32 : 10

FAMILIAR_MAX_SPEED :: PLAYER_MAX_SPEED / 2
FAMILIAR_MOVE_ACC :: PLAYER_MOVE_ACC
FAMILIAR_FOLLOW_DIST :: 2
FAMILIAR_FOLLOW_DIST2 :: FAMILIAR_FOLLOW_DIST * FAMILIAR_FOLLOW_DIST

FAMILIAR_BOB_PERIOD :: 1.2
FAMILIAR_BOB_HEIGHT :: 0.2

HP_SIZE :: 0.15
HP_OFFSET_Y :: 0.3
HP_SPACING_X :: HP_SIZE * 2

WINDOW_TILES_WIDTH :: 16
WINDOW_TILES_HEIGHT :: 9
// Include an extra tile that's half-shown on either side so that there can be a
// "middle" tile
VIEW_TILES_WIDTH :: 17
VIEW_TILES_HEIGHT :: 9

Bmp_Header :: struct #packed {
	id: [2]u8,
	size: u32le,
	_reserved1: u16le,
	_reserved2: u16le,
	bitmap_offset: u32le,
}
#assert(size_of(Bmp_Header) == 14)

Dib_Bitmap_Info_Header :: struct #packed {
	// Should be >= 40
	header_size: u32le,
	bitmap_width: i32le,
	// Positive: bottom->top
	// Negative: top->bottom
	bitmap_height: i32le,
	color_planes: u16le,
	bits_per_pixel: u16le,
	compression: Compression_Method,
	// 0 for RGB
	image_size: u32le,
	horiz_resolution: u32le,
	vert_resolution: u32le,
	colors: u32le,
	important_colors: u32le,
	// v4
	// RGBA
	masks: [4]u32le,
	cs_type: u32le,
	endpoints: [3][3]u32le,
	gamma: [3][2]u16le,
	// v5
	intent: u32le,
	profile_data: u32le,
	profile_size: u32le,
	_reserved: u32le,
}

Compression_Method :: enum u32le {
	Rgb             = 0,
	Rle8            = 1,
	Rle4            = 2,
	Bitfields       = 3,
	Jpeg            = 4,
	Png             = 5,
	Alpha_Bitfields = 6,
	Cmyk            = 11,
	Cmyk_Rle8       = 12,
	Cmyk_Rle4       = 13,
}

// TODO: Use same structure for dest frame buffer?
Bmp_Image :: struct {
	width: u32,
	height: u32,
	stride: u32,
	format: Bmp_Format,
	pixels: rawptr,
}

Bmp_Format :: enum {
	Rgba8le,
	Argb8le,
	// TODO: Separate formats for non-alpha channel? Just assume alpha is 255 in
	// those cases?
}

Bmp_Pixel_Rgba8le :: struct #packed {
	a, b, g, r: u8,
}
BMP_RGBA8LE_MASK :: [4]u32le{0xFF000000, 0x00FF0000, 0x0000FF00, 0x000000FF}

Bmp_Pixel_Argb8le :: struct #packed {
	b, g, r, a: u8,
}
BMP_ARGB8LE_MASK :: [4]u32le{0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000}

load_bmp :: proc(contents: []byte) -> (image: Bmp_Image, ok: bool) {
	if len(contents) < size_of(Bmp_Header) {
		ok = false
		return
	}

	// TODO: Replace asserts with error returns
	bmp_header := (^Bmp_Header)(&contents[0])
	assert(bmp_header.id == "BM")
	assert(bmp_header.bitmap_offset <= bmp_header.size)

	info_header := (^Dib_Bitmap_Info_Header)(&contents[size_of(bmp_header^)])
	assert(info_header.header_size >= size_of(info_header^))
	assert(info_header.color_planes == 1)
	assert(info_header.bits_per_pixel == 32)
	assert(info_header.colors == 0)

	// Round up to nearest 32-bit chunk
	stride_bytes :=
		((u32(info_header.bits_per_pixel) * u32(info_header.bitmap_width) +
				31) &
			~u32(31)) >>
		3
	assert(
		u32(info_header.image_size) ==
		stride_bytes * u32(abs(info_header.bitmap_height)),
	)

	// TODO: Support more dynamic formats
	#partial switch info_header.compression {
	case .Bitfields:
		if info_header.masks.rgb == BMP_RGBA8LE_MASK.rgb {
			image.format = .Rgba8le
		} else if info_header.masks.rgb == BMP_ARGB8LE_MASK.rgb {
			image.format = .Argb8le
		} else {
			panic("unsupported bitfields format")
		}
	// case .Alpha_Bitfields:
	// 	assert(info_header.masks == BMP_RGBA8LE_MASK)
	case:
		panic("unsupported BMP format")
	}

	assert(info_header.bitmap_width >= 0)
	// TODO: support flipped order
	assert(info_header.bitmap_height >= 0)
	image.width = u32(info_header.bitmap_width)
	image.height = u32(info_header.bitmap_height)
	image.stride = stride_bytes / 4
	image.pixels = &contents[bmp_header.bitmap_offset]
	ok = true
	return
}

@(export)
handmade_game_render :: proc "contextless" (
	memory: api.Memory,
	fb: Frame_Buffer,
) {
	context = get_game_context(memory)
	state := get_game_state(memory)

	// Fill borders
	frame_buffer_fill(fb, make_pixel(0, 0, 0))
	// TODO: Scale up rendering instead of just rendering to the center of the
	// window
	fb := frame_buffer_center_region(
		fb,
		linalg.min(
			[2]u32{fb.width, fb.height},
			[2]u32{WINDOW_TILES_WIDTH, WINDOW_TILES_HEIGHT} * TILE_SIZE_PX,
		),
	)
	// Fill with ugly color so it's obvious when some part isn't covered
	frame_buffer_fill(fb, make_pixel(0xFF, 0x00, 0xFF))

	// TODO: Background looks weird with trees as walls...
	// render_bmp(fb, 0, 0, state.background_texture)
	frame_buffer_fill(fb, make_pixel(0x40, 0x40, 0x40))

	// state.camera_pos, adjusted so that it points to the bottom-left corner
	// instead of the center
	window_origin := offset_pos(
		state.camera_pos,
		-{WINDOW_TILES_WIDTH, WINDOW_TILES_HEIGHT} / 2,
	)

	for sim_entity in state.sim_entities {
		entity := get_entity(state, sim_entity.id) or_continue
		// TODO: Extra culling for sim entities outside of the window

		render_pos := world_pos_sub_xy(entity.pos, window_origin)

		// #reverse for entity in state.entities {
		switch entity.type {
		case .None:
		case .Wall:
			assert(pos_is_normalized(entity.pos))
			render_pos := world_pos_sub_xy(entity.pos, window_origin)
			render_part(
				fb,
				{render_pos.x, render_pos.y, 0},
				state.tree_texture,
				{51, 30},
			)
		case .Hero:
			// if entity.pos.tile.z != state.camera_pos.tile.z do continue
			hero_tex := state.hero_textures[entity.face_dir]

			assert(pos_is_normalized(entity.pos))

			// Mark entity's tile
			// render_rect(
			// 	fb,
			// 	make_rect_center_dim(
			// 		world_pos_sub_xy(
			// 			world_pos_round(entity.pos),
			// 			window_origin,
			// 		),
			// 		1,
			// 	),
			// 	color = make_color(1.0),
			// )

			// Mark collision box
			// render_rect(
			// 	fb,
			// 	make_rect_center_dim(render_pos, entity.dim),
			// 	color = make_color(0.8, 0.8, 0.0),
			// )

			// Fade shadow when the player jumps
			shadow_alpha := 1 - min(entity.z / 2.0, 1)

			render_part(
				fb,
				{render_pos.x, render_pos.y, 0},
				state.hero_shadow_texture,
				// TODO: Is this the proper align position for the shadow in all
				// directions?
				hero_tex.align_px,
				shadow_alpha,
			)

			body_render_pos: [3]f32 = {render_pos.x, render_pos.y, entity.z}
			render_part(fb, body_render_pos, hero_tex.torso, hero_tex.align_px)
			render_part(fb, body_render_pos, hero_tex.cape, hero_tex.align_px)
			render_part(fb, body_render_pos, hero_tex.head, hero_tex.align_px)

			render_hp(fb, entity, render_pos)

		// Mark entity's position
		// MARKER_SIZE :: 0.1
		// render_rect(
		// 	fb,
		// 	make_rect_center_dim(render_pos, MARKER_SIZE),
		// 	color = make_color(0.8, 0.0, 0.0),
		// )
		case .Monster:
			// if entity.pos.tile.z != state.camera_pos.tile.z do continue
			hero_tex := state.hero_textures[entity.face_dir]

			assert(pos_is_normalized(entity.pos))

			render_part(
				fb,
				{render_pos.x, render_pos.y, 0},
				state.hero_shadow_texture,
				hero_tex.align_px,
			)
			render_part(
				fb,
				{render_pos.x, render_pos.y, entity.z},
				hero_tex.torso,
				hero_tex.align_px,
			)
			render_hp(fb, entity, render_pos)
		case .Familiar:
			// if entity.pos.tile.z != state.camera_pos.tile.z do continue
			hero_tex := state.hero_textures[entity.face_dir]

			assert(pos_is_normalized(entity.pos))

			shadow_alpha := 0.5 - min(entity.z / 2.0, 0.5)

			render_part(
				fb,
				{render_pos.x, render_pos.y, 0},
				state.hero_shadow_texture,
				hero_tex.align_px,
				shadow_alpha,
			)
			render_part(
				fb,
				{render_pos.x, render_pos.y, entity.z},
				hero_tex.head,
				hero_tex.align_px,
			)
		}
	}
}

render_hp :: proc(fb: Frame_Buffer, entity: ^Entity, render_pos: [2]f32) {
	if entity.hp_max <= 0 do return

	render_pos := render_pos
	render_pos.y -= HP_OFFSET_Y

	base_offset_x := -f32(entity.hp_max - 1) / 2 * HP_SPACING_X
	for i in 0 ..< entity.hp_max {
		color: Color
		if i < entity.hp {
			color = make_color(0.9, 0.0, 0.0)
		} else {
			color = make_color(0.2, 0.2, 0.2)
		}
		render_rect(
			fb,
			make_rect_center_dim(
				render_pos + {base_offset_x + f32(i) * HP_SPACING_X, 0},
				HP_SIZE,
			),
			color,
		)
	}
}

render_part :: proc(
	fb: Frame_Buffer,
	pos: [3]f32,
	bitmap: Bmp_Image,
	align_px: [2]f32,
	alpha: f32 = 1.0,
) {
	pos_xy := pos.xy
	pos_xy.y += Z_TO_Y_RATIO * pos.z
	pos_px := pos_xy * TILE_SIZE_PX - align_px
	render_bmp(fb, pos_px, bitmap, alpha)
}

Color :: [4]f32
Color_U8 :: [4]u8

make_color :: proc {
	make_color_rgba_f32,
	make_color_rgba_u8,
	make_color_grey,
}

make_color_rgba_f32 :: proc(r, g, b: f32, a: f32 = 1.0) -> Color {
	return {r, g, b, a}
}

make_color_rgba_u8 :: proc(r, g, b: u8, a: u8 = 255) -> Color {
	return linalg.to_f32([4]u8{r, g, b, a}) / 255.0
}

make_color_grey :: proc(v: f32, a: f32 = 1.0) -> Color {
	return make_color_rgba_f32(v, v, v, a)
}

make_pixel :: proc {
	make_pixel_bits,
	make_pixel_rgba_u8,
	make_pixel_rgba_f32,
	make_pixel_color,
}

make_pixel_rgba_u8 :: #force_inline proc(r, g, b: u8, a: u8 = 255) -> Pixel {
	return Pixel{r = r, g = g, b = b, a = a}
}

make_pixel_rgba_f32 :: proc(r, g, b: f32, a: f32 = 1.0) -> Pixel {
	to_u8 :: proc(v: f32) -> u8 {
		assert(v >= 0.0)
		assert(v <= 1.0)
		return u8(255 * v)
	}
	return make_pixel_rgba_u8(to_u8(r), to_u8(g), to_u8(b), to_u8(a))
}

make_pixel_color :: proc(color: Color) -> Pixel {
	return make_pixel_rgba_f32(color.r, color.g, color.b)
}

make_pixel_bits :: proc(bits: Pixel_Bits) -> Pixel {
	return {
		b = u8(bits & 0xFF),
		g = u8((bits >> 8) & 0xFF),
		r = u8((bits >> 16) & 0xFF),
	}
}

Pixel :: api.Pixel
Pixel_Bits :: distinct u32

pixel_bits :: proc(p: Pixel) -> Pixel_Bits {
	// TODO: Check endianness of the machine?
	// TODO: transmute?
	return Pixel_Bits(p.b) | (Pixel_Bits(p.g) << 8) | (Pixel_Bits(p.r) << 16)
}

frame_buffer_sub_region :: proc(
	fb: Frame_Buffer,
	pos, size: [2]u32,
) -> Frame_Buffer {
	assert(pos.x <= fb.width)
	assert(pos.y <= fb.height)
	assert(pos.x + size.x <= fb.width)
	assert(pos.y + size.y <= fb.height)
	return {
		width = size.x,
		height = size.y,
		stride = fb.stride,
		pixels = rawptr(
			uintptr(fb.pixels) +
			uintptr(pos.y * fb.stride) +
			uintptr(pos.x * size_of(Pixel)),
		),
	}
}

frame_buffer_center_region :: proc(
	fb: Frame_Buffer,
	size: [2]u32,
) -> Frame_Buffer {
	return frame_buffer_sub_region(
		fb,
		{(fb.width - size.x) / 2, (fb.height - size.y) / 2},
		size,
	)
}

frame_buffer_row :: proc(fb: Frame_Buffer, y: int) -> []Pixel {
	assert(y >= 0)
	assert(y < int(fb.height))
	return mem.slice_ptr(
		(^Pixel)(uintptr(fb.pixels) + uintptr(y * int(fb.stride))),
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

clamp_size :: #force_inline proc(v: [2]int, size: [2]int) -> [2]int {
	return {clamp(v.x, 0, size.x), clamp(v.y, 0, size.y)}
}

Mapped_Region :: struct {
	in_offset: [2]int,
	out_offset: [2]int,
	size: [2]int,
}

map_px_region :: proc(fb: Frame_Buffer, pos, size: [2]int) -> Mapped_Region {
	fb_size := [2]int{int(fb.width), int(fb.height)}
	clipped_in_min := clamp_size(pos, fb_size)
	clipped_in_max := clamp_size(pos + size, fb_size)

	return {
		in_offset = clipped_in_min - pos,
		out_offset = {clipped_in_min.x, fb_size.y - 1 - clipped_in_min.y},
		size = clipped_in_max - clipped_in_min,
	}
}

round_int :: proc(pos: [$N]f32) -> [N]int {
	return linalg.to_int(linalg.round(pos))
}

round_px_region :: proc(pos, size: [2]f32) -> (pos_px, size_px: [2]int) {
	min_px := round_int(pos)
	max_px := round_int(pos + size)
	return min_px, max_px - min_px
}

render_rect_px :: proc(fb: Frame_Buffer, rect: Rect(f32), color: Color) {
	pixel := make_pixel(color)
	pos_px, size_px := round_px_region(rect_min(rect), rect_dim(rect))
	region := map_px_region(fb, pos_px, size_px)

	for y in 0 ..< region.size.y {
		row := frame_buffer_row(fb, region.out_offset.y - y)
		row_part := row[region.out_offset.x:][:region.size.x]
		slice.fill(row_part, pixel)
	}
}

render_rect :: proc(fb: Frame_Buffer, rect: Rect(f32), color: Color) {
	render_rect_px(fb, rect_scale(rect, TILE_SIZE_PX), color = color)
}

render_bmp :: proc(
	fb: Frame_Buffer,
	pos_px: [2]f32,
	img: Bmp_Image,
	extra_alpha: f32 = 1.0,
) {
	region := map_px_region(
		fb,
		round_int(pos_px),
		{int(img.width), int(img.height)},
	)

	for y in 0 ..< region.size.y {
		img_y := region.in_offset.y + y
		fb_row := frame_buffer_row(fb, region.out_offset.y - y)
		for x in 0 ..< region.size.x {
			img_x := region.in_offset.x + x
			px_index := img_y * int(img.stride) + img_x
			src_color: Color_U8
			// TODO: Convert pixel order to a standard one when loading?
			switch img.format {
			case .Rgba8le:
				bmp_px := ([^]Bmp_Pixel_Rgba8le)(img.pixels)[px_index]
				src_color = Color_U8{bmp_px.r, bmp_px.g, bmp_px.b, bmp_px.a}
			case .Argb8le:
				bmp_px := ([^]Bmp_Pixel_Argb8le)(img.pixels)[px_index]
				src_color = Color_U8{bmp_px.r, bmp_px.g, bmp_px.b, bmp_px.a}
			}

			fb_col := region.out_offset.x + x
			px := &fb_row[fb_col]
			// Manual inlining is _much_ faster than calling an equivalent
			// function (25ms vs 40ms per frame).
			// TODO: Report bug? Or is this just expected in debug mode?
			// alpha_blend_u8_into(px, src_color)
			{
				alpha := u32(extra_alpha * f32(src_color.a))
				// TODO: Extracting these adds ~4ms per frame
				// src_alpha := 1 + alpha
				// dst_alpha := 256 - alpha
				r := u32(px.r) * (256 - alpha) + u32(src_color.r) * (1 + alpha)
				g := u32(px.g) * (256 - alpha) + u32(src_color.g) * (1 + alpha)
				b := u32(px.b) * (256 - alpha) + u32(src_color.b) * (1 + alpha)
				px^ = {
					r = u8(r >> 8),
					g = u8(g >> 8),
					b = u8(b >> 8),
				}
			}
		}
	}
}

alpha_blend :: proc(dst, src: Color) -> Color {
	alpha := src.a
	return dst * (1 - alpha) + src * alpha
}

alpha_blend_u8 :: proc(dst, src: Color_U8) -> Color_U8 {
	alpha := u32(src.a)
	// TODO: Using vector operations is much slower in debug mode. Report bug?
	r := (u32(dst.r) * (256 - alpha) + u32(src.r) * (1 + alpha))
	g := (u32(dst.g) * (256 - alpha) + u32(src.g) * (1 + alpha))
	b := (u32(dst.b) * (256 - alpha) + u32(src.b) * (1 + alpha))
	a := (u32(dst.a) * (256 - alpha) + u32(src.a) * (1 + alpha))
	// TODO: Report bug for image.blend doing a mask instead of a shift
	return {u8(r >> 8), u8(g >> 8), u8(b >> 8), u8(a >> 8)}
}

alpha_blend_u8_into :: proc(dst: ^Pixel, src: Color_U8) {
	alpha := u32(src.a)
	r := (u32(dst.r) * (256 - alpha) + u32(src.r) * (1 + alpha))
	g := (u32(dst.g) * (256 - alpha) + u32(src.g) * (1 + alpha))
	b := (u32(dst.b) * (256 - alpha) + u32(src.b) * (1 + alpha))
	// a := (u16(dst.a) * (256 - u16(alpha)) + u16(src.a) * (1 + u16(alpha)))
	dst^ = {
		r = u8(r >> 8),
		g = u8(g >> 8),
		b = u8(b >> 8),
		// a = u8(a >> 8),
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
