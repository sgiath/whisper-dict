const std = @import("std");

const ev_key: u16 = 0x01;
const key_release: i32 = 0;
const key_press: i32 = 1;

const LinuxInputEvent = extern struct {
    time: std.posix.timeval,
    type: u16,
    code: u16,
    value: i32,
};

const InputDevice = struct {
    file: std.fs.File,
};

pub const TriggerTransition = enum {
    pressed,
    released,
};

pub const Listener = struct {
    allocator: std.mem.Allocator,
    devices: std.ArrayList(InputDevice),
    poll_fds: []std.posix.pollfd,
    device_trigger_down: []bool,
    trigger_key_code: u16,
    poll_fd_count: usize,
    trigger_down_count: usize,

    pub fn init(allocator: std.mem.Allocator, trigger_key_code: u16) !Listener {
        var devices = try collectInputDevices(allocator);
        errdefer closeInputDevices(allocator, &devices);

        const poll_fds = try allocator.alloc(std.posix.pollfd, devices.items.len);
        errdefer allocator.free(poll_fds);

        const device_trigger_down = try allocator.alloc(bool, devices.items.len);
        errdefer allocator.free(device_trigger_down);
        @memset(device_trigger_down, false);

        for (devices.items, 0..) |device, idx| {
            poll_fds[idx] = .{
                .fd = device.file.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
        }

        return .{
            .allocator = allocator,
            .devices = devices,
            .poll_fds = poll_fds,
            .device_trigger_down = device_trigger_down,
            .trigger_key_code = trigger_key_code,
            .poll_fd_count = devices.items.len,
            .trigger_down_count = 0,
        };
    }

    pub fn deinit(self: *Listener) void {
        closeInputDevices(self.allocator, &self.devices);
        self.allocator.free(self.poll_fds);
        self.allocator.free(self.device_trigger_down);
    }

    pub fn deviceCount(self: *const Listener) usize {
        return self.poll_fd_count;
    }

    pub fn nextTransition(self: *Listener) !TriggerTransition {
        while (true) {
            if (self.poll_fd_count == 0) return error.NoInputDevicesAccessible;

            _ = try std.posix.ppoll(self.poll_fds[0..self.poll_fd_count], null, null);

            var idx: usize = 0;
            while (idx < self.poll_fd_count) {
                const poll_fd = &self.poll_fds[idx];
                const revents = poll_fd.revents;
                poll_fd.revents = 0;

                if ((revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) {
                    if (self.removeDevice(idx)) |transition| {
                        return transition;
                    }
                    continue;
                }

                if ((revents & std.posix.POLL.IN) == 0) {
                    idx += 1;
                    continue;
                }

                const event = readInputEvent(&self.devices.items[idx].file) catch |err| switch (err) {
                    error.EndOfStream => {
                        if (self.removeDevice(idx)) |transition| {
                            return transition;
                        }
                        continue;
                    },
                    else => return err,
                };

                if (self.handleInputEvent(idx, event)) |transition| {
                    return transition;
                }

                idx += 1;
            }
        }
    }

    fn handleInputEvent(self: *Listener, device_idx: usize, event: LinuxInputEvent) ?TriggerTransition {
        if (event.type != ev_key) return null;
        if (event.code != self.trigger_key_code) return null;

        const was_any_down = self.trigger_down_count > 0;
        const was_down = self.device_trigger_down[device_idx];

        switch (event.value) {
            key_press => {
                if (!was_down) {
                    self.device_trigger_down[device_idx] = true;
                    self.trigger_down_count += 1;
                }
            },
            key_release => {
                if (was_down) {
                    self.device_trigger_down[device_idx] = false;
                    self.trigger_down_count -= 1;
                }
            },
            else => return null,
        }

        const is_any_down = self.trigger_down_count > 0;

        if (!was_any_down and is_any_down) return .pressed;
        if (was_any_down and !is_any_down) return .released;
        return null;
    }

    fn removeDevice(self: *Listener, idx: usize) ?TriggerTransition {
        if (idx >= self.poll_fd_count) return null;

        const was_any_down = self.trigger_down_count > 0;
        const was_down = self.device_trigger_down[idx];

        if (was_down) {
            self.trigger_down_count -= 1;
        }

        const removed = self.devices.swapRemove(idx);
        removed.file.close();

        const last_idx = self.poll_fd_count - 1;
        if (idx != last_idx) {
            self.poll_fds[idx] = self.poll_fds[last_idx];
            self.device_trigger_down[idx] = self.device_trigger_down[last_idx];
        }

        self.poll_fd_count -= 1;

        const is_any_down = self.trigger_down_count > 0;
        if (was_any_down and !is_any_down) return .released;
        return null;
    }
};

fn collectInputDevices(allocator: std.mem.Allocator) !std.ArrayList(InputDevice) {
    var devices: std.ArrayList(InputDevice) = .empty;
    errdefer closeInputDevices(allocator, &devices);

    var dir = try std.fs.openDirAbsolute("/dev/input", .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "event")) continue;

        const file = dir.openFile(entry.name, .{ .mode = .read_only }) catch |err| switch (err) {
            error.AccessDenied, error.FileNotFound => continue,
            else => return err,
        };

        try devices.append(allocator, .{ .file = file });
    }

    if (devices.items.len == 0) return error.NoInputDevicesAccessible;
    return devices;
}

fn closeInputDevices(allocator: std.mem.Allocator, devices: *std.ArrayList(InputDevice)) void {
    for (devices.items) |device| {
        device.file.close();
    }
    devices.deinit(allocator);
}

fn readInputEvent(file: *const std.fs.File) !LinuxInputEvent {
    var event: LinuxInputEvent = undefined;
    var raw = std.mem.asBytes(&event);
    var offset: usize = 0;

    while (offset < raw.len) {
        const amount = try file.read(raw[offset..]);
        if (amount == 0) return error.EndOfStream;
        offset += amount;
    }

    return event;
}

fn makeKeyEvent(code: u16, value: i32) LinuxInputEvent {
    var event: LinuxInputEvent = undefined;
    event.type = ev_key;
    event.code = code;
    event.value = value;
    return event;
}

fn makeTestListener(allocator: std.mem.Allocator, device_count: usize, trigger_key_code: u16) !Listener {
    const poll_fds = try allocator.alloc(std.posix.pollfd, device_count);
    errdefer allocator.free(poll_fds);
    const device_trigger_down = try allocator.alloc(bool, device_count);
    @memset(device_trigger_down, false);

    return .{
        .allocator = allocator,
        .devices = .empty,
        .poll_fds = poll_fds,
        .device_trigger_down = device_trigger_down,
        .trigger_key_code = trigger_key_code,
        .poll_fd_count = device_count,
        .trigger_down_count = 0,
    };
}

test "transitions are aggregated across multiple devices" {
    const trigger_key_code: u16 = 97;
    var listener = try makeTestListener(std.testing.allocator, 2, trigger_key_code);
    defer listener.deinit();

    try std.testing.expect(listener.handleInputEvent(0, makeKeyEvent(trigger_key_code, key_press)) == .pressed);
    try std.testing.expect(listener.handleInputEvent(0, makeKeyEvent(trigger_key_code, key_press)) == null);
    try std.testing.expect(listener.handleInputEvent(1, makeKeyEvent(trigger_key_code, key_press)) == null);
    try std.testing.expect(listener.handleInputEvent(0, makeKeyEvent(trigger_key_code, key_release)) == null);
    try std.testing.expect(listener.handleInputEvent(1, makeKeyEvent(trigger_key_code, key_release)) == .released);
}

test "non-target keys do not change state" {
    const trigger_key_code: u16 = 97;
    var listener = try makeTestListener(std.testing.allocator, 1, trigger_key_code);
    defer listener.deinit();

    const event = makeKeyEvent(1, key_press);

    try std.testing.expect(listener.handleInputEvent(0, event) == null);
    try std.testing.expect(listener.trigger_down_count == 0);
}
