package main

import "core:log"
import "core:math"
import "core:mem"

// Enum of the keys we care about
Key :: enum {
	W,
	A,
	S,
	D,
	UP,
	Left,
	Right,
	Down,
	Space,
	Esc,
}

Button_Input :: struct {
	end_pressed: bool,
	transitions: u32,
}

Keyboard_Input :: [Key]Button_Input

Game_Input :: struct {
	keyboard: Keyboard_Input,
}

button_input_press_count :: proc(button: Button_Input) -> u32 {
	if button.end_pressed {
		// 0->0
		// 1->1
		// 2->1
		// 3->2
		return (button.transitions + 1) / 2
	} else {
		// 0->0
		// 1->0
		// 2->1
		// 3->1
		return button.transitions / 2
	}
}

button_input_update :: proc(button: ^Button_Input, pressed: bool) {
	if pressed != button.end_pressed {
		button.end_pressed = pressed
		button.transitions += 1
	}
}

// Reset input data after a state change
keyboard_input_reset :: proc(input: ^Keyboard_Input) {
	for &key in input {
		key.transitions = 0
	}
}

Frame_Buffer :: struct {
	base:   rawptr,
	width:  u32,
	height: u32,
	stride: u32,
}

// TOOD: Make non-global
x_offset, y_offset: f32

game_render :: proc(fb: Frame_Buffer, input: Game_Input, dt_ns: i64) {
	// rate=24p/s
	rate: f32 : 24.0
	x_rate: f32 = 0.0
	y_rate: f32 = 0.0

	// Use +=/-= so that pressing 2 directions at the same time cancels out
	if input.keyboard[.W].end_pressed || input.keyboard[.UP].end_pressed do y_rate += rate
	if input.keyboard[.A].end_pressed || input.keyboard[.Left].end_pressed do x_rate += rate
	if input.keyboard[.S].end_pressed || input.keyboard[.Down].end_pressed do y_rate -= rate
	if input.keyboard[.D].end_pressed || input.keyboard[.Right].end_pressed do x_rate -= rate
	x_offset += f32(dt_ns) * x_rate / 1_000_000_000.0
	y_offset += f32(dt_ns) * y_rate / 1_000_000_000.0

	render_gradient(fb, int(x_offset), int(y_offset))
}

Pixel :: distinct u32

make_pixel :: proc(r, g, b: u8) -> Pixel {
	return Pixel(u32(r) << 16 | u32(g) << 8 | u32(b))
}

frame_buffer_row :: proc(fb: Frame_Buffer, y: u32) -> []Pixel {
	assert(y < fb.height)
	return mem.slice_ptr((^Pixel)(uintptr(fb.base) + uintptr(y * fb.stride)), int(fb.width))
}

render_gradient :: proc(fb: Frame_Buffer, x_offset, y_offset: int) {
	for y in 0 ..< fb.height {
		row := frame_buffer_row(fb, y)
		for x in 0 ..< fb.width {
			// TODO: Is casting to u8 the "proper" way to wrap?
			row[x] = make_pixel(0, u8(int(y) + y_offset), u8(int(x) + x_offset))
		}
	}
}

Audio_Frame :: struct #packed {
	l: i16,
	r: i16,
}

global_phase: f32

game_render_audio :: proc(buffer: []Audio_Frame, input: Game_Input) {
	play_sound := input.keyboard[.Space].end_pressed
	generate_sine(buffer, freq = 420.0, amp = play_sound ? 0.2 : 0.0, phase = &global_phase)
}

generate_sine :: proc(frame_buf: []Audio_Frame, freq: f32, amp: f32, phase: ^f32) {
	sample_amp := f32(max(i16)) * amp
	dt := math.TAU / SAMPLE_RATE * freq

	t: f32 = phase^
	for _, index in frame_buf {
		sample := sample_amp * math.sin(t)
		frame_buf[index] = {i16(sample), i16(sample)}
		t += dt
		if t > math.TAU do t -= math.TAU
	}
	phase^ = t
}
