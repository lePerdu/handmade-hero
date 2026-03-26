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
	player_pos: World_Pos,
	player_dir: Player_Dir,
	world_arena: mem.Arena,
	background_texture: Bmp_Image,
	player_textures: [Player_Dir]Player_Textures,
	player_shadow_texture: Bmp_Image,
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

Player_Dir :: enum {
	Right,
	Back,
	Left,
	Front,
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
		mem.arena_init(&state.world_arena, memory.persistent[size_of(State):])
		gen_world(state)
		state.camera_pos = {
			tile = {VIEW_TILES_WIDTH / 2, VIEW_TILES_HEIGHT / 2, 0},
			local = 0,
		}
		state.player_pos = {
			tile = {VIEW_TILES_WIDTH / 3, VIEW_TILES_HEIGHT / 3, 0},
			local = 0,
		}
		state.player_dir = .Front

		state.background_texture = debug_load_bmp(
			memory,
			"assets/early_data/test/test_background.bmp",
		)

		state.player_textures[.Right] = load_player_textures(memory, "right")
		state.player_textures[.Back] = load_player_textures(memory, "back")
		state.player_textures[.Left] = load_player_textures(memory, "left")
		state.player_textures[.Front] = load_player_textures(memory, "front")
		state.player_shadow_texture = debug_load_bmp(
			memory,
			"assets/early_data/test/test_hero_shadow.bmp",
		)

		state.initialized = true
	}
	return state
}

load_player_textures :: proc(
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

@(export)
handmade_game_update :: proc "contextless" (
	memory: api.Memory,
	input: api.Input,
) {
	context = get_game_context(memory)
	state := get_game_state(memory)

	// Sign of the movement: -1, 0, +1
	player_dir: [2]f32
	player_delta: f32 = PLAYER_SPEED * 1e-9 * f32(input.dt_ns)

	if input.keyboard[.Space].end_pressed {
		player_delta *= 3
	}

	if input.keyboard[.W].end_pressed || input.keyboard[.Up].end_pressed {
		player_dir[1] += 1
		// TODO: Base this off the final direction? Prefer a direction?
		// Pick the last-pressed one?
		state.player_dir = .Back
	}
	if input.keyboard[.A].end_pressed || input.keyboard[.Left].end_pressed {
		player_dir[0] -= 1
		state.player_dir = .Left
	}
	if input.keyboard[.S].end_pressed || input.keyboard[.Down].end_pressed {
		player_dir[1] -= 1
		state.player_dir = .Front
	}
	if input.keyboard[.D].end_pressed || input.keyboard[.Right].end_pressed {
		player_dir[0] += 1
		state.player_dir = .Right
	}

	// Scale diagonal movement
	coord_delta := player_delta
	if player_dir[0] != 0 && player_dir[1] != 0 {
		coord_delta *= math.sqrt(f32(0.5))
	}

	new_pos := state.player_pos
	new_pos.local += player_dir * coord_delta

	old_tile_pos := state.player_pos.tile
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

	if state.player_pos.tile != old_tile_pos {
		#partial switch tile_map_get_tile_or_default(
			state.world.tile_map,
			state.player_pos.tile,
		) {
		case .Stair_Up:
			state.player_pos.tile.z += 1
		case .Stair_Down:
			state.player_pos.tile.z -= 1
		}
	}

	state.camera_pos = World_Pos {
		// Move camera by window-sized chunks
		// tile = (state.player_pos.tile / VIEW_TILES_DIMS) *
		// 	VIEW_TILES_DIMS + VIEW_TILES_DIMS / 2,
		// local = 0,
		// Center player
		tile = state.player_pos.tile,
		local = state.player_pos.local,
	}
}

TILE_SIZE_PX :: 60
TILE_OFFSET_PX :: [2]f32{-TILE_SIZE_PX / 2, 0}

PLAYER_WIDTH: f32 : 0.7
PLAYER_HEIGHT: f32 : 1
PLAYER_COLLISION_HEIGHT_TILES: f32 : 0.5
PLAYER_SPEED: f32 : 3 // tile/sec

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

	assert(pos_is_normalized(state.player_pos))

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
		for window_col in -overdraw_x ..< i32(VIEW_TILES_WIDTH) + overdraw_x {
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
				// TODO: How to continue out of a switch?
				color = make_color(0.1)
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
			// Debug: show current player tile
			if state.player_pos.tile == tile_pos {
				color = make_color(1.0)
			} else if tile_val^ == .Empty {
				continue
			}

			render_rect_tile(
				fb,
				pos = (linalg.to_f32(window_pos.xy) - state.camera_pos.local),
				size = 1,
				color = color,
			)
		}
	}

	player_tex := state.player_textures[state.player_dir]

	player_render_pos := world_pos_xy(
		world_pos_sub(state.player_pos, window_origin),
	)
	player_render_pos_px := player_render_pos * TILE_SIZE_PX
	// TODO: Calc render width/height based on image size? Scale bitmaps to fit
	// pre-defined dimensionts?
	render_bmp(
		fb,
		player_render_pos_px,
		// TODO: Is this the proper aling position for the shadow in all
		// directions?
		player_tex.align_px,
		state.player_shadow_texture,
	)
	render_bmp(fb, player_render_pos_px, player_tex.align_px, player_tex.torso)
	render_bmp(fb, player_render_pos_px, player_tex.align_px, player_tex.cape)
	render_bmp(fb, player_render_pos_px, player_tex.align_px, player_tex.head)

	MARKER_SIZE :: 0.1
	render_rect_tile(
		fb,
		pos = player_render_pos + 0.5 - {MARKER_SIZE / 2, 0},
		size = MARKER_SIZE,
		color = make_color(0.8, 0.0, 0.0),
	)
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
