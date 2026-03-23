const std = @import("std");

pub const Memory = extern struct {
    persistent: []u8,
    temporary: []u8,

    debug: DebugInterface,
};

pub const DebugInterface = extern struct {
    ptr: anyopaque,
    read_file: fn (ptr: anyopaque, filename: []const u8) callconv(.c) []u8,
    free_file: fn (ptr: anyopaque, contents: []u8) callconv(.c) void,
};

pub const SymbolTable = extern struct {
    update: *const fn (
        memory: *const Memory,
        input: *const Input,
    ) callconv(.c) void,
    render: *const fn (
        memory: *const Memory,
        fb: *const FrameBuffer,
    ) callconv(.c) void,
    render_audio: *const fn (
        memory: *const Memory,
        timings: AudioTimings,
        // TODO: Make align(1)?
        buffer: []AudioFrame,
    ) callconv(.c) void,
};

pub const Input = extern struct {
    dt_ns: i64,
    keyboard: *const Keyboard,
    mouse: *const Mouse,

    pub const Button = extern struct {
        end_pressed: bool = false,
        transitions: u32 = 0,

        pub fn pressed(self: Button) bool {
            return self.pressCount() > 0;
        }

        pub fn toggled(self: Button) bool {
            return self.pressCount() % 2 == 1;
        }

        pub fn pressCount(self: Button) u32 {
            if (self.end_pressed) {
                // 0->0, 1->1, 2->1, 3->2
                return (self.transitions + 1) / 2;
            } else {
                // 0->0, 1->0, 2->1, 3->1
                return self.transitions / 2;
            }
        }

        pub fn update(self: *Button, is_pressed: bool) void {
            if (is_pressed != self.end_pressed) {
                self.end_pressed = is_pressed;
                self.transitions += 1;
            }
        }

        pub fn reset(self: *Button) void {
            self.transitions = 0;
        }

        pub fn resetAll(buttons: []Button) void {
            // TODO: Is this fine to use for std.EnumArray?
            for (buttons) |*b| {
                b.reset();
            }
        }
    };

    pub const Key = enum(u8) {
        w,
        a,
        s,
        d,
        up,
        left,
        right,
        down,
        space,
    };

    pub const Keyboard = extern struct {
        keys: [n]Button = .{Button{}} ** n,

        const n = std.enums.values(Key).len;

        pub fn getConstPtr(self: *const Keyboard, key: Key) *const Button {
            return self.keys[@intFromEnum(key)];
        }

        pub fn getPtr(self: *Keyboard, key: Key) *Button {
            return &self.keys[@intFromEnum(key)];
        }

        pub fn reset(self: *Keyboard) void {
            Button.resetAll(&self.keys.values);
        }
    };

    pub const MouseButton = enum(u8) { left, middle, right };

    pub const Mouse = extern struct {
        buttons: [n]Button = .{Button{}} ** n,
        pos_x: f32 = 0,
        pos_y: f32 = 0,

        const n = std.enums.values(MouseButton).len;

        pub fn getConstButtonPtr(
            self: *const Mouse,
            button: MouseButton,
        ) *const Button {
            return self.buttons[@intFromEnum(button)];
        }

        pub fn getButtonPtr(
            self: *Mouse,
            button: MouseButton,
        ) *Button {
            return &self.buttons[@intFromEnum(button)];
        }

        pub fn reset(self: *Mouse) void {
            Button.resetAll(&self.buttons.values);
        }
    };
};

pub const FrameBuffer = extern struct {
    width: u32,
    height: u32,
    stride: u32,
    // TODO: Support multiple pixel formats?
    // TODO: Make align(1)?
    pixels: [*]Pixel,

    const empty_pixels: [0]Pixel = .{};
    pub const empty = FrameBuffer{
        .width = 0,
        .height = 0,
        .stride = 0,
        .pixels = &empty_pixels,
    };

    pub const Pixel = extern struct {
        b: u8,
        g: u8,
        r: u8,
        a: u8 = 255,
    };
};

pub const AudioTimings = extern struct {
    write_timestamp_ns: i64,
    sample_rate: u32,
};

pub const AudioFrame = extern struct { l: i16, r: i16 };
