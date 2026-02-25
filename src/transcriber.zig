const std = @import("std");

pub fn transcribe(
    allocator: std.mem.Allocator,
    wav_path: []const u8,
    model_path: []const u8,
    language: []const u8,
) ![]u8 {
    const output_base = withoutFileExtension(wav_path);

    var argv = [_][]const u8{
        "whisper-cli",
        "-m",
        model_path,
        "-f",
        wav_path,
        "-l",
        language,
        "-otxt",
        "-of",
        output_base,
        "-nt",
        "-np",
    };

    var child = std.process.Child.init(argv[0..], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    child.spawn() catch |err| switch (err) {
        error.FileNotFound => return error.TranscriptionCommandNotFound,
        else => return err,
    };

    child.waitForSpawn() catch |err| switch (err) {
        error.FileNotFound => return error.TranscriptionCommandNotFound,
        else => return err,
    };

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.TranscriptionFailed,
        else => return error.TranscriptionFailed,
    }

    const text_path = try std.fmt.allocPrint(allocator, "{s}.txt", .{output_base});
    errdefer allocator.free(text_path);

    const file = std.fs.cwd().openFile(text_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.TranscriptionOutputMissing,
        else => return err,
    };
    file.close();

    return text_path;
}

fn withoutFileExtension(file_path: []const u8) []const u8 {
    const dot_index = std.mem.lastIndexOfScalar(u8, file_path, '.') orelse return file_path;
    return file_path[0..dot_index];
}

test "withoutFileExtension strips only trailing extension" {
    try std.testing.expectEqualStrings(
        "recordings/session.v1/clip",
        withoutFileExtension("recordings/session.v1/clip.wav"),
    );
}

test "withoutFileExtension leaves extensionless paths unchanged" {
    try std.testing.expectEqualStrings(
        "recordings/session",
        withoutFileExtension("recordings/session"),
    );
}
