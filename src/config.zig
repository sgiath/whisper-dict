const std = @import("std");

const default_model_filename = "ggml-large-v3-turbo.bin";
const default_model_path_fallback = "models/ggml-large-v3-turbo.bin";
const default_recordings_dir = "/tmp/whisper-dict-recordings";
const default_language = "auto";
const default_trigger_key = "rightctrl";
const default_min_confidence: f64 = 0.0;
const default_min_recording_ms: u64 = 0;

const TriggerKeyDescriptor = struct {
    code: u16,
    aliases: []const []const u8,
    label: []const u8,
};

const trigger_key_descriptors = [_]TriggerKeyDescriptor{
    .{ .code = 1, .aliases = &.{ "esc", "escape" }, .label = "Escape" },
    .{ .code = 15, .aliases = &.{"tab"}, .label = "Tab" },
    .{ .code = 28, .aliases = &.{ "enter", "return" }, .label = "Enter" },
    .{ .code = 29, .aliases = &.{ "leftctrl", "lctrl", "ctrl" }, .label = "Left Ctrl" },
    .{ .code = 42, .aliases = &.{ "leftshift", "lshift", "shift" }, .label = "Left Shift" },
    .{ .code = 54, .aliases = &.{ "rightshift", "rshift" }, .label = "Right Shift" },
    .{ .code = 56, .aliases = &.{ "leftalt", "lalt", "alt" }, .label = "Left Alt" },
    .{ .code = 57, .aliases = &.{ "space", "spacebar" }, .label = "Space" },
    .{ .code = 58, .aliases = &.{ "capslock", "caps" }, .label = "Caps Lock" },
    .{ .code = 59, .aliases = &.{"f1"}, .label = "F1" },
    .{ .code = 60, .aliases = &.{"f2"}, .label = "F2" },
    .{ .code = 61, .aliases = &.{"f3"}, .label = "F3" },
    .{ .code = 62, .aliases = &.{"f4"}, .label = "F4" },
    .{ .code = 63, .aliases = &.{"f5"}, .label = "F5" },
    .{ .code = 64, .aliases = &.{"f6"}, .label = "F6" },
    .{ .code = 65, .aliases = &.{"f7"}, .label = "F7" },
    .{ .code = 66, .aliases = &.{"f8"}, .label = "F8" },
    .{ .code = 67, .aliases = &.{"f9"}, .label = "F9" },
    .{ .code = 68, .aliases = &.{"f10"}, .label = "F10" },
    .{ .code = 87, .aliases = &.{"f11"}, .label = "F11" },
    .{ .code = 88, .aliases = &.{"f12"}, .label = "F12" },
    .{ .code = 97, .aliases = &.{ "rightctrl", "rctrl" }, .label = "Right Ctrl" },
    .{ .code = 100, .aliases = &.{ "rightalt", "ralt", "altgr" }, .label = "Right Alt" },
    .{ .code = 125, .aliases = &.{ "leftmeta", "lmeta", "leftsuper", "lsuper", "super" }, .label = "Left Meta" },
    .{ .code = 126, .aliases = &.{ "rightmeta", "rmeta", "rightsuper", "rsuper" }, .label = "Right Meta" },
};

const TriggerKey = struct {
    code: u16,
    label: []u8,
};

pub const Config = struct {
    model_path: []u8,
    recordings_dir: []u8,
    language: []u8,
    trigger_key_code: u16,
    trigger_key_label: []u8,
    min_confidence: f64,
    min_recording_ms: u64,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.model_path);
        allocator.free(self.recordings_dir);
        allocator.free(self.language);
        allocator.free(self.trigger_key_label);
    }
};

pub fn parse(allocator: std.mem.Allocator) !Config {
    var model_path = try defaultModelPath(allocator);
    errdefer allocator.free(model_path);

    var recordings_dir = try allocator.dupe(u8, default_recordings_dir);
    errdefer allocator.free(recordings_dir);

    var language = try allocator.dupe(u8, default_language);
    errdefer allocator.free(language);

    var trigger_key = try parseTriggerKey(allocator, default_trigger_key);
    errdefer allocator.free(trigger_key.label);

    var min_confidence = default_min_confidence;
    var min_recording_ms = default_min_recording_ms;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        }

        if (std.mem.eql(u8, arg, "--model")) {
            idx += 1;
            if (idx >= args.len) return error.MissingModelPath;
            allocator.free(model_path);
            model_path = try allocator.dupe(u8, args[idx]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--recordings-dir")) {
            idx += 1;
            if (idx >= args.len) return error.MissingRecordingsDir;
            allocator.free(recordings_dir);
            recordings_dir = try allocator.dupe(u8, args[idx]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--language")) {
            idx += 1;
            if (idx >= args.len) return error.MissingLanguage;
            allocator.free(language);
            language = try allocator.dupe(u8, args[idx]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--trigger-key")) {
            idx += 1;
            if (idx >= args.len) return error.MissingTriggerKey;
            const parsed = try parseTriggerKey(allocator, args[idx]);
            allocator.free(trigger_key.label);
            trigger_key = parsed;
            continue;
        }

        if (std.mem.eql(u8, arg, "--min-confidence")) {
            idx += 1;
            if (idx >= args.len) return error.MissingMinConfidence;
            min_confidence = try parseMinConfidence(args[idx]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--min-recording-ms")) {
            idx += 1;
            if (idx >= args.len) return error.MissingMinRecordingMs;
            min_recording_ms = try parseMinRecordingMs(args[idx]);
            continue;
        }

        const prefix = "--model=";
        if (std.mem.startsWith(u8, arg, prefix)) {
            allocator.free(model_path);
            model_path = try allocator.dupe(u8, arg[prefix.len..]);
            continue;
        }

        const recordings_prefix = "--recordings-dir=";
        if (std.mem.startsWith(u8, arg, recordings_prefix)) {
            allocator.free(recordings_dir);
            recordings_dir = try allocator.dupe(u8, arg[recordings_prefix.len..]);
            continue;
        }

        const language_prefix = "--language=";
        if (std.mem.startsWith(u8, arg, language_prefix)) {
            allocator.free(language);
            language = try allocator.dupe(u8, arg[language_prefix.len..]);
            continue;
        }

        const trigger_key_prefix = "--trigger-key=";
        if (std.mem.startsWith(u8, arg, trigger_key_prefix)) {
            const parsed = try parseTriggerKey(allocator, arg[trigger_key_prefix.len..]);
            allocator.free(trigger_key.label);
            trigger_key = parsed;
            continue;
        }

        const min_confidence_prefix = "--min-confidence=";
        if (std.mem.startsWith(u8, arg, min_confidence_prefix)) {
            min_confidence = try parseMinConfidence(arg[min_confidence_prefix.len..]);
            continue;
        }

        const min_recording_ms_prefix = "--min-recording-ms=";
        if (std.mem.startsWith(u8, arg, min_recording_ms_prefix)) {
            min_recording_ms = try parseMinRecordingMs(arg[min_recording_ms_prefix.len..]);
            continue;
        }

        return error.InvalidArgument;
    }

    return .{
        .model_path = model_path,
        .recordings_dir = recordings_dir,
        .language = language,
        .trigger_key_code = trigger_key.code,
        .trigger_key_label = trigger_key.label,
        .min_confidence = min_confidence,
        .min_recording_ms = min_recording_ms,
    };
}

fn printUsage() void {
    std.debug.print(
        "Usage: whisper-dict [--model <path>] [--recordings-dir <path>] [--language <code|auto>] [--trigger-key <name|code>] [--min-confidence <0..1>] [--min-recording-ms <ms>]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --model <path>   Whisper model path (default: user cache dir + /whisper-dict/models/ggml-large-v3-turbo.bin)\n" ++
            "  --recordings-dir <path>  Directory for WAV/TXT output (default: {s})\n" ++
            "  --language <code|auto>   Language for whisper-cli (default: {s})\n" ++
            "  --trigger-key <name|code>  Push-to-talk key (default: {s})\n" ++
            "  --min-confidence <0..1>  Skip typing below this confidence (default: {d:.2})\n" ++
            "  --min-recording-ms <ms>  Skip transcription below this recording length (default: {d})\n" ++
            "  -h, --help       Show this help message\n",
        .{ default_recordings_dir, default_language, default_trigger_key, default_min_confidence, default_min_recording_ms },
    );
}

fn parseMinConfidence(value: []const u8) !f64 {
    const parsed = std.fmt.parseFloat(f64, value) catch return error.InvalidMinConfidence;
    if (!std.math.isFinite(parsed)) return error.InvalidMinConfidence;
    if (parsed < 0 or parsed > 1) return error.InvalidMinConfidence;
    return parsed;
}

fn parseMinRecordingMs(value: []const u8) !u64 {
    const parsed = std.fmt.parseInt(u64, value, 10) catch return error.InvalidMinRecordingMs;
    return parsed;
}

fn defaultModelPath(allocator: std.mem.Allocator) ![]u8 {
    const xdg_cache_home = std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };

    if (xdg_cache_home) |cache_home| {
        defer allocator.free(cache_home);
        if (cache_home.len == 0) return allocator.dupe(u8, default_model_path_fallback);
        return std.fs.path.join(allocator, &.{ cache_home, "whisper-dict", "models", default_model_filename });
    }

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };

    if (home) |home_dir| {
        defer allocator.free(home_dir);
        if (home_dir.len == 0) return allocator.dupe(u8, default_model_path_fallback);
        return std.fs.path.join(allocator, &.{ home_dir, ".cache", "whisper-dict", "models", default_model_filename });
    }

    return allocator.dupe(u8, default_model_path_fallback);
}

fn parseTriggerKey(allocator: std.mem.Allocator, value: []const u8) !TriggerKey {
    if (value.len == 0) return error.InvalidTriggerKey;

    const numeric_code = std.fmt.parseInt(u16, value, 0) catch null;
    if (numeric_code) |code| {
        return .{
            .code = code,
            .label = try std.fmt.allocPrint(allocator, "Key code {d}", .{code}),
        };
    }

    const normalized = try normalizeTriggerKey(allocator, value);
    defer allocator.free(normalized);

    for (trigger_key_descriptors) |descriptor| {
        for (descriptor.aliases) |alias| {
            if (!std.mem.eql(u8, normalized, alias)) continue;
            return .{
                .code = descriptor.code,
                .label = try allocator.dupe(u8, descriptor.label),
            };
        }
    }

    return error.InvalidTriggerKey;
}

fn normalizeTriggerKey(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(allocator);

    for (value) |char| {
        if (char == ' ' or char == '-' or char == '_') continue;
        try normalized.append(allocator, std.ascii.toLower(char));
    }

    if (normalized.items.len == 0) return error.InvalidTriggerKey;
    return normalized.toOwnedSlice(allocator);
}

test "trigger key parser supports key aliases" {
    const parsed = try parseTriggerKey(std.testing.allocator, "Right-Ctrl");
    defer std.testing.allocator.free(parsed.label);

    try std.testing.expectEqual(@as(u16, 97), parsed.code);
    try std.testing.expectEqualStrings("Right Ctrl", parsed.label);
}

test "trigger key parser supports numeric key code" {
    const parsed = try parseTriggerKey(std.testing.allocator, "0x3f");
    defer std.testing.allocator.free(parsed.label);

    try std.testing.expectEqual(@as(u16, 63), parsed.code);
    try std.testing.expectEqualStrings("Key code 63", parsed.label);
}

test "trigger key parser rejects unknown names" {
    try std.testing.expectError(error.InvalidTriggerKey, parseTriggerKey(std.testing.allocator, "totally-not-a-key"));
}

test "min confidence parser accepts boundary values" {
    try std.testing.expectEqual(@as(f64, 0), try parseMinConfidence("0"));
    try std.testing.expectEqual(@as(f64, 1), try parseMinConfidence("1"));
}

test "min confidence parser rejects out-of-range values" {
    try std.testing.expectError(error.InvalidMinConfidence, parseMinConfidence("-0.1"));
    try std.testing.expectError(error.InvalidMinConfidence, parseMinConfidence("1.1"));
}

test "min recording parser accepts integer milliseconds" {
    try std.testing.expectEqual(@as(u64, 0), try parseMinRecordingMs("0"));
    try std.testing.expectEqual(@as(u64, 250), try parseMinRecordingMs("250"));
}

test "min recording parser rejects invalid values" {
    try std.testing.expectError(error.InvalidMinRecordingMs, parseMinRecordingMs("-1"));
    try std.testing.expectError(error.InvalidMinRecordingMs, parseMinRecordingMs("abc"));
}
