# Developer docs

This file contains developer-facing notes for `whisper-dict`.
User-facing setup and usage are in `../README.md`.

## Intent

This project is intended to feel like push-to-talk dictation anywhere on your
desktop, without app-specific integrations.

Core intent:

- System-wide hotkey behavior (works across applications)
- Low-friction speech-to-text flow (hold key -> speak -> release -> text appears)
- Local-first transcription via `whisper-cli`
- Keyboard-style text insertion for broad compatibility
- Small, reliable background daemon written in Zig

## Planned architecture (high level)

- **Input trigger**: listen for a global key press/release event.
- **Audio capture**: start recording on key press, stop on key release.
- **Transcription**: invoke `whisper-cli` with a selected model.
- **Text injection**: emit keystrokes (or equivalent input events) into the active window.
- **Daemon lifecycle**: run in background, log events, handle failures gracefully.

## Current status

Current behavior:

- Runs as a Linux daemon-like foreground process.
- Listens globally for the configured trigger key press/release using `/dev/input/event*`.
- Starts WAV recording on trigger key press and stops on trigger key release.
- Runs `whisper-cli` after each recording completes.
- Saves both `<recordings-dir>/recording-<timestamp>.wav` and `<recordings-dir>/recording-<timestamp>.txt` (default `/tmp/whisper-dict-recordings`).
- Types the transcribed text into the currently focused window.
- Shows a minimal black-and-white waveform indicator near the bottom of the screen while recording is active (EWW overlay).
