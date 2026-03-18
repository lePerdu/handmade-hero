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
	world: World,
	player_pos: World_Pos,
	world_arena: mem.Arena,
}

World :: struct {
	tile_map: Tile_Map,
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
		mem.arena_init(&state.world_arena, memory.persistent[size_of(State):])
		gen_world(state)
		state.player_pos = {
			tile = WINDOW_CENTER,
			local = 0,
		}
		state.initialized = true
	}
	return state
}

gen_world :: proc(state: ^State) {
	SCREENS_X :: 32
	SCREENS_Y :: 32

	context.allocator = mem.arena_allocator(&state.world_arena)

	map_size := [2]i32 {
		SCREENS_X * WINDOW_TILES_WIDTH / CHUNK_SIZE,
		SCREENS_Y * WINDOW_TILES_HEIGHT / CHUNK_SIZE,
	}
	state.world.tile_map = {
		size = map_size,
		chunks = make([^]Tile_Chunk, int(map_size[0] * map_size[1])),
	}
	for chunk_y in 0 ..< map_size[1] {
		for chunk_x in 0 ..< map_size[0] {
			chunk, ok := tile_map_get_chunk(
				state.world.tile_map,
				{chunk_x, chunk_y},
			)
			assert(ok)
			chunk.tiles = new(type_of(chunk.tiles^))
		}
	}

	for screen_y in 0 ..< i32(SCREENS_Y) {
		for screen_x in 0 ..< i32(SCREENS_X) {
			for y in 0 ..< i32(WINDOW_TILES_HEIGHT) {
				for x in 0 ..< i32(WINDOW_TILES_WIDTH) {
					pos := [2]i32 {
						screen_x * WINDOW_TILES_WIDTH + x,
						screen_y * WINDOW_TILES_HEIGHT + y,
					}
					tile, ok := tile_map_get_tile(state.world.tile_map, pos)
					assert(ok)
					if x % 7 == y + screen_x % 5 + screen_y % 3 {
						tile^ = 1
					} else {
						tile^ = 0
					}
				}
			}
		}
	}
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

	if can_move_in_tile_map(
		   state.world.tile_map,
		   offset_pos(new_pos, -PLAYER_WIDTH / 2, 0),
	   ) &&
	   can_move_in_tile_map(
		   state.world.tile_map,
		   offset_pos(new_pos, PLAYER_WIDTH / 2, 0),
	   ) &&
	   can_move_in_tile_map(
		   state.world.tile_map,
		   offset_pos(new_pos, 0, PLAYER_COLLISION_HEIGHT_TILES),
	   ) {
		state.player_pos = normalize_pos(new_pos)
	}
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

	// `- 1` to account for the screen overlap
	WINDOW_TILES_DIMS :: [2]i32{WINDOW_TILES_WIDTH - 1, WINDOW_TILES_HEIGHT}
	window_tile_offset :=
		(state.player_pos.tile / WINDOW_TILES_DIMS) * WINDOW_TILES_DIMS

	for row in 0 ..< i32(WINDOW_TILES_HEIGHT) {
		for col in 0 ..< i32(WINDOW_TILES_WIDTH) {
			window_pos := [2]i32{col, row}
			tile_pos := window_pos + window_tile_offset
			tile_val, ok := tile_map_get_tile(state.world.tile_map, tile_pos)
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
		pos = (linalg.to_f32(state.player_pos.tile - window_tile_offset) +
			state.player_pos.local +
			0.5 -
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
