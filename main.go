// Yapper
//
// Push-to-talk local transcription daemon for macOS.
// Hold the configured hotkey, speak, release — transcription is pasted
// at the cursor via clipboard + Cmd+V. Fully local, whisper.cpp based.
package main

import (
	"flag"
	"log"
	"os/exec"
	"sync"
	"time"

	"github.com/gordonklaus/portaudio"
	hook "github.com/robotn/gohook"
	whisper "github.com/ggerganov/whisper.cpp/bindings/go/pkg/whisper"
)

const (
	sampleRate      = 16000
	frameSize       = 1024
	minDurationSecs = 0.3
)

var (
	modelPath = flag.String("model", "ggml-base.en.bin", "path to ggml whisper model")
	hotkey    = flag.String("hotkey", "rightoption", "hotkey to hold for recording")
	logText   = flag.Bool("log-text", false, "log transcribed text (disabled by default for privacy)")
)

// recorder buffers mic audio while the hotkey is held.
type recorder struct {
	mu        sync.Mutex
	samples   []float32
	active    bool
	startTime time.Time
	stream    *portaudio.Stream
}

func newRecorder() *recorder {
	return &recorder{}
}

func (r *recorder) start() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.active {
		return nil
	}
	r.samples = nil
	r.startTime = time.Now()
	buf := make([]float32, frameSize)
	stream, err := portaudio.OpenDefaultStream(1, 0, float64(sampleRate), len(buf), func(in []float32) {
		r.mu.Lock()
		r.samples = append(r.samples, in...)
		r.mu.Unlock()
	})
	if err != nil {
		return err
	}
	if err := stream.Start(); err != nil {
		stream.Close()
		return err
	}
	r.stream = stream
	r.active = true
	log.Println("recording started")
	return nil
}

// stop ends recording and returns the captured samples, or nil if
// recording was too short to be useful.
func (r *recorder) stop() []float32 {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.active {
		return nil
	}
	r.stream.Stop()
	r.stream.Close()
	r.active = false
	duration := time.Since(r.startTime).Seconds()
	log.Printf("recording stopped (%.2fs, %d samples)", duration, len(r.samples))

	if duration < minDurationSecs || len(r.samples) == 0 {
		log.Println("too short, ignored")
		return nil
	}
	out := make([]float32, len(r.samples))
	copy(out, r.samples)
	return out
}

// transcribeMu serialises calls to transcribe: the underlying C whisper
// context is not safe for concurrent use.
var transcribeMu sync.Mutex

// transcribe runs the buffered audio through whisper.cpp in-process.
func transcribe(model whisper.Model, samples []float32) (string, error) {
	transcribeMu.Lock()
	defer transcribeMu.Unlock()
	ctx, err := model.NewContext()
	if err != nil {
		return "", err
	}
	ctx.SetLanguage("en")
	if err := ctx.Process(samples, nil, nil, nil); err != nil {
		return "", err
	}
	var text string
	for {
		seg, err := ctx.NextSegment()
		if err != nil {
			break
		}
		text += seg.Text
	}
	return text, nil
}

// pasteAtCursor copies text to the clipboard and sends Cmd+V via osascript,
// then restores the previous clipboard contents after a short delay
// (so the paste has time to land before we overwrite the clipboard).
func pasteAtCursor(text string) error {
	prev, _ := exec.Command("pbpaste").Output()

	if err := setClipboard(text); err != nil {
		return err
	}

	// Let the OS register the clipboard update before sending Cmd+V.
	time.Sleep(100 * time.Millisecond)

	script := `tell application "System Events" to keystroke "v" using command down`
	pasteErr := exec.Command("osascript", "-e", script).Run()
	if pasteErr != nil {
		log.Printf("paste failed: %v (text is on clipboard, press Cmd+V manually)", pasteErr)
	}

	// Restore previous clipboard contents asynchronously, after giving
	// the focused app time to consume the pasted value.
	go func() {
		time.Sleep(600 * time.Millisecond)
		if err := setClipboard(string(prev)); err != nil {
			log.Printf("clipboard restore failed: %v", err)
		}
	}()

	return pasteErr
}

func setClipboard(text string) error {
	cmd := exec.Command("pbcopy")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	if _, err := stdin.Write([]byte(text)); err != nil {
		return err
	}
	stdin.Close()
	return cmd.Wait()
}

// keyEventCode maps a hotkey name to the gohook rawcode for that key.
// Extend this map for other keys as needed; rawcodes are macOS-specific.
func keyEventCode(name string) (uint16, error) {
	codes := map[string]uint16{
		"rightoption": 61,
		"leftoption":  58,
		"f19":         80,
	}
	code, ok := codes[name]
	if !ok {
		return 0, errUnknownKey
	}
	return code, nil
}

var errUnknownKey = &unknownKeyError{}

type unknownKeyError struct{}

func (e *unknownKeyError) Error() string { return "unknown hotkey name" }

func main() {
	flag.Parse()

	if err := portaudio.Initialize(); err != nil {
		log.Fatalf("portaudio init: %v", err)
	}
	defer portaudio.Terminate()

	log.Printf("loading whisper model %s...", *modelPath)
	model, err := whisper.New(*modelPath)
	if err != nil {
		log.Fatalf("loading model %s: %v", *modelPath, err)
	}
	defer model.Close()

	keyCode, err := keyEventCode(*hotkey)
	if err != nil {
		log.Fatalf("hotkey: %v", err)
	}

	rec := newRecorder()

	log.Printf("Yapper ready. Hold %s to record; release to transcribe and paste.", *hotkey)

	evChan := hook.Start()
	defer hook.End()

	for ev := range evChan {
		switch ev.Kind {
		case hook.KeyHold:
			if uint16(ev.Rawcode) == keyCode {
				if err := rec.start(); err != nil {
					log.Printf("start recording: %v", err)
				}
			}
		case hook.KeyUp:
			if uint16(ev.Rawcode) == keyCode {
				samples := rec.stop()
				if samples == nil {
					continue
				}
				go func(s []float32) {
					t0 := time.Now()
					text, err := transcribe(model, s)
					if err != nil {
						log.Printf("transcribe error: %v", err)
						return
					}
					if text == "" {
						log.Printf("(no speech detected, %.2fs)", time.Since(t0).Seconds())
						return
					}
					if *logText {
						log.Printf("-> %s [%.2fs]", text, time.Since(t0).Seconds())
					} else {
						log.Printf("transcribed [%.2fs]", time.Since(t0).Seconds())
					}
					if err := pasteAtCursor(text); err != nil {
						log.Printf("paste error: %v", err)
					}
				}(samples)
			}
		}
	}
}
