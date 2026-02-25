const std = @import("std");

const CommandResult = enum {
    success,
    unavailable,
    failed,
};

pub const Session = struct {
    eww_config_dir: []u8,

    pub fn stop(self: *Session, allocator: std.mem.Allocator) void {
        var argv = [_][]const u8{ "eww", "--config", self.eww_config_dir, "close", "recording_overlay" };
        _ = runCommand(allocator, argv[0..]) catch {};
        allocator.free(self.eww_config_dir);
    }
};

pub fn start(allocator: std.mem.Allocator) !?Session {
    const eww_config_dir = try resolveConfigDir(allocator) orelse return null;
    errdefer allocator.free(eww_config_dir);

    var daemon_argv = [_][]const u8{ "eww", "--config", eww_config_dir, "daemon" };
    const daemon_result = try runCommand(allocator, daemon_argv[0..]);
    if (daemon_result == .unavailable) return null;

    var open_argv = [_][]const u8{ "eww", "--config", eww_config_dir, "open", "recording_overlay" };
    return switch (try runCommand(allocator, open_argv[0..])) {
        .success => .{ .eww_config_dir = eww_config_dir },
        .unavailable => null,
        .failed => error.RecordingIndicatorFailed,
    };
}

fn resolveConfigDir(allocator: std.mem.Allocator) !?[]u8 {
    const local_dir = "eww";
    if (try configExists(allocator, local_dir)) {
        return @as(?[]u8, try allocator.dupe(u8, local_dir));
    }

    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;

    const dev_dir = try std.fs.path.join(allocator, &.{ exe_dir, "..", "..", "eww" });
    errdefer allocator.free(dev_dir);
    if (try configExists(allocator, dev_dir)) {
        return @as(?[]u8, dev_dir);
    }

    const prefix_dir = std.fs.path.dirname(exe_dir) orelse return null;
    const packaged_dir = try std.fs.path.join(allocator, &.{ prefix_dir, "share", "whisper-dict", "eww" });
    errdefer allocator.free(packaged_dir);

    if (try configExists(allocator, packaged_dir)) {
        return @as(?[]u8, packaged_dir);
    }

    return null;
}

fn configExists(allocator: std.mem.Allocator, config_dir: []const u8) !bool {
    const yuck_path = try std.fs.path.join(allocator, &.{ config_dir, "eww.yuck" });
    defer allocator.free(yuck_path);

    const scss_path = try std.fs.path.join(allocator, &.{ config_dir, "eww.scss" });
    defer allocator.free(scss_path);

    const yuck_file = openAnyPath(yuck_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    yuck_file.close();

    const scss_file = openAnyPath(scss_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    scss_file.close();

    return true;
}

fn openAnyPath(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, .{});
    }

    return std.fs.cwd().openFile(path, .{});
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !CommandResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    child.spawn() catch |err| switch (err) {
        error.FileNotFound => return .unavailable,
        else => return err,
    };

    child.waitForSpawn() catch |err| switch (err) {
        error.FileNotFound => return .unavailable,
        else => return err,
    };

    const term = try child.wait();
    return switch (term) {
        .Exited => |code| if (code == 0) .success else .failed,
        else => .failed,
    };
}

fn tmpRootPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test "configExists requires both eww config files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "eww.yuck", .data = "(defwindow recording_overlay [])" });

    const relative_dir = try tmpRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(relative_dir);

    try std.testing.expect(!(try configExists(std.testing.allocator, relative_dir)));

    try tmp.dir.writeFile(.{ .sub_path = "eww.scss", .data = "* { color: white; }" });
    try std.testing.expect(try configExists(std.testing.allocator, relative_dir));
}

test "configExists works with absolute paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "eww.yuck", .data = "(defwindow recording_overlay [])" });
    try tmp.dir.writeFile(.{ .sub_path = "eww.scss", .data = "* { color: white; }" });

    const relative_dir = try tmpRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(relative_dir);

    const absolute_dir = try std.fs.cwd().realpathAlloc(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(absolute_dir);

    try std.testing.expect(try configExists(std.testing.allocator, absolute_dir));
}
