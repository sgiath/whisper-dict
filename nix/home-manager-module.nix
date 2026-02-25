{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.whisper-dict;
  modelPath = "${cfg.modelsDir}/ggml-${cfg.model}.bin";
  prepareModel = pkgs.writeShellScript "whisper-dict-prepare-model" ''
    set -eu

    mkdir -p ${lib.escapeShellArg cfg.modelsDir}
    if [ ! -f ${lib.escapeShellArg modelPath} ]; then
      ${pkgs.whisper-cpp-vulkan}/bin/whisper-cpp-download-ggml-model ${lib.escapeShellArg cfg.model} ${lib.escapeShellArg cfg.modelsDir}
    fi

    mkdir -p ${lib.escapeShellArg cfg.recordingsDir}
  '';
in
{
  options.services.whisper-dict = {
    enable = lib.mkEnableOption "whisper-dict user background service";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.whisper-dict;
      defaultText = lib.literalExpression "self.packages.${pkgs.stdenv.hostPlatform.system}.whisper-dict";
      description = "Package providing the whisper-dict executable.";
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "base.en";
      example = "large-v3-turbo";
      description = ''
        Whisper model name passed to whisper-cpp-download-ggml-model.
        Models ending in ".en" are English-only.

        Available models:
        https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md#available-models
      '';
    };

    language = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      example = "cs";
      description = ''
        Language passed to whisper-cli via --language.
        Use "auto" for automatic detection, or a single language code like "en" or "cs".
      '';
    };

    modelsDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.cacheHome}/whisper-dict/models";
      example = "$HOME/.cache/whisper-dict/models";
      description = "Directory where Whisper model files are stored.";
    };

    recordingsDir = lib.mkOption {
      type = lib.types.str;
      default = "/tmp/whisper-dict-recordings";
      example = "/tmp/whisper-dict-recordings";
      description = "Directory for recorded audio and transcription text output.";
    };

    triggerKey = lib.mkOption {
      type = lib.types.str;
      default = "rightctrl";
      example = "f8";
      description = ''
        Push-to-talk trigger key passed to whisper-dict via --trigger-key.
        Use a key name (for example "rightctrl", "f8", "capslock") or an evdev key code.
        Named aliases are in https://github.com/sgiath/whisper-dict/blob/master/src/config.zig (trigger_key_descriptors).
        Find numeric codes with `evtest` (look for EV_KEY code values, for example code 97 for KEY_RIGHTCTRL).
        Linux key code constants are documented in https://github.com/torvalds/linux/blob/master/include/uapi/linux/input-event-codes.h.
      '';
    };

    minConfidence = lib.mkOption {
      type = lib.types.float;
      default = 0.0;
      example = 0.4;
      description = ''
        Minimum token confidence required before whisper-dict types a transcription.
        Use 0.0 to disable confidence filtering.
      '';
    };

    minRecordingMs = lib.mkOption {
      type = lib.types.addCheck lib.types.int (v: v >= 0);
      default = 0;
      example = 250;
      description = ''
        Minimum press duration in milliseconds before whisper-dict runs transcription.
        Use 0 to disable short-tap filtering.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.whisper-dict = {
      Unit = {
        Description = "whisper-dict daemon";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };

      Service = {
        Type = "simple";
        ExecStartPre = prepareModel;
        ExecStart = lib.concatStringsSep " " [
          (lib.getExe cfg.package)
          "--model"
          (lib.escapeShellArg modelPath)
          "--recordings-dir"
          (lib.escapeShellArg cfg.recordingsDir)
          "--language"
          (lib.escapeShellArg cfg.language)
          "--trigger-key"
          (lib.escapeShellArg cfg.triggerKey)
          "--min-confidence"
          (lib.escapeShellArg (toString cfg.minConfidence))
          "--min-recording-ms"
          (lib.escapeShellArg (toString cfg.minRecordingMs))
        ];
        Restart = "on-failure";
        RestartSec = "2";
      };

      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
