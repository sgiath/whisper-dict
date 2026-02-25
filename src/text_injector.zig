const std = @import("std");

const InjectAttempt = enum {
    success,
    unavailable,
    failed,
};

pub fn injectFromFile(allocator: std.mem.Allocator, text_path: []const u8) !void {
    const text = try std.fs.cwd().readFileAlloc(allocator, text_path, 8 * 1024 * 1024);
    defer allocator.free(text);

    const normalized = try normalizeWhitespace(allocator, text);
    defer allocator.free(normalized);

    if (normalized.len == 0) return error.EmptyTranscription;

    try injectText(allocator, normalized);
}

fn injectText(allocator: std.mem.Allocator, text: []const u8) !void {
    var saw_backend_failure = false;

    switch (try injectWithWtype(allocator, text)) {
        .success => return,
        .unavailable => {},
        .failed => saw_backend_failure = true,
    }

    switch (try injectWithXdotool(allocator, text)) {
        .success => return,
        .unavailable => {},
        .failed => saw_backend_failure = true,
    }

    if (saw_backend_failure) return error.TextInjectionFailed;
    return error.NoTextInjectionBackend;
}

fn injectWithWtype(allocator: std.mem.Allocator, text: []const u8) !InjectAttempt {
    var argv = [_][]const u8{ "wtype", text };
    return runCommand(allocator, argv[0..], null);
}

fn injectWithXdotool(allocator: std.mem.Allocator, text: []const u8) !InjectAttempt {
    var argv = [_][]const u8{ "xdotool", "type", "--delay", "0", "--clearmodifiers", "--file", "-" };
    return runCommand(allocator, argv[0..], text);
}

fn runCommand(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdin_data: ?[]const u8,
) !InjectAttempt {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = if (stdin_data != null) .Pipe else .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch |err| switch (err) {
        error.FileNotFound => return .unavailable,
        else => return err,
    };

    child.waitForSpawn() catch |err| switch (err) {
        error.FileNotFound => return .unavailable,
        else => return err,
    };

    if (stdin_data) |data| {
        if (child.stdin) |*stdin| {
            try stdin.writeAll(data);
            stdin.close();
            child.stdin = null;
        }
    }

    const term = try child.wait();
    return switch (term) {
        .Exited => |code| if (code == 0) .success else .failed,
        else => .failed,
    };
}

fn normalizeWhitespace(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var in_whitespace = true;
    for (input) |byte| {
        const is_ws = std.ascii.isWhitespace(byte);
        if (is_ws) {
            if (!in_whitespace) {
                try out.append(allocator, ' ');
                in_whitespace = true;
            }
            continue;
        }

        try out.append(allocator, byte);
        in_whitespace = false;
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }

    return out.toOwnedSlice(allocator);
}

test "normalizeWhitespace collapses runs and trims edges" {
    const normalized = try normalizeWhitespace(std.testing.allocator, "\n  hello\t\tworld  \r\nzig  ");
    defer std.testing.allocator.free(normalized);

    try std.testing.expectEqualStrings("hello world zig", normalized);
}

test "normalizeWhitespace returns empty for whitespace-only content" {
    const normalized = try normalizeWhitespace(std.testing.allocator, " \n\t\r ");
    defer std.testing.allocator.free(normalized);

    try std.testing.expectEqual(@as(usize, 0), normalized.len);
}
