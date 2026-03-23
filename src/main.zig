const std = @import("std");

const game_api = @import("./game/api.zig");

const State = struct {
    display: WaylandState = .{},
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var state = State{};
    state.display.setup();

    var poll_fds: []std.posix.pollfd = try allocator.alloc(std.posix.pollfd, 1);
    defer allocator.free(poll_fds);

    const wl_display_fd_index: usize = 0;
    poll_fds[wl_display_fd_index] = .{
        .events = std.posix.POLL.IN,
        .revents = 0,
        .fd = wayland.wl_display_get_fd(state.display.wl_display),
    };

    while (true) {
        var wl_err: c_int = 0;

        // Reading/flushing procedure described in `man wl_display(3)` under
        // `wl_display_prepare_read_queue`
        while (wayland.wl_display_prepare_read(state.display.wl_display) != 0) {
            wl_err =
                wayland.wl_display_dispatch_pending(state.display.wl_display);
            std.debug.assert(wl_err != -1);
        }
        wl_err = wayland.wl_display_flush(state.display.wl_display);
        std.debug.assert(wl_err != -1);

        // Result doesn't matter since error is caught in zig's wrapper
        _ = std.posix.poll(poll_fds, -1) catch |err| {
            // TODO: Recover somehow for certain errors?
            std.debug.panic("poll error: {}", .{err});
        };

        // TODO: Call these in a loop?
        {
            wl_err =
                wayland.wl_display_read_events(state.display.wl_display);
            std.debug.assert(wl_err != -1);
            wl_err =
                wayland.wl_display_dispatch_pending(state.display.wl_display);
            std.debug.assert(wl_err != -1);
        }

        if (state.display.close_requested) {
            break;
        }
        if (state.display.engine_keyboard_input.get(.esc).pressed()) {
            break;
        }
    }
}

//
// Wayland
//

const wayland = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell-client-protocol.h");
});

const EngineKey = enum {
    p,
    l,
    esc,
    num_0,
    num_1,
    num_2,
    num_3,
    num_4,
    num_5,
    num_6,
    num_7,
    num_8,
    num_9,
};

const WaylandState = struct {
    wl_display: ?*wayland.wl_display = null,
    wl_registry: ?*wayland.wl_registry = null,

    wl_compositor: ?*wayland.wl_compositor = null,
    wl_shm: ?*wayland.wl_shm = null,
    xdg_wm_base: ?*wayland.xdg_wm_base = null,

    shm_fd: std.posix.fd_t = -1,
    shm_data: []align(std.heap.page_size_min) u8 = &.{},
    wl_shm_pool: ?*wayland.wl_shm_pool = null,

    wl_surface: ?*wayland.wl_surface = null,
    xdg_surface: ?*wayland.xdg_surface = null,
    xdg_toplevel: ?*wayland.xdg_toplevel = null,
    xdg_configure_serial: ?u32 = null,

    buffers: [buffer_count]DisplayBuffer = undefined,
    back_buffer_index: usize = 0,

    frame_cb: ?*wayland.wl_callback = null,
    frame_rate_ns: i64 = 0,
    last_frame_time_ns: i64 = 0,
    last_cb_time_ns: i64 = 0,

    render_state: RenderState = .initial,
    close_requested: bool = false,

    wl_seat: ?*wayland.wl_seat = null,
    wl_keyboard: ?*wayland.wl_keyboard = null,
    wl_pointer: ?*wayland.wl_pointer = null,

    engine_keyboard_input: std.EnumArray(EngineKey, game_api.Input.Button) =
        .initFill(game_api.Input.Button{}),
    keyboard_input: game_api.Input.Keyboard = .{},
    mouse_input: game_api.Input.Mouse = .{},

    const RenderState = enum { initial, pending_configure, configured };

    const buffer_count = 2;
    const DisplayBuffer = struct {
        wl_buffer: ?*wayland.wl_buffer = null,
        state: BufferState = .free,
        fb: game_api.FrameBuffer = .empty,
    };
    const BufferState = enum { free, attached };

    const Self = @This();

    fn setup(self: *Self) void {
        // TODO: Handle errors better than assert
        var wl_err: c_int = 0;

        self.wl_display = wayland.wl_display_connect(null);
        std.debug.assert(self.wl_display != null);
        self.wl_registry = wayland.wl_display_get_registry(self.wl_display);
        std.debug.assert(self.wl_registry != null);
        wl_err = wayland.wl_registry_add_listener(
            self.wl_registry,
            &registry_listener,
            self,
        );
        std.debug.assert(wl_err == 0);

        // TODO: Does this block?
        wl_err = wayland.wl_display_roundtrip(self.wl_display);
        std.debug.assert(wl_err != -1);

        self.wl_surface = wayland.wl_compositor_create_surface(
            self.wl_compositor,
        );
        std.debug.assert(self.wl_surface != null);
        self.xdg_surface = wayland.xdg_wm_base_get_xdg_surface(
            self.xdg_wm_base,
            self.wl_surface,
        );
        std.debug.assert(self.xdg_surface != null);
        wl_err = wayland.xdg_surface_add_listener(
            self.xdg_surface,
            &xdg_surface_listener,
            self,
        );
        std.debug.assert(wl_err == 0);
        self.xdg_toplevel = wayland.xdg_surface_get_toplevel(self.xdg_surface);
        std.debug.assert(self.xdg_toplevel != null);
        wayland.xdg_toplevel_set_title(self.xdg_toplevel, "Handmade Hero");
        wayland.xdg_toplevel_set_app_id(
            self.xdg_toplevel,
            "lePerdu.handmade-hero",
        );

        wl_err = wayland.xdg_toplevel_add_listener(self.xdg_toplevel, &xdg_toplevel_listener, self);
        std.debug.assert(wl_err == 0);

        wl_err = wayland.xdg_wm_base_add_listener(
            self.xdg_wm_base,
            &xdg_wm_base_listener,
            self,
        );
        std.debug.assert(wl_err == 0);

        wl_err = wayland.wl_seat_add_listener(self.wl_seat, &wl_seat_listener, self);
        std.debug.assert(wl_err == 0);

        wayland.wl_surface_commit(self.wl_surface);

        self.setupBuffers();
    }

    fn setupBuffers(self: *Self) void {
        const width: usize = 960;
        const height: usize = 540;

        const stride_px = width;
        const stride_bytes = stride_px * 4;
        const buffer_size_bytes = stride_bytes * height;
        const total_size_bytes = buffer_size_bytes * buffer_count;

        // Free current allocations
        // TODO: Re-use current SHM allocation when possible
        // TODO: Look into wl_shm_pool_resize when growing the pool

        for (&self.buffers) |*buf| {
            if (buf.wl_buffer != null) {
                // TODO: Should destroying the buffer wait until the buffer is released?
                // That could get tricky since events are async...
                wayland.wl_buffer_destroy(buf.wl_buffer);
            }
        }
        if (self.wl_shm_pool != null) {
            wayland.wl_shm_pool_destroy(self.wl_shm_pool);
        }
        self.destroyShmMapping();

        self.creatShmMapping(total_size_bytes);

        self.wl_shm_pool = wayland.wl_shm_create_pool(
            self.wl_shm,
            self.shm_fd,
            @intCast(self.shm_data.len),
        );
        std.debug.assert(self.wl_shm_pool != null);

        for (&self.buffers, 0..) |*buf, i| {
            const offset = i * buffer_size_bytes;

            buf.fb = .{
                .width = width,
                .height = height,
                .stride = stride_px,
                .pixels = @ptrCast(&self.shm_data[offset]),
            };

            buf.wl_buffer = wayland.wl_shm_pool_create_buffer(
                self.wl_shm_pool,
                @intCast(offset),
                @intCast(width),
                @intCast(height),
                @intCast(stride_bytes),
                wayland.WL_SHM_FORMAT_XRGB8888,
            );
            const wl_err = wayland.wl_buffer_add_listener(
                buf.wl_buffer,
                &buffer_listener,
                buf,
            );
            std.debug.assert(wl_err == 0);
            buf.state = .free;
        }

        self.back_buffer_index = 0;

        // Attach one of the new, valid buffers, but don't commit yet since the buffer isn't written
        // TODO: Will this result in blank frames when resizing?
        wayland.wl_surface_attach(
            self.wl_surface,
            self.buffers[self.back_buffer_index].wl_buffer,
            0,
            0,
        );
    }

    fn destroyShmMapping(self: *Self) void {
        if (self.shm_fd == -1) {
            return;
        }
        std.posix.close(self.shm_fd);
        std.posix.munmap(self.shm_data);
    }

    fn creatShmMapping(self: *Self, size: usize) void {
        self.shm_fd = std.posix.memfd_createZ(
            "handmade-hero-wl-shm",
            0,
        ) catch |err| {
            std.debug.panic("failed to create SHM file: {}", .{err});
        };
        std.debug.assert(self.shm_fd != -1);

        std.posix.ftruncate(self.shm_fd, size) catch |err| {
            std.debug.panic(
                "failed to allocate SHM file: {}bytes: {}",
                .{ size, err },
            );
        };

        self.shm_data = std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            std.posix.MAP{ .TYPE = .SHARED },
            self.shm_fd,
            0,
        ) catch |err| {
            std.debug.panic("failed to MMAP SHM file: {}", .{err});
        };
    }

    const registry_listener = wayland.wl_registry_listener{
        .global = &handle_registry_global,
        .global_remove = &handle_registry_global_remove,
    };

    fn drawFrame(self: *Self) void {
        const cur_buf = &self.buffers[self.back_buffer_index];
        // TODO: Check state

        for (0..cur_buf.fb.height) |y| {
            for (0..cur_buf.fb.width) |x| {
                if ((x + y / 8 * 8) % 16 < 8) {
                    cur_buf.fb.pixels[y * cur_buf.fb.stride + x] = .{ .r = 0x66, .g = 0x66, .b = 0x66 };
                } else {
                    cur_buf.fb.pixels[y * cur_buf.fb.stride + x] = .{ .r = 0xEE, .g = 0xEE, .b = 0xEE };
                }
            }
        }

        wayland.wl_surface_attach(self.wl_surface, cur_buf.wl_buffer, 0, 0);
        wayland.wl_surface_damage_buffer(
            self.wl_surface,
            0,
            0,
            std.math.maxInt(i32),
            std.math.maxInt(i32),
        );
        wayland.wl_surface_commit(self.wl_surface);

        self.back_buffer_index = (self.back_buffer_index + 1) % 2;
    }

    fn handle_registry_global(
        data: ?*anyopaque,
        registry: ?*wayland.wl_registry,
        name: u32,
        interface: [*c]const u8,
        version: u32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));

        if (cstringEql(interface, wayland.wl_compositor_interface.name)) {
            self.wl_compositor = @ptrCast(wayland.wl_registry_bind(
                registry,
                name,
                &wayland.wl_compositor_interface,
                version,
            ));
        } else if (cstringEql(interface, wayland.wl_shm_interface.name)) {
            self.wl_shm = @ptrCast(wayland.wl_registry_bind(
                registry,
                name,
                &wayland.wl_shm_interface,
                version,
            ));
        } else if (cstringEql(interface, wayland.xdg_wm_base_interface.name)) {
            self.xdg_wm_base = @ptrCast(wayland.wl_registry_bind(
                registry,
                name,
                &wayland.xdg_wm_base_interface,
                version,
            ));
        } else if (cstringEql(interface, wayland.wl_seat_interface.name)) {
            self.wl_seat = @ptrCast(wayland.wl_registry_bind(
                registry,
                name,
                &wayland.wl_seat_interface,
                version,
            ));
        }
    }

    fn handle_registry_global_remove(
        data: ?*anyopaque,
        registry: ?*wayland.wl_registry,
        name: u32,
    ) callconv(.c) void {
        _ = data;
        _ = registry;
        _ = name;
        // TODO: Make sure important globals aren't removed?
    }

    const xdg_wm_base_listener = wayland.xdg_wm_base_listener{
        .ping = &handle_xdg_wm_base_ping,
    };

    fn handle_xdg_wm_base_ping(
        data: ?*anyopaque,
        xdg_wm_base: ?*wayland.xdg_wm_base,
        serial: u32,
    ) callconv(.c) void {
        _ = data;
        wayland.xdg_wm_base_pong(xdg_wm_base, serial);
    }

    const xdg_toplevel_listener = wayland.xdg_toplevel_listener{
        .close = &handleXdgToplevelClose,
        .configure = &handleXdgToplevelConfigure,
        .configure_bounds = &handleXdgToplevelConfigureBounds,
        // TODO: Handle toplevel_configure?
    };

    fn handleXdgToplevelClose(
        data: ?*anyopaque,
        toplevel: ?*wayland.xdg_toplevel,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        _ = toplevel;
        self.close_requested = true;
    }

    fn handleXdgToplevelConfigure(
        data: ?*anyopaque,
        toplevel: ?*wayland.xdg_toplevel,
        width: i32,
        height: i32,
        states: [*c]wayland.wl_array,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        _ = self;
        _ = toplevel;
        // TODO: Handle these?
        _ = width;
        _ = height;
        defer if (states.*.alloc > 0) {
            wayland.wl_array_release(states);
        };
    }

    fn handleXdgToplevelConfigureBounds(
        data: ?*anyopaque,
        toplevel: ?*wayland.xdg_toplevel,
        width: i32,
        height: i32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        _ = self;
        _ = toplevel;
        // TODO: Handle these?
        _ = width;
        _ = height;
    }

    const xdg_surface_listener = wayland.xdg_surface_listener{
        .configure = &handle_xdg_surface_configure,
    };

    fn handle_xdg_surface_configure(
        data: ?*anyopaque,
        surface: ?*wayland.xdg_surface,
        serial: u32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        self.xdg_configure_serial = serial;

        _ = wayland.xdg_surface_ack_configure(
            surface,
            self.xdg_configure_serial.?,
        );
        self.xdg_configure_serial = 0;

        self.drawFrame();
    }

    const buffer_listener = wayland.wl_buffer_listener{
        .release = &handle_wl_buffer_release,
    };

    fn handle_wl_buffer_release(
        data: ?*anyopaque,
        wl_buffer: ?*wayland.wl_buffer,
    ) callconv(.c) void {
        // const self: *Self = @ptrCast(@alignCast(data.?));
        const display_buf: *DisplayBuffer = @ptrCast(@alignCast(data.?));
        std.debug.assert(display_buf.wl_buffer == wl_buffer);
        display_buf.state = .free;
    }

    const wl_seat_listener = wayland.wl_seat_listener{
        .name = &handle_wl_seat_name,
        .capabilities = &handle_wl_seat_capabilities,
    };

    fn handle_wl_seat_name(
        data: ?*anyopaque,
        seat: ?*wayland.wl_seat,
        name: [*c]const u8,
    ) callconv(.c) void {
        _ = data;
        _ = seat;
        std.log.debug("wl_seat name: {s}", .{name});
    }

    fn handle_wl_seat_capabilities(
        data: ?*anyopaque,
        seat: ?*wayland.wl_seat,
        caps: u32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        if (caps & wayland.WL_SEAT_CAPABILITY_KEYBOARD != 0) {
            self.wl_keyboard = wayland.wl_seat_get_keyboard(seat);
            std.debug.assert(self.wl_keyboard != null);
            const wl_err = wayland.wl_keyboard_add_listener(
                self.wl_keyboard,
                &keyboard_listener,
                self,
            );
            std.debug.assert(wl_err == 0);
        } else {
            std.log.err("wl_keyboard not available", .{});
        }

        if (caps & wayland.WL_SEAT_CAPABILITY_POINTER != 0) {
            self.wl_pointer = wayland.wl_seat_get_pointer(seat);
            std.debug.assert(self.wl_pointer != null);
            const wl_err = wayland.wl_pointer_add_listener(
                self.wl_pointer,
                &pointer_listener,
                self,
            );
            std.debug.assert(wl_err == 0);
        } else {
            std.log.err("wl_pointer not available", .{});
        }
    }

    const keyboard_listener = wayland.wl_keyboard_listener{
        .keymap = &handleKeyboardKeymap,
        .enter = &handleKeyboardEnter,
        .leave = &handleKeyboardLeave,
        .key = &handleKeyboardKey,
        .modifiers = &handleKeyboardModifiers,
        .repeat_info = &handleKeyboardRepeatInfo,
    };

    fn handleKeyboardEnter(
        data: ?*anyopaque,
        keyboard: ?*wayland.wl_keyboard,
        serial: u32,
        surface: ?*wayland.wl_surface,
        keys: [*c]wayland.wl_array,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        _ = keyboard;
        _ = serial;
        _ = surface;
        defer if (keys.*.alloc > 0) {
            wayland.wl_array_release(keys);
        };
        const keys_bytes = @as([*]u8, @ptrCast(keys.*.data));
        const keys_slice = std.mem.bytesAsSlice(u32, keys_bytes[0..keys.*.size]);
        for (keys_slice) |key| {
            self.handleKeyEvent(key, true);
        }
    }

    fn handleKeyboardLeave(
        data: ?*anyopaque,
        keyboard: ?*wayland.wl_keyboard,
        serial: u32,
        surface: ?*wayland.wl_surface,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        _ = keyboard;
        _ = serial;
        _ = surface;
        // Un-press all keys (TODO: Keep them pressed?)
        for (&self.keyboard_input.keys) |*key| {
            key.update(false);
        }
        for (&self.engine_keyboard_input.values) |*key| {
            key.update(false);
        }
    }

    fn handleKeyboardKey(
        data: ?*anyopaque,
        keyboard: ?*wayland.wl_keyboard,
        serial: u32,
        time: u32,
        key: u32,
        state: u32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        _ = keyboard;
        _ = serial;
        _ = time;
        self.handleKeyEvent(key, state == wayland.WL_KEYBOARD_KEY_STATE_PRESSED);
    }

    fn handleKeyboardModifiers(
        data: ?*anyopaque,
        keyboard: ?*wayland.wl_keyboard,
        serial: u32,
        depressed: u32,
        latched: u32,
        locked: u32,
        group: u32,
    ) callconv(.c) void {
        _ = data;
        _ = keyboard;
        _ = serial;
        _ = depressed;
        _ = latched;
        _ = locked;
        _ = group;
    }

    fn handleKeyboardRepeatInfo(
        data: ?*anyopaque,
        keyboard: ?*wayland.wl_keyboard,
        _: i32,
        _: i32,
    ) callconv(.c) void {
        _ = data;
        _ = keyboard;
    }

    fn handleKeyboardKeymap(
        data: ?*anyopaque,
        keyboard: ?*wayland.wl_keyboard,
        format: u32,
        fd: std.posix.fd_t,
        size: u32,
    ) callconv(.c) void {
        _ = data;
        _ = keyboard;
        _ = format;
        _ = size;
        // Just free FD since it isn't needed
        std.posix.close(fd);
    }

    fn getKeyButton(self: *Self, wl_key: u32) ?*game_api.Input.Button {
        const KEY_W = 17;
        const KEY_A = 30;
        const KEY_S = 31;
        const KEY_D = 32;

        const KEY_UP = 103;
        const KEY_LEFT = 105;
        const KEY_DOWN = 108;
        const KEY_RIGHT = 106;
        const KEY_SPACE = 57;

        const KEY_1 = 2;
        const KEY_2 = 3;
        const KEY_3 = 4;
        const KEY_4 = 5;
        const KEY_5 = 6;
        const KEY_6 = 7;
        const KEY_7 = 8;
        const KEY_8 = 9;
        const KEY_9 = 10;
        const KEY_0 = 11;
        const KEY_L = 38;
        const KEY_P = 25;
        const KEY_ESC = 1;

        return switch (wl_key) {
            KEY_W => self.keyboard_input.getPtr(.w),
            KEY_A => self.keyboard_input.getPtr(.a),
            KEY_S => self.keyboard_input.getPtr(.s),
            KEY_D => self.keyboard_input.getPtr(.d),
            KEY_UP => self.keyboard_input.getPtr(.up),
            KEY_DOWN => self.keyboard_input.getPtr(.down),
            KEY_LEFT => self.keyboard_input.getPtr(.left),
            KEY_RIGHT => self.keyboard_input.getPtr(.right),
            KEY_SPACE => self.keyboard_input.getPtr(.space),

            KEY_1 => self.engine_keyboard_input.getPtr(.num_1),
            KEY_2 => self.engine_keyboard_input.getPtr(.num_2),
            KEY_3 => self.engine_keyboard_input.getPtr(.num_3),
            KEY_4 => self.engine_keyboard_input.getPtr(.num_4),
            KEY_5 => self.engine_keyboard_input.getPtr(.num_5),
            KEY_6 => self.engine_keyboard_input.getPtr(.num_6),
            KEY_7 => self.engine_keyboard_input.getPtr(.num_7),
            KEY_8 => self.engine_keyboard_input.getPtr(.num_8),
            KEY_9 => self.engine_keyboard_input.getPtr(.num_9),
            KEY_0 => self.engine_keyboard_input.getPtr(.num_0),
            KEY_L => self.engine_keyboard_input.getPtr(.l),
            KEY_P => self.engine_keyboard_input.getPtr(.p),
            KEY_ESC => self.engine_keyboard_input.getPtr(.esc),

            else => null,
        };
    }

    fn handleKeyEvent(self: *Self, wl_key: u32, pressed: bool) void {
        if (self.getKeyButton(wl_key)) |button| {
            button.update(pressed);
        }
    }

    const pointer_listener = wayland.wl_pointer_listener{
        .enter = &handlePointerEnter,
        .leave = &handlePointerLeave,
        .button = &handlePointerButton,
        .motion = &handlePointerMotion,
        .frame = &handlePointerFrame,
    };

    fn handlePointerEnter(
        data: ?*anyopaque,
        pointer: ?*wayland.wl_pointer,
        serial: u32,
        surface: ?*wayland.wl_surface,
        x: wayland.wl_fixed_t,
        y: wayland.wl_fixed_t,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        _ = pointer;
        _ = serial;
        _ = surface;
        // TODO: Setup custom cursor
        self.updatePointerPos(x, y);
    }

    fn handlePointerLeave(
        data: ?*anyopaque,
        pointer: ?*wayland.wl_pointer,
        serial: u32,
        surface: ?*wayland.wl_surface,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = serial;
        _ = surface;
    }

    fn getPointerButton(self: *Self, wl_button: u32) ?*game_api.Input.Button {
        // From linux/input-event-codes.h
        const BTN_LEFT = 0x110;
        const BTN_RIGHT = 0x111;
        const BTN_MIDDLE = 0x112;
        return switch (wl_button) {
            BTN_LEFT => self.mouse_input.getButtonPtr(.left),
            BTN_RIGHT => self.mouse_input.getButtonPtr(.right),
            BTN_MIDDLE => self.mouse_input.getButtonPtr(.middle),
            else => null,
        };
    }

    fn handlePointerButton(
        data: ?*anyopaque,
        pointer: ?*wayland.wl_pointer,
        serial: u32,
        time: u32,
        button: u32,
        state: u32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        _ = pointer;
        _ = serial;
        _ = time;
        if (self.getPointerButton(button)) |btn| {
            btn.update(state == wayland.WL_POINTER_BUTTON_STATE_PRESSED);
        }
    }

    fn handlePointerMotion(
        data: ?*anyopaque,
        pointer: ?*wayland.wl_pointer,
        time: u32,
        x: wayland.wl_fixed_t,
        y: wayland.wl_fixed_t,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        _ = pointer;
        _ = time;
        self.updatePointerPos(x, y);
    }

    fn updatePointerPos(
        self: *Self,
        x: wayland.wl_fixed_t,
        y: wayland.wl_fixed_t,
    ) void {
        self.mouse_input.pos_x = @floatCast(wayland.wl_fixed_to_double(x));
        self.mouse_input.pos_y = @floatCast(wayland.wl_fixed_to_double(y));
    }

    fn handlePointerFrame(
        data: ?*anyopaque,
        pointer: ?*wayland.wl_pointer,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
    }
};

// TODO: Does this function exist in std? Should `stdlen` from c stdlib be used?
fn cstringEql(a: [*c]const u8, b: [*c]const u8) bool {
    var i: usize = 0;
    while (true) : (i += 1) {
        if (a[i] == 0 and b[i] == 0) {
            return true;
        } else if (a[i] == 0 or b[i] == 0) {
            return false;
        } else if (a[i] != b[i]) {
            return false;
        }
    }
}
