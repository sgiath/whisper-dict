{
  pkgs ? import <nixpkgs> { },
}:
let
  version =
    let
      zon = builtins.readFile ./build.zig.zon;
      versionLines = builtins.filter (
        line: builtins.match ''[[:space:]]*[.]version[[:space:]]*=[[:space:]]*"[^"]+".*'' line != null
      ) (pkgs.lib.splitString "\n" zon);
      matches =
        if versionLines == [ ] then
          null
        else
          builtins.match ''[[:space:]]*[.]version[[:space:]]*=[[:space:]]*"([^"]+)".*'' (
            builtins.head versionLines
          );
    in
    if matches == null then
      throw "Could not read .version from build.zig.zon"
    else
      builtins.elemAt matches 0;

  runtimeDeps = with pkgs; [
    whisper-cpp-vulkan
    alsa-utils
    ffmpeg
    wtype
    xdotool
    eww
  ];
in
pkgs.stdenv.mkDerivation {
  pname = "whisper-dict";
  inherit version;
  src = builtins.path {
    path = ./.;
    name = "whisper-dict-src";
  };

  nativeBuildInputs = with pkgs; [
    zig
    makeWrapper
  ];

  buildPhase = ''
    runHook preBuild
    zig build -Doptimize=ReleaseSafe --prefix "$out"
    runHook postBuild
  '';

  doCheck = true;

  checkPhase = ''
    runHook preCheck
    zig build test -Doptimize=ReleaseSafe
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/whisper-dict"
    cp -r eww "$out/share/whisper-dict/"
    runHook postInstall
  '';

  postFixup = ''
    wrapProgram "$out/bin/whisper-dict" \
      --prefix PATH : "${pkgs.lib.makeBinPath runtimeDeps}"
  '';

  passthru = {
    inherit runtimeDeps;
  };

  meta = with pkgs.lib; {
    description = "System-wide push-to-talk dictation daemon powered by whisper.cpp";
    mainProgram = "whisper-dict";
    platforms = platforms.linux;
    license = licenses.wtfpl;
  };
}
