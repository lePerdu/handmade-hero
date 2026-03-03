package main

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

Game_State :: struct {
	x_offset, y_offset: f32,
	play_sound:         bool,
	audio_vol:          f32,
	audio_phase:        f32,
}

game_update :: proc(state: ^Game_State, input: Game_Input, dt_ns: i64) {
	// rate=24p/s
	rate: f32 : 24.0
	x_rate: f32 = 0.0
	y_rate: f32 = 0.0

	// Use +=/-= so that pressing 2 directions at the same time cancels out
	if input.keyboard[.W].end_pressed || input.keyboard[.UP].end_pressed do y_rate += rate
	if input.keyboard[.A].end_pressed || input.keyboard[.Left].end_pressed do x_rate += rate
	if input.keyboard[.S].end_pressed || input.keyboard[.Down].end_pressed do y_rate -= rate
	if input.keyboard[.D].end_pressed || input.keyboard[.Right].end_pressed do x_rate -= rate
	state.x_offset += f32(dt_ns) * x_rate / 1_000_000_000.0
	state.y_offset += f32(dt_ns) * y_rate / 1_000_000_000.0

	state.play_sound = input.keyboard[.Space].end_pressed
}

game_render :: proc(state: ^Game_State, fb: Frame_Buffer) {
	render_gradient(fb, int(state.x_offset), int(state.y_offset))
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

Audio_Output_Config :: struct {
	// Samples/sec
	sample_rate: uint,
}

Audio_Frame :: struct #packed {
	l: i16,
	r: i16,
}

VOLUME :: 0.2
ATTACK_MS :: 500.0

game_render_audio :: proc(
	state: ^Game_State,
	output_config: Audio_Output_Config,
	buffer: []Audio_Frame,
) {
	generate_sine(
		output_config,
		buffer,
		freq = 420.0,
		amp = &state.audio_vol,
		amp_target = state.play_sound ? VOLUME : 0.0,
		phase = &state.audio_phase,
	)
}

generate_sine :: proc(
	output_config: Audio_Output_Config,
	frame_buf: []Audio_Frame,
	freq: f32,
	amp: ^f32,
	amp_target: f32,
	phase: ^f32,
) {
	dt := math.TAU / f32(output_config.sample_rate) * freq
	// amplitude increment for each sample in order to go from 0->VOLUME in ATTACK_MS
	amp_inc := VOLUME / (ATTACK_MS / 1000.0) / f32(output_config.sample_rate)

	t: f32 = phase^
	cur_amp: f32 = amp^
	for _, index in frame_buf {
		if cur_amp <= amp_target {
			cur_amp = min(cur_amp + amp_inc, amp_target)
		} else {
			cur_amp = max(cur_amp - amp_inc, amp_target)
		}
		sample_amp := f32(max(i16)) * cur_amp
		sample := sample_amp * math.sin(t)
		frame_buf[index] = {i16(sample), i16(sample)}
		t += dt
		if t > math.TAU do t -= math.TAU
	}
	phase^ = t
	amp^ = cur_amp
}
