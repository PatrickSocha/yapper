#!/usr/bin/env bash
#
# Install script for Yapper (Go).
# Clones whisper.cpp, builds it, downloads a model, builds the
# yapper binary, and optionally installs it as a launchd daemon.
#
# Usage:
#   ./install.sh             # build and install
#   ./install.sh uninstall   # remove daemon, binary, and model
#
# Requires: macOS, Go 1.22+, Xcode command line tools, Homebrew (for portaudio)

set -euo pipefail

MODEL="${MODEL:-base.en}"
HOTKEY="${HOTKEY:-rightoption}"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHISPER_DIR="$WORKDIR/whisper.cpp"

BIN_DEST="/usr/local/bin/yapper"
MODEL_DEST="/usr/local/share/yapper/ggml-${MODEL}.bin"
PLIST_DEST="$HOME/Library/LaunchAgents/com.yapper.ptt.plist"

# ── Uninstall ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "uninstall" ]]; then
  any=0

  if [ -f "$PLIST_DEST" ]; then
    echo "==> Unloading launchd agent"
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    rm -f "$PLIST_DEST"
    echo "    Removed $PLIST_DEST"
    any=1
  else
    echo "    launchd plist not found: $PLIST_DEST"
  fi

  if [ -f "$BIN_DEST" ]; then
    echo "==> Removing binary"
    sudo rm -f "$BIN_DEST"
    echo "    Removed $BIN_DEST"
    any=1
  else
    echo "    Binary not found: $BIN_DEST"
  fi

  if [ -f "$MODEL_DEST" ]; then
    echo "==> Removing model"
    sudo rm -f "$MODEL_DEST"
    sudo rmdir "$(dirname "$MODEL_DEST")" 2>/dev/null || true
    echo "    Removed $MODEL_DEST"
    any=1
  else
    echo "    Model not found: $MODEL_DEST"
  fi

  if [ "$any" -eq 0 ]; then
    echo "Nothing to uninstall — Yapper does not appear to be installed."
  else
    echo
    echo "==> Uninstall complete."
  fi
  exit 0
fi

echo "==> Checking dependencies"
command -v go >/dev/null || { echo "Go not found. Install from https://go.dev/dl/"; exit 1; }
command -v git >/dev/null || { echo "git not found."; exit 1; }
command -v brew >/dev/null || { echo "Homebrew not found. Install from https://brew.sh"; exit 1; }

if ! brew list portaudio >/dev/null 2>&1; then
  echo "==> Installing portaudio"
  brew install portaudio
fi

if ! command -v pkg-config >/dev/null 2>&1; then
  echo "==> Installing pkg-config"
  brew install pkgconf
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo "==> Installing cmake"
  brew install cmake
fi

echo "==> Fetching whisper.cpp"
if [ ! -d "$WHISPER_DIR" ]; then
  git clone https://github.com/ggerganov/whisper.cpp "$WHISPER_DIR"
fi

echo "==> Building whisper.cpp (static libs)"
cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" --fresh -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
cmake --build "$WHISPER_DIR/build" --config Release -j"$(sysctl -n hw.logicalcpu)"

echo "==> Downloading model: $MODEL"
MODEL_FILE="$WHISPER_DIR/models/ggml-${MODEL}.bin"
if [ ! -f "$MODEL_FILE" ]; then
  bash "$WHISPER_DIR/models/download-ggml-model.sh" "$MODEL"
fi

echo "==> Building yapper"
cd "$WORKDIR"
go mod tidy

WHISPER_BUILD="$WHISPER_DIR/build"

# Static pkg-config override so portaudio links as .a not .dylib
mkdir -p /tmp/yapper-pkgconfig
cat > /tmp/yapper-pkgconfig/portaudio-2.0.pc << 'PCEOF'
prefix=/opt/homebrew/opt/portaudio
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: PortAudio
Description: Portable audio I/O
Version: 19.7.0
Libs: ${libdir}/libportaudio.a -framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -framework CoreServices
Cflags: -I${includedir}
PCEOF

PKG_CONFIG_PATH="/tmp/yapper-pkgconfig" \
CGO_CFLAGS="-I${WHISPER_DIR}/include -I${WHISPER_DIR}/ggml/include" \
CGO_LDFLAGS="-L${WHISPER_BUILD}/src -L${WHISPER_BUILD}/ggml/src -L${WHISPER_BUILD}/ggml/src/ggml-metal -L${WHISPER_BUILD}/ggml/src/ggml-blas" \
go build -o yapper .

echo "==> Build complete: $WORKDIR/yapper"
echo "    Model: $MODEL_FILE"
echo

read -rp "Install as a background daemon (launchd)? [y/N] " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
  echo "==> Installing binary to $BIN_DEST (requires sudo)"
  sudo cp "$WORKDIR/yapper" "$BIN_DEST"

  echo "==> Installing model to $MODEL_DEST (requires sudo)"
  sudo mkdir -p "$(dirname "$MODEL_DEST")"
  sudo cp "$MODEL_FILE" "$MODEL_DEST"

  PLIST_SRC="$WORKDIR/com.yapper.ptt.plist"

  read -rp "Log transcribed text to /tmp/yapper.log? (not recommended for privacy) [y/N] " log_ans
  LOG_TEXT_FLAG=""
  if [[ "$log_ans" =~ ^[Yy]$ ]]; then
    LOG_TEXT_FLAG="<string>-log-text</string>"
  fi

  echo "==> Writing $PLIST_DEST"
  mkdir -p "$(dirname "$PLIST_DEST")"
  sed \
    -e "s#/usr/local/bin/yapper#${BIN_DEST}#g" \
    -e "s#/usr/local/share/yapper/ggml-base.en.bin#${MODEL_DEST}#g" \
    -e "s#rightoption#${HOTKEY}#g" \
    -e "s#<string>-hotkey=${HOTKEY}</string>#<string>-hotkey=${HOTKEY}</string>${LOG_TEXT_FLAG}#g" \
    "$PLIST_SRC" > "$PLIST_DEST"

  echo "==> Loading launchd agent"
  launchctl unload "$PLIST_DEST" 2>/dev/null || true
  launchctl load "$PLIST_DEST"

  echo
  echo "Installed and running. Logs: /tmp/yapper.log, /tmp/yapper.err"
  echo "To stop: launchctl unload $PLIST_DEST"
else
  echo
  echo "Run manually with:"
  echo "  ./yapper -model=$MODEL_FILE -hotkey=$HOTKEY"
fi

echo
echo "==> First run requires macOS permissions:"
echo "    System Settings -> Privacy & Security -> Microphone (add your terminal/binary)"
echo "    System Settings -> Privacy & Security -> Accessibility (add your terminal/binary)"
