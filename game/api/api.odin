package game_api

import "core:dynlib"

// Game memory is opaque from the the outside to allow its structure to change
// between share library loads
Memory :: distinct rawptr

Init_Proc :: #type proc "c" (memory: Memory, memory_len: int)
// TODO: Can these use the odin calling convention even when coming from a
// shared library?
Update_Proc :: #type proc "c" (memory: Memory, input: ^Input, dt_ns: i64)
Render_Proc :: #type proc "c" (memory: Memory, fb: ^Frame_Buffer)
Render_Audio_Proc :: #type proc "c" (
	memory: Memory,
	timings: ^Audio_Timings,
	buffer: [^]Audio_Frame,
	buffer_len: int,
)

// Symbol table for use with core:dynlib.initialize_symbols
Symbol_Table :: struct {
	__handle: dynlib.Library,
	init: Init_Proc,
	update: Update_Proc,
	render: Render_Proc,
	render_audio: Render_Audio_Proc,
}

Input :: struct {
	keyboard: Keyboard_Input,
}

Frame_Buffer :: struct {
	base: rawptr,
	width: u32,
	height: u32,
	stride: u32,
}

Audio_Timings :: struct {
	// Approximate timestamp at which the next written samples will be audible
	write_timestamp_ns: i64,
	// Samples/sec
	sample_rate: uint,
}

Audio_Frame :: struct #packed {
	l: i16,
	r: i16,
}

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
