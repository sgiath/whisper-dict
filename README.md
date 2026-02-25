# whisper-dict

`whisper-dict` is a Zig-based system-wide dictation daemon.

The goal is to let you **hold a configured key**, speak, and on release:

1. record audio from your microphone,
2. run `whisper-cli` to transcribe speech to text,
3. inject the transcription into the currently focused app as if typed on a keyboard.

![whisper-dict recording indicator](./docs/screenshot.png)

## Usage

Run with default model:

`whisper-dict`

Run with a custom model:

`whisper-dict --model models/ggml-base.en.bin`

Run with a custom output directory:

`whisper-dict --recordings-dir recordings`

Run with automatic language detection:

`whisper-dict --language auto`

Run with a fixed language (example: Czech):

`whisper-dict --language cs`

Run with a custom push-to-talk key (example: F8):

`whisper-dict --trigger-key f8`

Skip low-confidence transcriptions (example threshold: `0.40`):

`whisper-dict --min-confidence 0.40`

Skip very short accidental taps (example: at least `250ms`):

`whisper-dict --min-recording-ms 250`

Note: models ending in `.en` are English-only. For Czech or other languages,
use a multilingual model (for example `large-v3-turbo`, `medium`, `small`, `base`).

Trigger key accepts key names (for example `rightctrl`, `leftalt`, `f8`, `capslock`) or a numeric evdev key code.
Available named key aliases are defined in [`trigger_key_descriptors` in `src/config.zig`](./src/config.zig).

To find a numeric evdev key code on Linux, run `sudo evtest`, select your keyboard,
press the desired key, and use the reported `code` value from `EV_KEY` (for example
`code 97 (KEY_RIGHTCTRL)` means `--trigger-key 97`).
Reference key definitions are in Linux [`input-event-codes.h`](https://github.com/torvalds/linux/blob/master/include/uapi/linux/input-event-codes.h).

Default model path is `~/.cache/whisper-dict/models/ggml-large-v3-turbo.bin`.
Default recordings directory is `/tmp/whisper-dict-recordings`.
Default language is `auto`.
Default trigger key is `rightctrl`.
Default minimum confidence is `0.00` (disabled).
Default minimum recording length is `0ms` (disabled).

Download models with `whisper-cpp-download-ggml-model`.
The full list of available model names is documented in whisper.cpp:
https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md#available-models

Example (download `large-v3-turbo` into the default model directory):

`whisper-cpp-download-ggml-model large-v3-turbo ~/.cache/whisper-dict/models`

## Required external commands (non-NixOS)

On NixOS these commands are wired in automatically. On other systems, install
them manually and make sure they are available in `PATH`.

- `whisper-cli` (required): from [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
- `whisper-cpp-download-ggml-model` (for model download command in this README): from [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
- Recording backend (install at least one):
  - `arecord` from [alsa-utils](https://github.com/alsa-project/alsa-utils)
  - `ffmpeg` from [FFmpeg](https://ffmpeg.org/)
- Text injection backend (install at least one):
  - `wtype` for Wayland from [wtype](https://github.com/atx/wtype)
  - `xdotool` for X11 from [xdotool](https://github.com/jordansissel/xdotool)
- `eww` (optional, only for the recording overlay): from [elkowar/eww](https://github.com/elkowar/eww)

## Linux permissions

For `whisper-dict` to run as a regular user (without root), the user running
the daemon needs:

- Read access to `/dev/input/event*` (required for global trigger key capture).
- Write access to the recordings directory (default: `/tmp/whisper-dict-recordings`, or the path
  set by `--recordings-dir`).
- Microphone access through your audio stack (used by `arecord` or `ffmpeg`).

Most distros gate `/dev/input/event*` behind the `input` group. A common setup
is:

`sudo usermod -aG input $USER`

Then log out and log back in so new group membership takes effect.

## Home Manager module

The flake exports a Home Manager module at `homeManagerModules.whisper-dict`
(also aliased as `homeManagerModules.default`).

Example:

```nix
{
  imports = [ inputs.whisper-dict.homeManagerModules.whisper-dict ];

  services.whisper-dict = {
    enable = true;
    model = "large-v3-turbo";
    language = "auto";
    triggerKey = "f8";
    minConfidence = 0.4;
    minRecordingMs = 250;
    modelsDir = "${config.xdg.cacheHome}/whisper-dict/models";
    recordingsDir = "/tmp/whisper-dict-recordings";
  };
}
```

When enabled, it creates `systemd --user` service `whisper-dict` that:

- runs `whisper-dict` in the background,
- downloads the configured model with `whisper-cpp-download-ggml-model`
  before start (if missing),
- stores models in `services.whisper-dict.modelsDir`,
- sets transcription language with `services.whisper-dict.language`
  (default `"auto"`),
- sets push-to-talk key with `services.whisper-dict.triggerKey`
  (default `"rightctrl"`),
- filters low-confidence transcriptions with `services.whisper-dict.minConfidence`
  (default `0.0`, disabled),
- skips short taps with `services.whisper-dict.minRecordingMs`
  (default `0`, disabled),
- stores audio/transcription outputs in
  `services.whisper-dict.recordingsDir` (default: `/tmp/whisper-dict-recordings`).
