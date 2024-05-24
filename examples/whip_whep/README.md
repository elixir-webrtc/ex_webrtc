# WHIP/WHEP

A [WHIP](https://datatracker.ietf.org/doc/html/draft-ietf-wish-whip-13)/[WHEP](https://datatracker.ietf.org/doc/html/draft-ietf-wish-whep-01) broadcasting server.

While in `examples/whip_whep` directory

1. Run `mix deps.get`
2. Run `mix run --no-halt`

We will use [OBS](https://github.com/obsproject/obs-studio) as a media source.
Open OBS, go to `settings > Stream` and change `Service` to `WHIP`.

Pass `http://127.0.0.1:8829/whip` as the `Server` value and `example` as the `Bearer Token` value. Press `Apply`.
Close the settings, choose a source of you liking (e.g. a web-cam feed) and press `Start Streaming`.

Next, acces `http://127.0.0.1:8829/index.html` in your browser. You should see the live stream from you OBS.
You don't have to use the provided player, any WHEP player should work.

The IP, port and the token of the app can be configured in `config/config.exs`.
