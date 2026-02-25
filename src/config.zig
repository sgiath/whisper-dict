const std = @import("std");

const default_model_path = "models/ggml-large-v3-turbo.bin";
const default_recordings_dir = "recordings";
const default_language = "auto";

pub const Config = struct {
    model_path: []u8,
    recordings_dir: []u8,
    language: []u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.model_path);
        allocator.free(self.recordings_dir);
        allocator.free(self.language);
    }
};

pub fn parse(allocator: std.mem.Allocator) !Config {
    var model_path = try allocator.dupe(u8, default_model_path);
    errdefer allocator.free(model_path);

    var recordings_dir = try defaultRecordingsDir(allocator);
    errdefer allocator.free(recordings_dir);

    var language = try allocator.dupe(u8, default_language);
    errdefer allocator.free(language);

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

        return error.InvalidArgument;
    }

    return .{
        .model_path = model_path,
        .recordings_dir = recordings_dir,
        .language = language,
    };
}

fn printUsage() void {
    std.debug.print(
        "Usage: whisper-dict [--model <path>] [--recordings-dir <path>] [--language <code|auto>]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --model <path>   Whisper model path (default: {s})\n" ++
            "  --recordings-dir <path>  Directory for WAV/TXT output (default: env WHISPER_DICT_RECORDINGS_DIR or {s})\n" ++
            "  --language <code|auto>   Language for whisper-cli (default: {s})\n" ++
            "  -h, --help       Show this help message\n",
        .{ default_model_path, default_recordings_dir, default_language },
    );
}

fn defaultRecordingsDir(allocator: std.mem.Allocator) ![]u8 {
    const env_value = std.process.getEnvVarOwned(allocator, "WHISPER_DICT_RECORDINGS_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };

    if (env_value) |value| {
        if (value.len == 0) {
            allocator.free(value);
            return allocator.dupe(u8, default_recordings_dir);
        }

        return value;
    }

    return allocator.dupe(u8, default_recordings_dir);
}
