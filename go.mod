module yapper

go 1.23

require (
	github.com/ggerganov/whisper.cpp/bindings/go v0.0.0
	github.com/gordonklaus/portaudio v0.0.0-20230709114228-aafa478834f5
	github.com/robotn/gohook v0.41.0
)

require github.com/vcaesar/keycode v0.10.1 // indirect

replace github.com/ggerganov/whisper.cpp/bindings/go => ./whisper.cpp/bindings/go
