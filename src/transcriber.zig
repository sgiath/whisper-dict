const std = @import("std");

pub const Result = struct {
    text_path: []u8,
    average_token_confidence: ?f64,
};

pub fn transcribe(
    allocator: std.mem.Allocator,
    wav_path: []const u8,
    model_path: []const u8,
    language: []const u8,
    min_confidence: f64,
) !Result {
    const output_base = withoutFileExtension(wav_path);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{
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
    });

    if (min_confidence > 0) {
        try argv.append(allocator, "-ojf");
    }

    var child = std.process.Child.init(argv.items, allocator);
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

    if (min_confidence <= 0) {
        return .{
            .text_path = text_path,
            .average_token_confidence = null,
        };
    }

    const json_path = try std.fmt.allocPrint(allocator, "{s}.json", .{output_base});
    defer allocator.free(json_path);

    const average_confidence = averageTokenConfidenceFromJson(allocator, json_path) catch |err| switch (err) {
        error.FileNotFound => return error.TranscriptionConfidenceOutputMissing,
        else => return error.TranscriptionConfidenceUnavailable,
    };

    return .{
        .text_path = text_path,
        .average_token_confidence = average_confidence,
    };
}

fn withoutFileExtension(file_path: []const u8) []const u8 {
    const dot_index = std.mem.lastIndexOfScalar(u8, file_path, '.') orelse return file_path;
    return file_path[0..dot_index];
}

const WhisperJson = struct {
    transcription: []const Segment = &.{},

    const Segment = struct {
        tokens: []const Token = &.{},
    };

    const Token = struct {
        text: []const u8 = "",
        p: f64 = 0,
    };
};

fn averageTokenConfidenceFromJson(allocator: std.mem.Allocator, json_path: []const u8) !?f64 {
    const raw = try std.fs.cwd().readFileAlloc(allocator, json_path, 8 * 1024 * 1024);
    defer allocator.free(raw);

    const parsed = std.json.parseFromSlice(WhisperJson, allocator, raw, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
    defer parsed.deinit();

    var sum: f64 = 0;
    var count: usize = 0;

    for (parsed.value.transcription) |segment| {
        for (segment.tokens) |token| {
            if (isSpecialToken(token.text)) continue;
            if (!std.math.isFinite(token.p)) continue;

            sum += token.p;
            count += 1;
        }
    }

    if (count == 0) return null;
    return sum / @as(f64, @floatFromInt(count));
}

fn isSpecialToken(token_text: []const u8) bool {
    if (token_text.len < 2) return false;
    return token_text[0] == '[' and token_text[token_text.len - 1] == ']';
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

test "averageTokenConfidenceFromJson ignores special tokens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.json",
        .data = "{\n" ++
            "  \"transcription\": [\n" ++
            "    {\n" ++
            "      \"tokens\": [\n" ++
            "        { \"text\": \" hello\", \"p\": 0.6 },\n" ++
            "        { \"text\": \" world\", \"p\": 0.8 },\n" ++
            "        { \"text\": \"[_EOT_]\", \"p\": 0.99 }\n" ++
            "      ]\n" ++
            "    }\n" ++
            "  ]\n" ++
            "}\n",
    });

    const root_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root_path);

    const json_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/sample.json", .{root_path});
    defer std.testing.allocator.free(json_path);

    const confidence = (try averageTokenConfidenceFromJson(std.testing.allocator, json_path)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), confidence, 0.0001);
}
