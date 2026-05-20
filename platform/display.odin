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
	close_requested: bool,
	last_frame_time_ns: i64,
	// Keys that are only used for the engine, not passed to the game code
	engine_keyboard_input: [Engine_Key]game_api.Button_Input,
	keyboard_input: game_api.Keyboard_Input,
	mouse_input: game_api.Mouse_Input,
}
