# Save to File

Receive video from a browser and save it to a file.

1. Start `ex_ice/signalling_server` with `mix run --no-halt`
2. Run `elixir example.exs`
3. Visit `example.html` in your browser e.g. `file:///home/Repos/elixir-webrtc/ex_webrtc/examples/save_to_file/example.html`
4. Press `Start` button to start the connection, then `Stop` button to stop recording.
5. Video and audio have been saved to `video.ivf` and `audio.ogg` files. Play it with

```console
ffplay audio.ogg
```
