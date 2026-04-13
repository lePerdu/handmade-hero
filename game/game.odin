package game

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
	camera_follow_entity_index: int,
	entity_buf: [256]Entity,
	entities: [dynamic]Entity,
	controller_to_player_entity: [VIRT_CONTROLLER_COUNT]int,
	world_arena: mem.Arena,
	background_texture: Bmp_Image,
	hero_textures: [Direction]Player_Textures,
	hero_shadow_texture: Bmp_Image,
}

Entity :: struct {
	exists: bool,
	pos: World_Pos,
	vel: [2]f32,
	face_dir: Direction,
}

World :: struct {
	tile_map: Tile_Map,
}

Player_Textures :: struct {
	head: Bmp_Image,
	torso: Bmp_Image,
	cape: Bmp_Image,
	align_px: [2]i32,
}

Direction :: enum {
	Right,
	Back,
	Left,
	Front,
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
		gen_world(state)
		state.camera_pos = {
			tile = {VIEW_TILES_WIDTH / 2, VIEW_TILES_HEIGHT / 2, 0},
			local = 0,
		}
		state.entities = mem.buffer_from_slice(state.entity_buf[:])
		// TODO: Set exists = true in add_entity?
		nil_entity, nil_entity_index :=
			add_entity(state) or_else panic("failed to create nil entity")
		assert(nil_entity_index == 0)
		assert(!nil_entity.exists)

		if player_entity, index, ok := add_entity(state); ok {
			player_entity^ = {
				exists = true,
				face_dir = .Front,
				pos = {
					tile = {VIEW_TILES_WIDTH / 3, VIEW_TILES_HEIGHT / 3, 0},
					local = {-0.5, -0.5},
				},
			}
			state.controller_to_player_entity[KEYBOARD_FULL_INDEX] = index
			state.camera_follow_entity_index = index
		} else {
			panic("failed to add player entity")
		}

		state.background_texture = debug_load_bmp(
			memory,
			"assets/early_data/test/test_background.bmp",
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
		align_px = {i32(torso.width) / 2, 0},
	}
}

gen_world :: proc(state: ^State) {
	SCREENS_X :: 128
	SCREENS_Y :: 128

	mem.arena_free_all(&state.world_arena)
	context.allocator = mem.arena_allocator(&state.world_arena)

	map_size := [?]i32 {
		SCREENS_X * VIEW_TILES_WIDTH / CHUNK_SIZE,
		SCREENS_Y * VIEW_TILES_HEIGHT / CHUNK_SIZE,
		2,
	}
	state.world.tile_map = {
		size = map_size,
		chunks = make(
			[^]Tile_Chunk,
			int(map_size.x * map_size.y * map_size.z),
		),
	}

	rand.reset(2)
	screen_x, screen_y, screen_z: i32
	door_left, door_right, door_bottom, door_top, stair, stair_exit: bool
	for screen_i in 0 ..< 100 {
		// TODO: Custom RNG
		// Can't add a stair if there is already a stair exit here
		r := rand.uint_max(stair_exit ? 2 : 3)
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
				pos := Global_Tile_Pos {
					screen_x * VIEW_TILES_WIDTH + x,
					screen_y * VIEW_TILES_HEIGHT + y,
					screen_z,
				}
				tile, ok := tile_map_get_tile_or_alloc_chunk(
					state.world.tile_map,
					pos,
				)
				assert(ok)
				if x == 0 {
					if y == VIEW_TILES_HEIGHT / 2 && door_left {
						tile^ = .Door
					} else {
						tile^ = .Wall
					}
				} else if x == VIEW_TILES_WIDTH - 1 {
					if y == VIEW_TILES_HEIGHT / 2 && door_right {
						tile^ = .Door
					} else {
						tile^ = .Wall
					}
				} else if y == 0 {
					if x == VIEW_TILES_WIDTH / 2 && door_bottom {
						tile^ = .Door
					} else {
						tile^ = .Wall
					}
				} else if y == VIEW_TILES_HEIGHT - 1 {
					if x == VIEW_TILES_WIDTH / 2 && door_top {
						tile^ = .Door
					} else {
						tile^ = .Wall
					}
				} else if x == VIEW_TILES_WIDTH / 2 &&
				   y == VIEW_TILES_HEIGHT / 2 {
					if door_up {
						tile^ = .Stair_Up
					} else if door_down {
						tile^ = .Stair_Down
					} else {
						tile^ = .Empty
					}
				} else {
					tile^ = .Empty
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

	dt_sec := f32(input.dt_ns) * 1e-9

	// For now, just support 1 keyboard
	handle_controller_input(
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

	if camera_follow_target, ok := get_entity(
		state,
		state.camera_follow_entity_index,
	); ok {
		target_pos := camera_follow_target.pos
		MOVE_CAMERA_IN_CHUNKS :: true
		if MOVE_CAMERA_IN_CHUNKS {
			state.camera_pos = World_Pos {
				// Move camera by window-sized chunks
				tile = (target_pos.tile / VIEW_TILES_DIMS) *
					VIEW_TILES_DIMS + VIEW_TILES_DIMS / 2,
				local = 0,
			}
		} else {
			state.camera_pos = World_Pos {
				// Center player
				tile = target_pos.tile,
				local = target_pos.local,
			}
		}
	}
}

add_entity :: proc(state: ^State) -> (entity: ^Entity, index: int, ok: bool) {
	index = len(state.entities)
	if _, err := append_nothing(&state.entities); err != nil {
		return
	}
	entity = &state.entities[index]
	ok = true
	return
}

get_entity :: proc(state: ^State, index: int) -> (entity: ^Entity, ok: bool) {
	entity = slice.get_ptr(state.entities[:], index) or_return
	if !entity.exists do return nil, false
	return entity, true
}

handle_controller_input :: proc(
	state: ^State,
	dt_sec: f32,
	controller_index: int,
	controller: api.Controller,
) {
	entity_index := state.controller_to_player_entity[controller_index]
	if entity_index == 0 {
		return
		/*
		if api.button_input_pressed(controller.buttons[.Start]) {
			new_player: ^Entity
			new_player, entity_index =
				add_entity(state) or_else panic(
					"failed to add player entity for controller",
				)
			new_player^ = {
				exists = true,
				face_dir = .Front,
				pos = {
					tile = {VIEW_TILES_WIDTH / 3, VIEW_TILES_HEIGHT / 3, 0},
				},
			}
			state.controller_to_player_entity[controller_index] = entity_index
			if state.camera_follow_entity_index == 0 {
				state.camera_follow_entity_index = entity_index
			}
		} else {
			return
		}
		*/
	}

	update_player_movement(state, entity_index, dt_sec, controller)
}

update_player_movement :: proc(
	state: ^State,
	entity_index: int,
	dt_sec: f32,
	controller: api.Controller,
) {
	player := &state.entities[entity_index]
	// Save for later after movement computation
	old_tile_pos := player.pos.tile
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

	// Base face_dir on the input accel rather than total accel so it doens't
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
	if controller.buttons[.Action_Up].end_pressed {
		max_speed *= 3
	}

	player_move_acc := PLAYER_MOVE_ACC * linalg.normalize0(player_move_dir)

	collides_wall :: proc(
		pos: World_Pos,
		dp: [2]f32,
		tile_pos: [2]i32,
		wall_coord: f32,
		$AXIS: int,
	) -> (
		t: f32,
		collides: bool,
	) {
		OTHER_AXIS :: 1 - AXIS
		rel_pos := linalg.to_f32(tile_pos - pos.tile.xy) - pos.local

		delta := rel_pos[AXIS] + wall_coord
		// TODO: Remove this check since it's done outside?
		if math.sign(delta) != math.sign(dp[AXIS]) ||
		   math.sign(dp[AXIS]) == 0 {
			return
		}

		t = delta / dp[AXIS]
		other_delta := rel_pos[OTHER_AXIS]
		collides = -0.5 <= other_delta && other_delta <= 0.5
		return
	}

	collides_tile :: proc(
		pos: World_Pos,
		dp: [2]f32,
		tile_pos: [2]i32,
	) -> (
		t: f32 = 1.0,
		norm: [2]f32,
		collides: bool,
	) {
		// TODO: Make some of these exclusive
		// Up
		if pos.tile.y < tile_pos.y && dp.y > 0 {
			wall_t, wall_collides := collides_wall(pos, dp, tile_pos, -0.5, 1)
			if wall_collides && wall_t < t {
				t = wall_t
				collides = wall_collides
				norm = {0, -1}
			}
		}
		// Down
		if pos.tile.y > tile_pos.y && dp.y < 0 {
			wall_t, wall_collides := collides_wall(pos, dp, tile_pos, 0.5, 1)
			if wall_collides && wall_t < t {
				t = wall_t
				collides = wall_collides
				norm = {0, 1}
			}
		}
		// Left
		if pos.tile.x > tile_pos.x && dp.x < 0 {
			wall_t, wall_collides := collides_wall(pos, dp, tile_pos, 0.5, 0)
			if wall_collides && wall_t < t {
				t = wall_t
				collides = wall_collides
				norm = {1, 0}
			}
		}
		// Right
		if pos.tile.x < tile_pos.x && dp.x > 0 {
			wall_t, wall_collides := collides_wall(pos, dp, tile_pos, -0.5, 0)
			if wall_collides && wall_t < t {
				t = wall_t
				collides = wall_collides
				norm = {-1, 0}
			}
		}

		return
	}

	remaining_dt_sec := dt_sec

	// TODO: Limit iterations
	// TODO: Add epsilon comparison
	collision_iters := 0
	for remaining_dt_sec > 0 {
		target_dp := player.vel * remaining_dt_sec
		target_pos := normalize_pos(offset_pos(player.pos, target_dp))

		// TODO: Handle or disallow coordinate wrapping
		// Search for collisions in the rectangle bounding the current and target
		// positions
		min_tile := linalg.min(player.pos.tile.xy, target_pos.tile.xy)
		max_tile := linalg.max(player.pos.tile.xy, target_pos.tile.xy)

		closest_t: f32 = 1
		collide_norm: [2]f32

		tile_z := player.pos.tile.z
		for tile_y in min_tile.y ..= max_tile.y {
			for tile_x in min_tile.x ..= max_tile.x {
				tile_xy := [2]i32{tile_x, tile_y}

				// No need to check current position. This should also help
				// recover from the player being inside a wall tile
				if player.pos.tile.xy == tile_xy do continue

				// TODO: How to handle missing tiles?
				tile := tile_map_get_tile_or_default(
					state.world.tile_map,
					{tile_x, tile_y, tile_z},
					.Wall,
				)

				if tile != .Wall do continue

				if t, norm, coll := collides_tile(
					player.pos,
					target_dp,
					tile_xy,
				); coll && t < closest_t {
					closest_t = t
					collide_norm = norm
				}
			}
		}

		step_dt_sec: f32
		if closest_t < 1 {
			// TODO: Use distance-based epsilon so it's velocity-independant
			T_EPSILON :: 0.0001
			step_dt_sec = max(remaining_dt_sec * closest_t - T_EPSILON, 0)
		} else {
			step_dt_sec = remaining_dt_sec
		}
		remaining_dt_sec -= step_dt_sec

		// Update position based on collision, then update velocity. Not fully
		// "correct", but computing the acceleration continuously makes the
		// collision path non-linear
		step_dp := player.vel * step_dt_sec
		player.pos = normalize_pos(offset_pos(player.pos, step_dp))

		// Friction -> collide -> move_acc
		if player.vel != 0 {
			// v' = v - F*v/|v| = v * (1 - F/|v|)
			friction_scale := min(
				PLAYER_FRICTION * step_dt_sec / linalg.length(player.vel),
				1,
			)
			player.vel *= 1 - friction_scale
		}
		if collide_norm != 0 {
			player.vel -=
				(1 + PLAYER_COLLIDE_COEF) *
				linalg.dot(collide_norm, player.vel) *
				collide_norm
		}
		player.vel += step_dt_sec * player_move_acc
		player.vel = linalg.clamp_length(player.vel, max_speed)

		MAX_COLLISION_ITERS :: 10
		collision_iters += 1
		if collision_iters > MAX_COLLISION_ITERS {
			panic("possible infinite collision detection loop")
		}
	}

	if player.pos.tile != old_tile_pos {
		#partial switch tile_map_get_tile_or_default(
			state.world.tile_map,
			player.pos.tile,
		) {
		case .Stair_Up:
			player.pos.tile.z += 1
		case .Stair_Down:
			player.pos.tile.z -= 1
		}
	}
}

TILE_SIZE_PX :: 60
TILE_OFFSET_PX :: [2]f32{-TILE_SIZE_PX / 2, 0}

PLAYER_WIDTH: f32 : 0.7
PLAYER_HEIGHT: f32 : 1
PLAYER_COLLISION_HEIGHT_TILES: f32 : 0.5
PLAYER_MAX_SPEED: f32 : 6 // tile/sec
PLAYER_FRICTION: f32 : 40 // tile/sec^2
// Include friction, since it is always acting against movement acceleration
// TODO: Only apply friction in non-movement direction?
// TODO: Use drag force instead of constant friction?
PLAYER_MOVE_ACC: f32 : 70 // tile/sec^2
// TODO: Figure out how to avoid studering when pressing against a wall when
// this is non-0
PLAYER_COLLIDE_COEF: f32 : 0

WINDOW_TILES_WIDTH :: 16
WINDOW_TILES_HEIGHT :: 9
// Include an extra tile that's half-shown on either side so that there can be a
// "middle" tile
VIEW_TILES_WIDTH :: 17
VIEW_TILES_HEIGHT :: 9
VIEW_TILES_DIMS: [3]i32 : {VIEW_TILES_WIDTH, VIEW_TILES_HEIGHT, 1}

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
	// those caes?
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

	render_bmp(fb, 0, 0, state.background_texture)

	// state.camera_pos, adjusted so that it points to the bottom-left corner
	// instead of the center
	window_origin := World_Pos {
		tile = state.camera_pos.tile - VIEW_TILES_DIMS / 2,
		local = state.camera_pos.local,
	}

	// Can reduce the tiles drawn when the camera is tile-aligned
	overdraw_x: i32 = window_origin.local.x == 0.0 ? 0 : 1
	overdraw_y: i32 = window_origin.local.y == 0.0 ? 0 : 1
	for window_row in -overdraw_y ..< i32(VIEW_TILES_HEIGHT) + overdraw_y {
		col_loop: for window_col in -overdraw_x ..< i32(VIEW_TILES_WIDTH) +
			overdraw_x {
			window_pos := Global_Tile_Pos{window_col, window_row, 0}
			tile_pos := window_pos + window_origin.tile
			tile_val, ok := tile_map_get_tile_ptr(
				state.world.tile_map,
				tile_pos,
			)
			if !ok {
				// Leave the tile blank for now? Wrap the coordinate?
				continue
			}

			color: Color
			switch tile_val^ {
			case .Empty:
				continue col_loop
			case .Wall:
				color = make_color(0.8)
			case .Door:
				// door
				color = make_color(0.2)
			case .Stair_Up:
				color = make_color(r = 0.0, g = 0.4, b = 0.0)
			case .Stair_Down:
				color = make_color(r = 0.0, g = 0.0, b = 0.4)
			}

			render_rect_tile(
				fb,
				pos = (linalg.to_f32(window_pos.xy) - state.camera_pos.local),
				size = 1,
				color = color,
			)
		}
	}

	for entity in state.entities {
		if !entity.exists do continue
		if entity.pos.tile.z != state.camera_pos.tile.z do continue
		hero_tex := state.hero_textures[entity.face_dir]

		assert(pos_is_normalized(entity.pos))

		render_pos := world_pos_xy(world_pos_sub(entity.pos, window_origin))
		// Mark entity's tile
		render_rect_tile(
			fb,
			pos = linalg.to_f32(entity.pos.tile.xy - window_origin.tile.xy),
			size = 1,
			color = make_color(1.0),
		)

		render_pos_px := render_pos * TILE_SIZE_PX
		// TODO: Calc render width/height based on image size? Scale bitmaps to fit
		// pre-defined dimensionts?
		render_bmp(
			fb,
			render_pos_px,
			// TODO: Is this the proper aling position for the shadow in all
			// directions?
			hero_tex.align_px,
			state.hero_shadow_texture,
		)
		render_bmp(fb, render_pos_px, hero_tex.align_px, hero_tex.torso)
		render_bmp(fb, render_pos_px, hero_tex.align_px, hero_tex.cape)
		render_bmp(fb, render_pos_px, hero_tex.align_px, hero_tex.head)

		// Mark entity's position
		MARKER_SIZE :: 0.1
		render_rect_tile(
			fb,
			pos = render_pos + 0.5 - {MARKER_SIZE / 2, 0},
			size = MARKER_SIZE,
			color = make_color(0.8, 0.0, 0.0),
		)
	}
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

render_rect :: proc(fb: Frame_Buffer, pos, size: [2]f32, color: Color) {
	pixel := make_pixel(color)
	pos_px, size_px := round_px_region(pos, size)
	region := map_px_region(fb, pos_px, size_px)

	for y in 0 ..< region.size.y {
		row := frame_buffer_row(fb, region.out_offset.y - y)
		row_part := row[region.out_offset.x:][:region.size.x]
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

render_bmp :: proc(
	fb: Frame_Buffer,
	pos: [2]f32,
	align: [2]i32,
	img: Bmp_Image,
) {
	pos := pos - linalg.to_f32(align)
	region := map_px_region(
		fb,
		round_int(pos),
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
				alpha := u32(src_color.a)
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
	// TODO: Using vector opertions is much slower in debug mode. Report bug?
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
