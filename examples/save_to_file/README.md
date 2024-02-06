# Save To File

Receive video and audio from a browser and save it to files.

While in `examples/save_to_file` directory

1. Run `mix deps.get`
2. Run `mix run --no-halt`
3. Visit `http://127.0.0.1:8829/index.html` in your browser.
4. Press the `Start` button to start recording.
5. Press the `Stop` button to stop recording.

Audio and video have been saved to `audio.ogg` and `video.ivf` files.
You can play them using `ffplay`:

```shell
ffplay audio.ogg
ffplay video.ivf
```
