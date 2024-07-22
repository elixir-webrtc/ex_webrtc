# Negotiating the connection

Before starting to send or receive media, you need to negotiate the WebRTC connection first, which comes down to:

* specifying to your WebRTC peer what you want to send and/or receive (like video or audio tracks)
* exchanging information necessary to establish a connection with the other WebRTC peer
* starting the data transmission.

We'll go through this process step-by-step.

## Web browser

Let's start from the web browse side of things. Let's say we want to send the video from your webcam and audio from your microphone to the Elixir app.

Firstly, we'll create the `RTCPeerConnection` - this object represents a WebRTC connection with a remote peer. Further on, it will be our interface to all
of the WebRTC-related stuff.

```js
const opts = { iceServers: [{ urls: "stun:stun.l.google.com:19302" }] }
const pc = new RTCPeerConnection(opts)
```

> #### ICE servers {: .info}
> Arguably, the most important configuration option of the `RTCPeerConnection` is the `iceServers`.
> It is a list of STUN/TURN servers that the PeerConnection will try to use. You can learn more about
> it in the [MDN docs](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/RTCPeerConnection) but
> it boils down to the fact that lack of any STUN servers might cause you trouble connecting with other peers, so make sure
> something is there.

Next, we will obtain the media tracks from the webcam and microphone using `mediaDevices` JavaScript API.

```js
// a popup asking for permissions should appear after calling this function
const localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: true });
```

The `localStream` is an object of type `MediaStream` - it aggregates video or audio tracks.
Now we can add the tracks to our `RTCPeerConnection`.

```js
for (const track of localStream.getTracks()) {
  pc.addTrack(track, localStream);
}
```

Finally, we have to create and set an offer.

```js
const offer = await pc.createOffer();
// offer == { type: "offer", sdp: "<SDP here>"}
await pc.setLocalDescription(offer);
```

> #### Offers, answers, and SDP {: .info}
> Offers and answers contain information about your local `RTCPeerConnection`, like tracks, codecs, IP addresses, encryption fingerprints, and more.
> All of that is encoded in a text format called SDP. You, as the user, generally can very successfully use WebRTC without ever looking into what's in the SDP,
> but if you wish to learn more, check out the [SDP Anatomy](https://webrtchacks.com/sdp-anatomy/) tutorial from _webrtcHacks_.

Next, we need to pass the offer to the other peer - in our case, the Elixir app. The WebRTC standard does not specify how to do this.
Here, we will just assume that the offer was sent to the Elixir app using some kind of WebSocket relay service that we previously connected to, but generally it
doesn't matter how you get the offer from the other peer.

```js
const json = JSON.stringify(offer);
webSocket.send(json);
```

Let's handle the offer in the Elixir app next.

## Elixir app

Before we do anything else, we need to set up the `PeerConnection`, similar to what we have done in the web browser. The main difference
between Elixir and JavaScript WebRTC API is that, in Elixir, `PeerConnection` is a process. Also, remember to set up the `ice_servers` option!

```elixir
# PeerConnection in Elixir WebRTC is a process!
{:ok, pc} = ExWebRTC.PeerConnection.start_link(ice_servers: [%{urls: "stun:stun.l.google.com:19302"}])
 ```

> #### PeerConnection configuration {: .info}
> There is quite a lot of configuration options for the `ExWebRTC.PeerConnection`.
> You can find all of them in `ExWebRTC.PeerConnection.Configuration`. For instance, all of the JavaScript `RTCPeerConnection` events
> like `track` or `icecandidate` in Elixir WebRTC are simply messages sent by the `ExWebRTC.PeerConnection` process sent to the process that
> called `ExWebRTC.PeerConnection.start_link/2` by default. This can be changed by using the `start_link(controlling_process: pid)` option!

Then we can handle the SDP offer that was sent from the web browser.

```elixir
# we will use the Jason library for decoding the JSON message
receive do
  {:web_socket, {:offer, json}} ->
    offer =
      json
      |> Jason.decode!()
      |> ExWebRTC.SessionDescription.from_json()

    ExWebRTC.PeerConnection.set_remote_description(pc, offer)
end
```

> #### Is WebRTC peer-to-peer? {: .info}
> WebRTC itself is peer-to-peer. It means that the audio and video data is sent directly from one peer to another.
> But to even establish the connection itself, we need to somehow pass the offer and answer between the peers.
>
> In our case, the Elixir app (e.g. a Phoenix web app) probably has a public-facing IP address - we can send the offer directly to it.
> In the case when we want to connect two web browser WebRTC peers, a relay service might be needed to pass the offer and answer -
> after all, both of the peers might be in private networks, like your home WiFi.

Now we create the answer, set it, and send it back to the web browser.

```elixir
{:ok, answer} = ExWebRTC.PeerConnection.create_answer(pc)
:ok = PeerConnection.set_local_description(pc, answer)

answer
|> ExWebRTC.SessionDescription.to_json()
|> Jason.encode!()
|> web_socket_send()
```

> #### PeerConnection can be bidirectional {: .tip}
> Here we have only shown you how to receive data from a browser in the Elixir app, but, of course, you
> can also send data from Elixir's `PeerConnection` to the browser.
>
> Just be aware of this for now, you will learn more about sending data using Elixir WebRTC in the next tutorial.

Now the `PeerConnection` process should send messages to its parent process announcing remote tracks - each of the messages maps to
one of the tracks added on the JavaScript side.

```elixir
receive do
  {:ex_webrtc, ^pc, {:track, %ExWebRTC.MediaStreamTrack{}}} ->
    # we will learn what you can do with the track later
end
```

> #### ICE candidates {: .info}
> ICE candidates are, simplifying a bit, the IP addresses that PeerConnection will try to use to establish a connection with the other peer.
> A PeerConnection will produce a new ICE candidate every now and then, that candidate has to be sent to the other WebRTC peer
> (using any medium, i.e. the same WebSocket relay used for the offer/answer exchange, or some other way).
>
> In JavaScript:
>
> ```js
> pc.onicecandidate = event => webSocket.send(JSON.stringify(event.candidate));
> webSocket.onmessage = candidate => pc.addIceCandidate(JSON.parse(candidate));
> ```
>
> And in Elixir:
>
> ```elixir
> receive do
>   {:ex_webrtc, ^pc, {:ice_candidate, candidate}} ->
>     candidate
>     |> ExWebRTC.ICECandidate.to_json()
>     |> Jason.encode!()
>     |> web_socket_send()
>
>    {:web_socket, {:ice_candidate, json}} ->
>      candidate =
>        json
>        |> Jason.decode!()
>        |> ExWebRTC.ICECandidate.from_json()
>
>      ExWebRTC.PeerConnection.add_ice_candidate(pc, candidate)
> end
> ```

Lastly, we need to set the answer on the JavaScript side.

```js
answer = JSON.parse(receive_answer());
await pc.setRemoteDescription(answer);
```

The process of the offer/answer exchange is called _negotiation_. After negotiation has been completed, the connection between the peers can be established, and media
flow can start.

You can determine that the connection was established by listening for `{:ex_webrtc, _from, {:connection_state_change, :connected}}` message
or by handling the `onconnectionstatechange` event on the JavaScript `RTCPeerConnection`.

> #### Renegotiations {: .info}
> We've just gone through the first negotiation, but you'll need to repeat the same steps after you added/removed tracks
> to your `PeerConnection`. The need for renegotiation is signaled by the `negotiationneeded` event in JavaScript or by the
> `{:ex_webrtc, _from, :negotiation_needed}` message in Elixir WebRTC. You will learn more about how to properly conduct
> a renegotiation with multiple PeerConnectins present in section TODO.

You might be wondering how can you do something with the media data in the Elixir app.
While in JavaScript API you are limited to e.g. attaching tracks to video elements on a web page,
Elixir WebRTC provides you with the actual media data sent by the other peer in the form
of RTP packets for further processing. You will learn how to tackle this in the next part of this tutorial series.
