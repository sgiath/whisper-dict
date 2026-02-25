const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum {
    arecord,
    ffmpeg,
};

pub const Session = struct {
    child: std.process.Child,
    kind: Kind,
    output_path: []u8,

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.output_path);
    }
};

pub fn start(allocator: std.mem.Allocator, recordings_dir: []const u8) !Session {
    try ensureRecordingsDirExists(recordings_dir);

    const output_path = try std.fmt.allocPrint(
        allocator,
        "{s}/recording-{d}.wav",
        .{ recordings_dir, std.time.timestamp() },
    );
    errdefer allocator.free(output_path);

    const spawned_recorder = try spawnRecorder(allocator, output_path);

    std.debug.print(
        "Recording started ({s}) -> {s}\n",
        .{ kindName(spawned_recorder.kind), output_path },
    );

    return .{
        .child = spawned_recorder.child,
        .kind = spawned_recorder.kind,
        .output_path = output_path,
    };
}

pub fn stop(session: *Session) !void {
    try stopProcess(&session.child);
    const term = try session.child.wait();
    maybePrintProcessExit(term);

    try ensureRecordingWasWritten(session.output_path);
    std.debug.print("Saved recording to {s}\n", .{session.output_path});
}

const SpawnedRecorder = struct {
    child: std.process.Child,
    kind: Kind,
};

fn spawnRecorder(allocator: std.mem.Allocator, output_path: []const u8) !SpawnedRecorder {
    if (try spawnArecord(allocator, output_path)) |child| {
        return .{ .child = child, .kind = .arecord };
    }

    if (try spawnFfmpeg(allocator, output_path)) |child| {
        return .{ .child = child, .kind = .ffmpeg };
    }

    return error.NoRecorderAvailable;
}

fn spawnArecord(allocator: std.mem.Allocator, output_path: []const u8) !?std.process.Child {
    var argv = [_][]const u8{
        "arecord",
        "-f",
        "S16_LE",
        "-r",
        "16000",
        "-c",
        "1",
        "-t",
        "wav",
        output_path,
    };

    var child = std.process.Child.init(argv[0..], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    child.spawn() catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    child.waitForSpawn() catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    return child;
}

fn spawnFfmpeg(allocator: std.mem.Allocator, output_path: []const u8) !?std.process.Child {
    var argv = [_][]const u8{
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-f",
        "pulse",
        "-i",
        "default",
        "-ac",
        "1",
        "-ar",
        "16000",
        "-y",
        output_path,
    };

    var child = std.process.Child.init(argv[0..], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    child.spawn() catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    child.waitForSpawn() catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    return child;
}

fn stopProcess(child: *std.process.Child) !void {
    if (builtin.os.tag == .windows) {
        _ = try child.kill();
        return;
    }

    std.posix.kill(child.id, std.posix.SIG.INT) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => return err,
    };
}

fn maybePrintProcessExit(term: std.process.Child.Term) void {
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Recorder exited with code {d}\n", .{code});
            }
        },
        .Signal => |signal| {
            if (builtin.os.tag != .windows and signal != std.posix.SIG.INT) {
                std.debug.print("Recorder ended on signal {d}\n", .{signal});
            }
        },
        .Stopped => |signal| {
            std.debug.print("Recorder stopped on signal {d}\n", .{signal});
        },
        .Unknown => |signal| {
            std.debug.print("Recorder ended with unknown status {d}\n", .{signal});
        },
    }
}

fn ensureRecordingWasWritten(output_path: []const u8) !void {
    const file = std.fs.cwd().openFile(output_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.RecordingNotWritten,
        else => return err,
    };
    defer file.close();

    const file_stat = try file.stat();
    if (file_stat.size == 0) return error.EmptyRecording;
}

fn ensureRecordingsDirExists(recordings_dir: []const u8) !void {
    if (recordings_dir.len == 0) return error.InvalidRecordingsDirectory;
    try std.fs.cwd().makePath(recordings_dir);
}

fn kindName(kind: Kind) []const u8 {
    return switch (kind) {
        .arecord => "arecord",
        .ffmpeg => "ffmpeg",
    };
}
