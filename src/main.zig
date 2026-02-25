const std = @import("std");
const app = @import("app.zig");
const config = @import("config.zig");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const result = gpa_state.deinit();
        if (result == .leak) std.debug.print("Warning: memory leak detected.\n", .{});
    }

    var app_config = config.parse(gpa_state.allocator()) catch |err| {
        switch (err) {
            error.MissingModelPath => {
                std.debug.print("Missing model path. Use --model <path>.\n", .{});
            },
            error.MissingRecordingsDir => {
                std.debug.print("Missing recordings directory. Use --recordings-dir <path>.\n", .{});
            },
            error.MissingLanguage => {
                std.debug.print("Missing language. Use --language <code|auto>.\n", .{});
            },
            error.InvalidArgument => {
                std.debug.print("Invalid argument. Use --help for usage.\n", .{});
            },
            else => {
                std.debug.print("Failed to parse args: {s}\n", .{@errorName(err)});
            },
        }

        std.process.exit(1);
    };
    defer app_config.deinit(gpa_state.allocator());

    app.run(gpa_state.allocator(), app_config) catch |err| {
        switch (err) {
            error.NoInputDevicesAccessible => {
                std.debug.print("Could not access /dev/input/event*. Check input-device permissions.\n", .{});
            },
            else => {
                std.debug.print("Recorder failed: {s}\n", .{@errorName(err)});
            },
        }

        std.process.exit(1);
    };
}
