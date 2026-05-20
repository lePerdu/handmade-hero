package platform_x11

import platform ".."
import game_api "../../game/api"
import "base:runtime"
import "core:log"
import "core:sys/posix"
import "vendor:x11/xlib"

State :: struct {
	using common: platform.Display_Common,
	display: ^xlib.Display,
	gc: xlib.GC,
	window: xlib.Window,
	back_buffer_fb: game_api.Frame_Buffer,
	back_buffer_image: xlib.XImage,
	odin_context: runtime.Context,
}

global_state: ^State

init :: proc(state: ^State) -> bool {
	global_state = state
	state.odin_context = context

	state.display = xlib.OpenDisplay(nil)
	if state.display == nil {
		log.fatal("failed to open X11 connection")
		return false
	}

	// TODO: Error handling here
	root_window := xlib.DefaultRootWindow(state.display)
	state.window = xlib.CreateSimpleWindow(
		state.display,
		parent = root_window,
		x = 0,
		y = 0,
		width = platform.DEFAULT_WINDOW_WIDTH,
		height = platform.DEFAULT_WINDOW_HEIGHT,
		bordersz = 0,
		border = 0,
		bg = 0x00aade87,
	)
	// state.gc = xlib.DefaultGC(state.display, xlib.DefaultScreen(state.display))
	state.gc = xlib.CreateGC(state.display, state.window, {}, nil)
	setup_buffers(state)

	log_error :: proc "c" (
		display: ^xlib.Display,
		event: ^xlib.XErrorEvent,
	) -> i32 {
		context = global_state.odin_context
		log_x_error(
			.Error,
			"X11 server error:",
			display,
			xlib.Status(event.error_code),
		)
		return 0
	}
	xlib.SetErrorHandler(log_error)

	xlib.MapWindow(state.display, state.window)
	_ = xlib.Flush(state.display)

	return true
}

@(private)
log_x_error :: proc(
	level: runtime.Logger_Level,
	msg: string,
	display: ^xlib.Display,
	code: xlib.Status,
) {
	err_buf: [64]u8
	xlib.GetErrorText(display, i32(code), &err_buf[0], len(err_buf))

	context = global_state.odin_context
	log.logf(level, "{}: {}", msg, cstring(&err_buf[0]))
}

get_poll_descriptor :: proc(state: ^State) -> (posix.pollfd, bool) {
	return {
			fd = posix.FD(xlib.ConnectionNumber(state.display)),
			events = {.IN},
		},
		true
}

handle_poll :: proc(state: ^State, pollfd: ^posix.pollfd) -> bool {
	for xlib.Pending(state.display) > 0 {
		event: xlib.XEvent
		xlib.NextEvent(state.display, &event)

		#partial switch event.type {
		}
	}
	return true
}

get_back_buffer :: proc(state: ^State) -> (game_api.Frame_Buffer, bool) {
	return state.back_buffer_fb, true
}

submit_frame :: proc(state: ^State) {
	xlib.PutImage(
		state.display,
		state.window,
		state.gc,
		&state.back_buffer_image,
		src_x = 0,
		src_y = 0,
		dst_x = 0,
		dst_y = 0,
		width = state.back_buffer_fb.width,
		height = state.back_buffer_fb.height,
	)
}

submit_first_frame :: proc(state: ^State) {
	submit_frame(state)
}

toggle_fullscreen :: proc(state: ^State) {}

@(private)
setup_buffers :: proc(state: ^State) {
	attrs: xlib.XWindowAttributes
	if ok := xlib.GetWindowAttributes(state.display, state.window, &attrs);
	   !bool(ok) {
		log.panic("failed to query window attributes")
	}

	if state.back_buffer_fb.pixels != nil {
		pixels := cast([^]game_api.Pixel)state.back_buffer_fb.pixels
		delete(
			pixels[:state.back_buffer_fb.width * state.back_buffer_fb.height],
		)
	}
	pixels := make([]game_api.Pixel, attrs.width * attrs.height)
	state.back_buffer_fb = {
		pixels = raw_data(pixels),
		width = u32(attrs.width),
		height = u32(attrs.height),
		stride = u32(attrs.width * size_of(pixels[0])),
	}

	state.back_buffer_image = {
		width = attrs.width,
		height = attrs.height,
		format = .ZPixmap,
		data = state.back_buffer_fb.pixels,
		byte_order = i32(xlib.ByteOrder.LSBFirst),
		bitmap_unit = 32,
		bitmap_bit_order = xlib.ByteOrder.LSBFirst,
		bitmap_pad = 32,
		depth = attrs.depth,
		bytes_per_line = i32(state.back_buffer_fb.stride),
		bits_per_pixel = 8 * size_of(game_api.Pixel),
		red_mask = 0x00FF0000,
		green_mask = 0x0000FF00,
		blue_mask = 0x000000FF,
	}
	if ok := xlib.InitImage(&state.back_buffer_image); !bool(ok) {
		log.panic("failed to initialize back buffer image")
	}
}
