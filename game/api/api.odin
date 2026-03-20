package game_api

import "base:intrinsics"
import "core:dynlib"

// Game memory is opaque from the the outside to allow its structure to change
// between share library loads
Memory :: struct {
	persistent: []byte,
	// TODO: Replace with virtual mem arena?
	temporary: []byte,
	debug: struct {
		data: rawptr,
		read_file: #type proc "contextless" (
			data: rawptr,
			filename: string,
		) -> []byte,
		free_file: #type proc "contextless" (data: rawptr, contents: []byte),
	},
}

// TODO: Can these use the odin calling convention even when coming from a
// shared library?
Update_Proc :: #type proc "contextless" (memory: Memory, input: Input)
Render_Proc :: #type proc "contextless" (memory: Memory, fb: Frame_Buffer)
Render_Audio_Proc :: #type proc "contextless" (
	memory: Memory,
	timings: Audio_Timings,
	buffer: []Audio_Frame,
)

// Symbol table for use with core:dynlib.initialize_symbols
Symbol_Table :: struct {
	__handle: dynlib.Library,
	update: Update_Proc,
	render: Render_Proc,
	render_audio: Render_Audio_Proc,
}

dummy_symbol_table := Symbol_Table {
	update = dummy_update,
	render = dummy_render,
	render_audio = dummy_render_audio,
}

dummy_update :: proc "contextless" (memory: Memory, input: Input) {}
dummy_render :: proc "contextless" (memory: Memory, fb: Frame_Buffer) {}
dummy_render_audio :: proc "contextless" (
	memory: Memory,
	timings: Audio_Timings,
	buffer: []Audio_Frame,
) {}

Input :: struct {
	dt_ns: i64,
	keyboard: Keyboard_Input,
	mouse: Mouse_Input,
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
	Up,
	Left,
	Right,
	Down,
	Space,
}

Button_Input :: struct {
	end_pressed: bool,
	transitions: u32,
}

Keyboard_Input :: [Key]Button_Input

Mouse_Button :: enum {
	Left,
	Middle,
	Right,
}

Mouse_Input :: struct {
	// TODO: Store position at which button presses occur? Would require having
	// a limited number of mouse events
	buttons: [Mouse_Button]Button_Input,
	pos_x: f32,
	pos_y: f32,
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

button_input_pressed :: proc(button: Button_Input) -> bool {
	return button_input_press_count(button) > 0
}

button_input_toggled :: proc(button: Button_Input) -> bool {
	return button_input_press_count(button) % 2 == 1
}

button_input_update :: proc(button: ^Button_Input, pressed: bool) {
	if pressed != button.end_pressed {
		button.end_pressed = pressed
		button.transitions += 1
	}
}

// Reset input data after a state change
keyboard_input_reset :: proc(input: ^[$E]Button_Input) {
	for &key in input {
		key.transitions = 0
	}
}

mouse_input_reset :: proc(input: ^Mouse_Input) {
	for &b in input.buttons {
		b.transitions = 0
	}
}
