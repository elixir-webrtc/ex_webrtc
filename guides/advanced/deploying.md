# Deploying

Deploying WebRTC applications might be cumbersome.
Here are a couple of nitpicks you should keep in mind when trying to push your project into production.

### Allow for UDP traffic in your firewall

In most cases, WebRTC uses UDP to exchange audio and video data.
Therefore, you have to allow UDP traffic in your firewall.
In Linux-based systems that use `ufw`, you can do this with the following command:

```sh
ufw allow 50000:60000/udp
```

Our ICE implementation, by default, uses an ephemeral port range, so it might vary depending on your operating system.
However, you can specify an exact port range that ICE will use when creating a new peer connection, e.g.:

```elixir
PeerConnection.start_link(ice_port_range: 50_000..60_000)
```

### Allow for TCP traffic in your firewall

In some cases, when ICE really cannot find a UDP path, it may fall back to a TCP connection.
However, since our ICE implementation does not support TCP yet, you don't need to take any extra steps here :)

### Export ports in your docker container

If you are running your application using Docker, we recommend using the `--network host` option.
If that's not possible (e.g. you are running on macOS), you have to manually export the ports used by ICE, e.g.:

```
docker run -p 50000-50010/udp myapp
```

Keep in mind that exporting a lot of ports might take a lot of time or even cause the Docker deamon to timeout.
That's why we recommend using host's network.

### Choose your cloud provider wisely

Many cloud providers do not offer good support for UDP traffic.
In such cases, deploying a WebRTC-based application might be impossible.
We recommend using bare machines that you can configure as you need.

### Enable HTTPS in your frontend

The server hosting your frontend site must have HTTPS enabled.
This is a requirement for accessing the user's microphone and camera devices.

### Proxy WebSocket connections

WebSockets are a common option for signalling channel.
If you are using a reverse-proxy like nginx, to make your WebSocket connections work,
you have to preserve the original (client) request headers.
In other words, you need to add the following lines to your endpoint handling websocket connections configuration:

```
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
```

Read more [here](https://nginx.org/en/docs/http/websocket.html).

### Configure STUN servers

If you are deploying your application behind a NAT, you have to configure a STUN 
server that will allow it to discover its public IP address.
In Elixir WebRTC this will be:

```elixir
PeerConnection.start_link(ice_servers: [%{urls: "stun:stun.l.google.com:19302"}])
```

Google's STUN server is publicaly available, but keep in mind that you depend on
someone else's infrastructure.
If it goes down, you can do nothing about it.
Anyway, that's what a lot of people do :) 

### Configure TURN servers

If your application is deployed behind a very restrictive NAT, which should be very rare (e.g. a symmetric NAT),
you will need to configure a TURN server.
In most cases, TURN servers are needed on the client side as you don't have any control 
over a network your clients connect from.
For testing and experimental purposes, you can use our publicly available TURN called [Rel](https://github.com/elixir-webrtc/rel)!
