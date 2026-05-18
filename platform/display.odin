package platform

import game_api "../game/api"

Engine_Key :: enum {
	P,
	L,
	Esc,
	Num_0,
	Num_1,
	Num_2,
	Num_3,
	Num_4,
	Num_5,
	Num_6,
	Num_7,
	Num_8,
	Num_9,
	F11,
}

DEFAULT_WINDOW_WIDTH :: 960
DEFAULT_WINDOW_HEIGHT :: 540

Display_Common :: struct {
	last_frame_time_ns: i64,
	keyboard_input: game_api.Keyboard_Input,
	mouse_input: game_api.Mouse_Input,
}
