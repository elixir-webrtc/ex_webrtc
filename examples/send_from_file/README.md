# Send from File

Send video and audio from files to a browser.

While in `examples/send_from_file` directory

1. Generate media files

```shell
ffmpeg -f lavfi -i testsrc=duration=5:size=640x480:rate=30 video.ivf
ffmpeg -f lavfi -i sine=frequency=420:duration=5 -c:a libopus audio.ogg
```

You may use your own files, if they meet the requirements:
* for video, it must be IVF in 30 FPS,
* for audio, it must be Ogg with a single Opus stream.

2. Run `mix deps.get`
3. Run `mix run --no-halt`
4. Visit `http://127.0.0.1:8829` in your browser and press the `play` button.

The video and audio will loop infinitely.
