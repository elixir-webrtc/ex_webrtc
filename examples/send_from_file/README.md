# Send From File

Send video and audio from files to a browser.

While in `examples/send_from_file` directory

1. Generate media files

```shell
ffmpeg -f lavfi -i testsrc=duration=5:size=640x480:rate=30 -g 60 video.ivf
ffmpeg -f lavfi -i sine=frequency=420:duration=5 -c:a libopus audio.ogg
```

> [!NOTE]
> Option `-g` defines a GOP size i.e. how frequently we will generate a new keyframe.
> Our framerate is 30, so we set the GOP to 60 to have a new keyframe every two seconds.
> This is to make sure, that even if something goes really badly and your keyframe is dropped
> (e.g. there is a bug in a web browser, or something strange happend on your network interface), 
> a browser, in the worst case scenario, will get a new one in two seconds.

You may use your own files, if they meet the requirements:
* for video, it must be IVF in 30 FPS,
* for audio, it must be Ogg with a single Opus stream.

2. Run `mix deps.get`
3. Run `mix run --no-halt`
4. Visit `http://127.0.0.1:8829/index.html` in your browser and press the `play` button.

The IP and port of the app can be configured in `config/config.exs`.

The video and audio will loop infinitely.
