# Yapper

Push-to-talk local transcription daemon for macOS. Hold a hotkey, speak,
release — transcription is pasted at the cursor. Fully local via
whisper.cpp, nothing leaves the machine.

## Requirements

- macOS, Go 1.22+
- Xcode command line tools (`xcode-select --install`) — needed to build whisper.cpp
- CMake: `brew install cmake`
- PortAudio: `brew install portaudio`
- pkg-config: `brew install pkgconf`

## 1. Build whisper.cpp

whisper.cpp is included as a subdirectory. Build it as static libraries with CMake:

```bash
cmake -S whisper.cpp -B whisper.cpp/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
cmake --build whisper.cpp/build --config Release -j$(sysctl -n hw.logicalcpu)
```

## 2. Download a model

```bash
bash whisper.cpp/models/download-ggml-model.sh base.en
```

This downloads `whisper.cpp/models/ggml-base.en.bin` (~140MB). Larger models
(`small.en`, `medium.en`) are more accurate but slower.

## 3. Build Yapper

From this directory:

The build links whisper and portaudio statically, so the resulting binary has no third-party dylib dependencies.

```bash
go mod tidy

# Override pkg-config so portaudio links as a static archive
mkdir -p /tmp/yapper-pkgconfig
cat > /tmp/yapper-pkgconfig/portaudio-2.0.pc << 'EOF'
prefix=/opt/homebrew/opt/portaudio
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include
Name: PortAudio
Description: Portable audio I/O
Version: 19.7.0
Libs: ${libdir}/libportaudio.a -framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -framework CoreServices
Cflags: -I${includedir}
EOF

PKG_CONFIG_PATH="/tmp/yapper-pkgconfig" \
CGO_CFLAGS="-I$(pwd)/whisper.cpp/include -I$(pwd)/whisper.cpp/ggml/include" \
CGO_LDFLAGS="-L$(pwd)/whisper.cpp/build/src -L$(pwd)/whisper.cpp/build/ggml/src \
  -L$(pwd)/whisper.cpp/build/ggml/src/ggml-metal \
  -L$(pwd)/whisper.cpp/build/ggml/src/ggml-blas" \
go build -o yapper .
```

## 4. Run it

```bash
./yapper -model=whisper.cpp/models/ggml-base.en.bin -hotkey=rightoption
```

First run will trigger macOS permission prompts:

- **Microphone** — to capture audio
- **Accessibility** — to listen for the global hotkey and send Cmd+V

Grant both to whatever binary/terminal is running `yapper`, then quit
and relaunch.

Hold Right Option, speak, release. The transcription is pasted at the
cursor and your previous clipboard contents are restored shortly after.

## 5. Run as a background daemon (optional)

Copy the binary and model somewhere stable:

```bash
sudo cp yapper /usr/local/bin/
sudo mkdir -p /usr/local/share/yapper
sudo cp whisper.cpp/models/ggml-base.en.bin /usr/local/share/yapper/
```

Edit `com.yapper.ptt.plist` if your paths differ, then:

```bash
cp com.yapper.ptt.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.yapper.ptt.plist
```

It will now start on login and restart if it crashes (`KeepAlive`).
Logs go to `/tmp/yapper.log` and `/tmp/yapper.err`.

To stop/unload:

```bash
launchctl unload ~/Library/LaunchAgents/com.yapper.ptt.plist
```

## Configuration

- `-model` — path to a ggml `.bin` model file
- `-hotkey` — `rightoption`, `leftoption`, or `f19`. To add other keys,
  extend the `codes` map in `keyEventCode` in `main.go` with the
  appropriate gohook rawcode for that key.

## Third-party components

| Component | Author | License |
|---|---|---|
| [whisper.cpp](https://github.com/ggerganov/whisper.cpp) | The ggml authors | MIT |
| [whisper.cpp Go bindings](https://github.com/ggerganov/whisper.cpp/tree/master/bindings/go) | David Thorpe | MIT |
| [gordonklaus/portaudio](https://github.com/gordonklaus/portaudio) | Gordon Klaus | MIT |
| [robotn/gohook](https://github.com/robotn/gohook) | go-ego Project Developers | MIT |
| [vcaesar/keycode](https://github.com/vcaesar/keycode) | go-vgo Project Developers | Apache 2.0 |

License texts are included in their respective source directories. A copy of the Apache 2.0 license can be found at `go/pkg/mod/github.com/vcaesar/keycode*/LICENSE` in your Go module cache, or at https://www.apache.org/licenses/LICENSE-2.0.

## Inspiration

[LocalFlow](https://github.com/vmysla/LocalFlow) — a similar push-to-talk transcription tool that inspired this project.

## License

MIT — see [LICENSE](LICENSE).
