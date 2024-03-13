# WebRTC-HTTP Egress Protocol (WHEP) Send From File Example

Loads a video & audio file from the server and sends them to the browser negotiated via a WHEP handshake. 

This example supports multiple concurrent viewers who will all receive the same content at the same time.

While in `examples/whep_from_file` directory

1. Generate media files

```shell
ffmpeg -f lavfi -i testsrc=duration=15:size=640x480:rate=30 video.ivf
ffmpeg -f lavfi -i sine=frequency=420:duration=15 -c:a libopus audio.ogg
```

You may use your own files, if they meet the requirements:
* for video, it must be IVF in 30 FPS,
* for audio, it must be Ogg with a single Opus stream.

2. Run `mix deps.get`
3. Run `mix run --no-halt`
4. Visit `http://127.0.0.1:8829/index.html` in your browser and press the `play` button.

The video and audio will loop infinitely.
