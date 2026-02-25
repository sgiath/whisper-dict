const std = @import("std");
const builtin = @import("builtin");

const config = @import("config.zig");
const input_listener = @import("input_listener.zig");
const recording_indicator = @import("recording_indicator.zig");
const recorder = @import("recorder.zig");
const text_injector = @import("text_injector.zig");
const transcriber = @import("transcriber.zig");

var shutdown_requested = std.atomic.Value(bool).init(false);

const ShutdownSignalGuard = struct {
    previous_int: std.posix.Sigaction,
    previous_term: std.posix.Sigaction,
    previous_hup: std.posix.Sigaction,

    fn install() ShutdownSignalGuard {
        shutdown_requested.store(false, .seq_cst);

        const action = std.posix.Sigaction{
            .handler = .{ .handler = handleShutdownSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };

        var guard: ShutdownSignalGuard = undefined;
        std.posix.sigaction(std.posix.SIG.INT, &action, &guard.previous_int);
        std.posix.sigaction(std.posix.SIG.TERM, &action, &guard.previous_term);
        std.posix.sigaction(std.posix.SIG.HUP, &action, &guard.previous_hup);
        return guard;
    }

    fn deinit(self: *const ShutdownSignalGuard) void {
        std.posix.sigaction(std.posix.SIG.INT, &self.previous_int, null);
        std.posix.sigaction(std.posix.SIG.TERM, &self.previous_term, null);
        std.posix.sigaction(std.posix.SIG.HUP, &self.previous_hup, null);
    }
};

fn handleShutdownSignal(_: i32) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}

pub fn run(allocator: std.mem.Allocator, app_config: config.Config) anyerror!void {
    if (builtin.os.tag != .linux) {
        std.debug.print("Global trigger key capture is currently supported on Linux only.\n", .{});
        return;
    }

    const signal_guard = ShutdownSignalGuard.install();
    defer signal_guard.deinit();

    var listener = try input_listener.Listener.init(allocator, app_config.trigger_key_code);
    defer listener.deinit();

    std.debug.print(
        "Listening globally for {s} on {d} input device(s). Hold {s} to record.\n",
        .{ app_config.trigger_key_label, listener.deviceCount(), app_config.trigger_key_label },
    );

    var active_recording: ?recorder.Session = null;
    var active_indicator: ?recording_indicator.Session = null;
    var indicator_unavailable_reported = false;
    defer cleanupActiveSessions(allocator, &active_recording, &active_indicator);

    while (true) {
        if (shutdown_requested.load(.seq_cst)) {
            std.debug.print("Shutdown signal received; cleaning up.\n", .{});
            break;
        }

        const transition = listener.nextTransition() catch |err| switch (err) {
            error.SignalInterrupt => {
                if (shutdown_requested.load(.seq_cst)) {
                    std.debug.print("Shutdown signal received; cleaning up.\n", .{});
                    break;
                }
                continue;
            },
            else => return err,
        };

        switch (transition) {
            .pressed => {
                if (active_recording != null) continue;

                active_recording = recorder.start(allocator, app_config.recordings_dir) catch |err| blk: {
                    switch (err) {
                        error.NoRecorderAvailable => {
                            std.debug.print("No recorder backend found. Install 'arecord' or 'ffmpeg'.\n", .{});
                        },
                        error.InvalidRecordingsDirectory => {
                            std.debug.print("Invalid recordings directory. Use --recordings-dir <path>.\n", .{});
                        },
                        else => {
                            std.debug.print("Failed to start recording: {s}\n", .{@errorName(err)});
                        },
                    }
                    break :blk null;
                };

                if (active_recording != null and active_indicator == null) {
                    active_indicator = recording_indicator.start(allocator) catch |err| blk: {
                        if (err != error.RecordingIndicatorFailed) {
                            break :blk null;
                        }

                        std.debug.print("Failed to show recording indicator.\n", .{});
                        break :blk null;
                    };

                    if (active_indicator == null and !indicator_unavailable_reported) {
                        std.debug.print(
                            "Recording indicator unavailable (check EWW install/config).\n",
                            .{},
                        );
                        indicator_unavailable_reported = true;
                    }
                }
            },
            .released => {
                if (active_recording) |session| {
                    var recording_to_stop = session;
                    active_recording = null;
                    defer recording_to_stop.deinit(allocator);

                    if (active_indicator) |*indicator| {
                        indicator.stop(allocator);
                        active_indicator = null;
                    }

                    recorder.stop(&recording_to_stop) catch |err| {
                        reportStopRecordingError(err);
                        continue;
                    };

                    const now_ms = std.time.milliTimestamp();
                    const duration_ms_i64 = @max(@as(i64, 0), now_ms - recording_to_stop.started_at_ms);
                    const duration_ms: u64 = @intCast(duration_ms_i64);

                    if (duration_ms < app_config.min_recording_ms) {
                        std.debug.print(
                            "Skipping short recording ({d}ms < {d}ms).\n",
                            .{ duration_ms, app_config.min_recording_ms },
                        );
                        continue;
                    }

                    const transcription = transcriber.transcribe(
                        allocator,
                        recording_to_stop.output_path,
                        app_config.model_path,
                        app_config.language,
                        app_config.min_confidence,
                    ) catch |err| {
                        switch (err) {
                            error.TranscriptionCommandNotFound => {
                                std.debug.print("Could not find whisper-cli in PATH.\n", .{});
                            },
                            error.TranscriptionFailed => {
                                std.debug.print("whisper-cli exited with an error.\n", .{});
                            },
                            error.TranscriptionOutputMissing => {
                                std.debug.print("whisper-cli did not produce a transcription file.\n", .{});
                            },
                            error.TranscriptionConfidenceOutputMissing => {
                                std.debug.print("whisper-cli did not produce a confidence JSON file.\n", .{});
                            },
                            error.TranscriptionConfidenceUnavailable => {
                                std.debug.print("Could not read transcription confidence from whisper-cli output.\n", .{});
                            },
                            else => {
                                std.debug.print("Transcription failed: {s}\n", .{@errorName(err)});
                            },
                        }
                        continue;
                    };
                    defer allocator.free(transcription.text_path);

                    if (transcription.average_token_confidence) |confidence| {
                        if (confidence < app_config.min_confidence) {
                            std.debug.print(
                                "Skipping low-confidence transcription ({d:.3} < {d:.3}).\n",
                                .{ confidence, app_config.min_confidence },
                            );
                            continue;
                        }
                    }

                    std.debug.print("Saved transcription to {s}\n", .{transcription.text_path});

                    text_injector.injectFromFile(allocator, transcription.text_path) catch |err| {
                        switch (err) {
                            error.EmptyTranscription => {
                                std.debug.print("Transcription is empty, nothing to type.\n", .{});
                            },
                            error.NoTextInjectionBackend => {
                                std.debug.print(
                                    "No text injection backend found. Install 'wtype' or 'xdotool'.\n",
                                    .{},
                                );
                            },
                            error.TextInjectionFailed => {
                                std.debug.print("Text injection backend failed to type transcription.\n", .{});
                            },
                            else => {
                                std.debug.print("Text injection failed: {s}\n", .{@errorName(err)});
                            },
                        }
                    };
                }
            },
        }
    }
}

fn cleanupActiveSessions(
    allocator: std.mem.Allocator,
    active_recording: *?recorder.Session,
    active_indicator: *?recording_indicator.Session,
) void {
    if (active_indicator.*) |*indicator| {
        indicator.stop(allocator);
        active_indicator.* = null;
    }

    if (active_recording.*) |*session| {
        recorder.stop(session) catch |err| {
            reportStopRecordingError(err);
        };
        session.deinit(allocator);
        active_recording.* = null;
    }
}

fn reportStopRecordingError(err: anyerror) void {
    switch (err) {
        error.RecordingNotWritten => {
            std.debug.print("Recording stopped, but no WAV file was written.\n", .{});
        },
        error.EmptyRecording => {
            std.debug.print("Recording file was created but is empty.\n", .{});
        },
        else => {
            std.debug.print("Failed to stop recording: {s}\n", .{@errorName(err)});
        },
    }
}
