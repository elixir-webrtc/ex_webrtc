# Ogg Fixtures

* opus_correct.ogg - 1s sinewave Opus audio generated with:

```console
ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -c:a libopus -b:a 32k opus_correct.ogg
```

* empty.ogg - empty file
