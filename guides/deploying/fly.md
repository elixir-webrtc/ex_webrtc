# Deploying on Fly.io

Elixir WebRTC-based apps can be easily deployed on [Fly.io](https://fly.io)!

There are just two things you need to do:

* configure a STUN server both on the client and server side
* use a custom Fly.io IP filter on the server side

In theory, configuring a STUN server just on one side should be enough but we recommend doing it on both sides.

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
if System.get_env("FLY_IO") do
  config :your_app, ice_ip_filter: &ExWebRTC.ICE.FlyIpFilter.ip_filter/1
end
```

In fly.toml:

```toml
[env]
  # add one additional env
  FLY_IO = 'true'
```

That's it!
No special UDP port exports or dedicated IP address are needed.
Just run `fly launch` and enjoy your deployment :)
