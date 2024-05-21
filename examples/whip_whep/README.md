# Broadcaster

A [WHIP](https://datatracker.ietf.org/doc/html/draft-ietf-wish-whip-13)/[WHEP](https://datatracker.ietf.org/doc/html/draft-ietf-wish-whep-01) broadcasting server with a simble browser front-end.

## Usage

Clone this repo and fetch dependencies.

Fetch dependencies

```shell
mix deps.get
```

Set the evironment variables

```shell
# note: these are actually the default values,
# so you can omit setting the variables
export BCR_IP="127.0.0.1"
export BCR_PORT="5002"
export BCR_TOKEN="test"
export BCR_HOST="http://localhost:$BCR_PORT"
export BCR_ADMIN_USERNAME="admin"
export BCR_ADMIN_PASSWORD="admin"
```

Run the app

```shell
mix run --no-halt
```

We will use [OBS](https://github.com/obsproject/obs-studio) as a media source.
Open OBS an go to `settings > Stream` and change `Service` to `WHIP`.

Pass `$BCR_HOST/api/whip` as the `Server` value and `$BCR_TOKEN` as the `Bearer Token` value, using the environment
variables values that have been set a moment ago. Press `Apply`.

Close the settings, choose a source of you liking (e.g. a web-cam feed) and press `Start Streaming`.

Acces `$BCR_HOST/` in your browser. You should see the live stream from you OBS.





# WHIP/WHEP

A [WHIP](https://datatracker.ietf.org/doc/html/draft-ietf-wish-whip-13)/[WHEP](https://datatracker.ietf.org/doc/html/draft-ietf-wish-whep-01) broadcasting server.

While in `examples/whip_whep` directory

1. Run `mix deps.get`
2. Run `mix run --no-halt`

We will use [OBS](https://github.com/obsproject/obs-studio) as a media source.
Open OBS, go to `settings > Stream` and change `Service` to `WHIP`.

Pass `http://127.0.0.1:8829/whip` as the `Server` value and `test` as the `Bearer Token` value. Press `Apply`.
Close the settings, choose a source of you liking (e.g. a web-cam feed) and press `Start Streaming`.

Next, to see the stream, go to TODO.

The IP and port of the app can be configured in `config/config.exs`.
