# Deploying on Fly.io

Elixir WebRTC-based apps can be easily deployed on [Fly.io](https://fly.io)!

There are just three things you need to do:

* configure a STUN server both on the client and server side
* use a custom Fly.io IP filter on the server side
* slightly modify auto-generated Dockerfile 

In JavaScript code:

```js
pc = new RTCPeerConnection({
  iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
});
```

In Elixir code:

```elixir
ip_filter = Application.get_env(:your_app, :ice_ip_filter)

{:ok, pc} =
  PeerConnection.start_link(
    ice_ip_filter: ip_filter,
    ice_servers: [%{urls: "stun:stun.l.google.com:19302"}]
  )
```

In `runtime.exs`:

```elixir
if System.get_env("FLY_APP_NAME") do
  config :your_app, ice_ip_filter: &ExWebRTC.ICE.FlyIpFilter.ip_filter/1
end
```

Now:
1. Run `fly launch`. It will generate a Dockerfile that will fail to build.
2. Introduce the following changes 

    ```diff
    - ARG ELIXIR_VERSION=1.16.0
    - ARG OTP_VERSION=26.2.1
    - ARG DEBIAN_VERSION=bullseye-20231009-slim
    + ARG ELIXIR_VERSION=1.17.2
    + ARG OTP_VERSION=27.0.1
    + ARG DEBIAN_VERSION=bookworm-20240701-slim

    - RUN apt-get update -y && apt-get install -y build-essential git \
    -     && apt-get clean && rm -f /var/lib/apt/lists/*_*
    + RUN apt-get update -y && apt-get install -y build-essential git pkg-config libssl-dev \
    +     && apt-get clean && rm -f /var/lib/apt/lists/*_*
    ```

3. Run `fly deploy` to retry.

That's it!
No special UDP port exports or dedicated IP address are needed :)
