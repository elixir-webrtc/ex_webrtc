# Introduction to Elixir WebRTC

In this tutorial, we'll go through some simple use cases of Elixir WebRTC. Its purpose is to teach where you'd want to use WebRTC,
how WebRTC API looks like and how it should be used, focusing on some common caveats.

> #### Before You Start {: .info}
> This guide assumes little prior knowledge of the WebRTC API, but it would be highly beneficial
> to go through the [MDN WebRTC tutorial](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API)
> as the Elixir API tries to closely mimic the browser JavaScript API.

## What is WebRTC and where it can be used

WebRTC is an open, real-time communication standard that allows you to send video, audio, and generic data between peers over the network.
WebRTC is implemented by all of the major web browsers and available JavaScript API, there's also native WebRTC clients for Android and iOS
and implementation in other programming languages ([Pion](https://github.com/pion/webrtc), [webrtc.rs](https://github.com/webrtc-rs/webrtc),
and now [Elixir WebRTC](https://github.com/elixir-webrtc/ex_webrtc)).

WebRTC is the obvious choice in applications where low latency is important. It's also probably the easiest way to obtain the voice and video from a user of
your web application. Here are some example use cases:
* videoconferencing apps (one-on-one meetings of fully fledged meeting rooms, like Microsoft Teams or Google Meet)
* ingress for broadcasting services (as a presenter, you can use WebRTC to get media to a server, which will then broadcast it to viewers using WebRTC or different protocols)
* obtaining voice and video from web app users to use it for machine learning model inference on the back end.

In general, all of the use cases come down to getting media from one peer to another. In the case of Elixir WebRTC, one of the peers is usually a server,
like your Phoenix backend (although it does not have to - there's no concept of server/client in WebRTC, so you might as well connect two browsers or two Elixir peers).

This is what the first part of this tutorial will focus on - we will try to get media from a web browser to a simple Elixir app.

## Getting media from a web browser to the Elixir app

Let's start from the web browse side of things. Firstly, we need to obtain the webcam and microphone feeds from the browser.

```js
// a popup asking for permissions should appear after calling this function
const localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: true });
```

We used the `mediaDevices` API to get a `MediaStream` with our video and audio tracks. Now, we can start with the WebRTC itself.

```js
const opts = { iceServers: [{ urls: "stun:stun.l.google.com:19302" }] }
const pc = new RTCPeerConnection(opts)
```

We've created a new `RTCPeerConnection`. PeerConnection, as the name implies, represents a connection between two WebRTC peers. Further on, this object will
be our interface to all of the WebRTC-related stuff.

> #### ICE servers {: .info}
> Arguably, the most important configuration option of the `RTCPeerConnection` is the `iceServers`.
> It is a list of STUN/TURN servers that the PeerConnection will try to use. You can learn more about
> it in the [MDN docs](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/RTCPeerConnection) but
> it boils down to the fact that without any STUN servers, you might have trouble connecting with other peers
> if you're behind a NAT (which is most likely the case).

Now we can add the audio and video track from the `localStream` to our `RTCPeerConnection`.

```js
for (const track of localStream.getTracks()) {
  pc.addTrack(track, localStream);
}
```

Finally, we have to create and set an offer - an [SDP description](https://webrtchacks.com/sdp-anatomy/) containing information about added tracks, codecs, used IP addresses and ports,
encryption fingerprints, and other stuff. You, as the user, generally don't have to care about what's in the offer SDP.

```js
const offer = await pc.createOffer();
// offer == { type: "offer", sdp: "<SDP here>"}
await pc.setLocalDescription(offer);
```

Next, we need to pass the offer to the other peer - in our case, the Elixir app. The WebRTC standard does not specify how to do this, but generally, some kind of
WebSocket relay server can be used. Here, we will just assume that the offer was magically sent to the Elixir app.

```js
const json = JSON.stringify(offer);
send_offer_to_other_peer(json);
```

> #### Is WebRTC peer-to-peer? {: .info}
> WebRTC itself is peer-to-peer. It means that the audio and video data is sent directly from one peer to another.
> But to even establish the connection itself, we need to somehow pass the SDP offer and answer between the peers.
> In our case, the Elixir app (e.g. a Phoenix web app) probably has a public-facing IP address - we can send the offer directly to it.
> In the case when we want to connect two web browser WebRTC peers, a relay service might be needed to pass the SDP offer and answer -
> after all both of the peers might be in private networks, like your home WiFi.

And then we receive the SDP offer in Elixir.

```elixir
# we will use the Jason library for decoding the JSON message
offer = receive_offer() |> Jason.decode!() |> ExWebRTC.SessionDescription.from_json()
```

Now's the moment when we need to start playing with the Elixir API, but do not worry, it's very similar to the JavaScript one.

```elixir
alias ExWebRTC.PeerConnection

# PeerConnection in Elixir WebRTC is a process!
{:ok, pc} = PeerConnection.start_link(ice_servers: [%{urls: "stun:stun.l.google.com19302"}])
:ok = PeerConnection.set_remote_description(pc, offer)

{:ok, answer} = PeerConnection.create_answer(pc)
:ok = PeerConnection.set_local_description(pc, answer)

answer
|> ExWebRTC.SessionDescription.to_json()
|> Jason.encode!()
|> send_answer_to_other_peer()
```

We created a PeerConnection, set the offer, created an answer, applied it, and sent it back to the web browser. Now the `PeerConnection` process should send
messages to its parent process announcing remote tracks - each of the messages maps to one of the tracks added on the JavaScript side.

```elixir
receive do
  {:ex_webrtc, ^pc, {:track, %ExWebRTC.MediaStreamTrack{}}} ->
    # do something with the track
end
```

> #### ICE candidates {: .info}
> ICE candidates are, simplifying a bit, the IP addresses that PeerConnection will try to use to establish a connection with the other peer.
> Candidates can be included in the offer/answer, or (if Trickle ICE is enabled, and by default it is) can be gathered asynchronously and exchanged
> after the offer/answer negotiation already happened (using any medium, i.e. the same WebSocket server used for the offer/answer, or some other way).
>
> In JavaScript:
>
> ```js
> pc.onicecandidate = event => send_cand_to_other_peer(JSON.stringify(event.candidate));
> // for every candidate received from the other peer
> on_cand_from_other_peer(candidate => pc.addIceCandidate(JSON.parse(candidate)));
> ```
>
> And in Elixir:
>
> ```elixir
> # let's assume this is a GenServer
> alias ExWebRTC.{PeerConnection, ICECandidate}
>
> def handle_info({:ex_webrtc, _from, {:ice_candidate, cand}}, state) do
>   cand |> ICECandidate.to_json() |> Jason.encode!() |> send_cand_to_other_peer()
>   {:noreply, state}
> end
>
> def handle_info({:cand_from_other_peer, cand}, state) do
>   ic = cand |> Jason.decode!() |> ICECandidate.from_json()
>   :ok = PeerConnection.add_ice_candidate(state.pc, ic)
>   {:noreply, state}
> end
> ```

Lastly, we need to set the answer on the JavaScript side.

```js
answer = JSON.parse(receive_answer());
await pc.setRemoteDescription(answer);
```

The process of the offer/answer exchange is called _negotiation_. After negotiation has been completed, the connection between the peers can be established and media
flow can start.

> #### PeerConnection can be bidirectional {: .tip}
> In our simple example, we only send media from the web browser to the Elixir app. We can use the same PeerConnection to send media from the Elixir app back to the browser.
> We could achieve this by adding the tracks **before** we created the answer.
>
> ```elixir
> alias ExWebRTC.MediaStreamTrack
>
> # add tracks to the same MediaStream to ensure synchronization between them
> stream_id = MediaStreamTrack.generate_stream_id()
> PeerConnection.add_track(pc, MediaStreamTrack.new(:video, [stream_id]))
> PeerConnection.add_track(pc, MediaStreamTrack.new(:audio, [stream_id]))
> ```
>
> As you can see, the track does not have to be obtained from some kind of source, like the `userMedia` API in JavaScript. This is because
> we allow for the sending of arbitrary media data on each of the tracks.
> You will see how to send media from the Elixir PeerConnection further in this tutorial.
>
> After you apply the answer on the JavaScript side, the `RTCPeerConnection` should fire the `ontrack` handler for both of these tracks.
>
> ```js
> // you can attach the remote stream (which contains both of the tracks) to an HTML video element
> pc.ontrack = event => videoElement.srcObject = event.streams[0];
> ```

You can determine that the connection was established by listening for `{:ex_webrtc, _from, {:connection_state_change, :connected}}` message
or by handling the `onconnectionstatechange` event on the JavaScript `RTCPeerConnection`.

You might be wondering how can you actually do something with the media data in the Elixir app.
While in JavaScript API you are limited to e.g. attaching tracks to video elements on a web page,
Elixir WebRTC provides you with the actual media data sent by the other peer in the form
of RTP packets for further processing.

```elixir
def handle_info({:ex_webrtc, _from, {:rtp, track_id, _rid, packet}}) do
  # do something with the packet
  # also, for now you can assume that _rid is always nil and ignore it
  {:noreply, state}
end
```

The `track_id` corresponds to one of the tracks that we received in `{:ex_webrtc, _from, {:track, ...}}` messages.

> #### RTP and RTCP {: .info}
> RTP is a network protocol created for carrying real-time data (like media) and is used
> by WebRTC. It provides some useful features like:
> * sequence numbers: UDP (which is usually used by WebRTC) does not provide ordering, thus we need this to catch missing or out-of-order packets
> * timestamp: these can be used to correctly play the media back to the user (e.g. using the right framerate for the video)
> * payload type: thanks to this combined with information in the SDP offer/answer, we can tell which codec is carried by this packet
>
> and many more. Check out the [RFC 3550](https://datatracker.ietf.org/doc/html/rfc3550) to learn more about RTP.
>
> RTCP, on the other hand, carries metadata about the RTP streams. Unless you're familiar with it, you don't have to care about
> RTCP in Elixir WebRTC, as the PeerConnection handles all of the things necessary for correct operation.
> Both types of packets are sent to the user as messages: `{:ex_webrtc, _from, msg}`, where `msg` is either `{:rtp, track_id, rid, packet}`
> or `{:rtcp, packets}`.

Next, we will learn what you can do with the RTP packets.

## Forwarding the packets

### To the same peer

Let's start by simply forwarding the RTP packets back to the same web browser.

```mermaid
flowchart LR
  subgraph Elixir
    PC[PeerConnection] --> Forwarder --> PC
  end

  WB((Web Browser)) <-.-> PC
```

The only thing we have to implement is the `Forwarder` GenServer process. Let's combine the ideas from the previous section
to write it.

```elixir
defmodule Forwarder do
  use GenServer

  alias ExWebRTC.{PeerConnection, ICEAgent, MediaStreamTrack, SessionDescription}

  @ice_servers [%{urls: "stun:stun.l.google.com:19302"}]

  @impl true
  def init(_) do
    {:ok, pc} = PeerConnection.start_link(ice_servers: @ice_servers)

    stream_id = MediaStreamTrack.generate_stream_id()
    audio_track = MediaStreamTrack.new(:audio, [stream_id])
    video_track = MediaStreamTrack.new(:video, [stream_id])

    {:ok, _sender} = PeerConnection.add_track(pc, audio_track)
    {:ok, _sender} = PeerConnection.add_track(pc, video_track)

    # in_tracks = %{id => kind}
    # out_tracks = %{kind => id}
    out_tracks = %{audio: audio_track.id, video: video_track.id}
    {:ok, %{pc: pc, out_tracks: out_tracks, in_tracks: %{}}}
  end

  # ...
end
```

We started by creating the PeerConnection and adding two tracks (one for audio and one for video).
Remember that these tracks will be used to *send* data to the peer. Tracks that will receive the data
will arrive as messages after the negotiation.

> #### Where are the tracks? {: .tip}
> In the context of Elixir WebRTC, a track is simply a _track id_, _ids_ of streams this track belongs to, and a _type_ (audio/video).
> We can either add tracks to the PeerConnection (these tracks will be used to *send* data when calling `PeerConnection.send_rtp/4` and
> for each one of the tracks, the remote peer should fire the `ontrack` handler)
> or handle remote tracks (which you are notified about with messages from the PeerConnection process: `{:ex_webrtc, _from, {:track, track}}`).
> These are used when handling messages with RTP packets: `{:ex_webrtc, _from, {:rtp, _rid, track_id, packet}}`.
>
> Alternatively, all of the tracks can be obtained by iterating over the transceivers:
>
> ```elixir
> tracks =
>   peer_connection
>   |> PeerConnection.get_transceivers()
>   |> Enum.map(&(&1.receiver.track))
> ```
>
> If you want to know more about transceivers, read the [Mastering Transceivers](https://hexdocs.pm/ex_webrtc/mastering_transceivers.html) guide.

Next, we need to take care of the offer/answer and ICE candidate exchange.

```elixir
# sending/receiving the offer/answer/candidates to/from the other peer is your responsibility

@impl true
def handle_info({:offer, offer}, state) do
  :ok = PeerConnection.set_remote_description(state.pc, offer)
  {:ok, answer} = PeerConnection.create_answer(state.pc)
  :ok = PeerConnection.set_local_description(state.pc, answer)
  send_to_other_peer(answer)
  {:noreply, state}
end

@impl true
def handle_info({:cand, cand}, state) do
  :ok = PeerConnection.add_ice_candidate(state.pc, cand)
  {:noreply, state}
end

@impl true
def handle_info({:ex_webrtc, _from, {:ice_candidate, cand}}, state) do
  send_to_other_peer(cand)
  {:noreply, state}
end
```

Now we can handle the remote tracks and match them with the tracks that we are going to send.
We need to be careful not to send packets from the audio track on a video track by mistake!

```elixir
@impl true
def handle_info({:ex_webrtc, _from, {:track, track}}, state) do
  state = put_in(state.in_tracks[track.id], track.kind)
  {:noreply, state}
end
```

We are ready to handle the incoming RTP packets!

```elixir
@impl true
def handle_info({:ex_webrtc, _from, {:rtp, track_id, nil, packet}}, state) do
  kind = Map.fetch!(state.in_tracks, track_id)
  id = Map.fetch!(state.out_tracks, kind)
  :ok = PeerConnection.send_rtp(state.pc, id, packet)

  {:noreply, state}
end
```

> #### RTP packet rewriting {: .info}
> In the example above we just receive the RTP packet and immediately send it back. In reality, a lot of stuff in the packet header must be rewritten.
> That includes SSRC (a number that identifies to which stream the packet belongs), payload type (indicates the codec, even though the codec does not
> change between two tracks, the payload types are dynamically assigned and may differ between RTP sessions), and some RTP header extensions. All of that is
> done by Elixir WebRTC behind the scenes, but be aware - it is not as simple as forwarding the exact same piece of data!

Lastly, let's take care of the client-side code.

```js
const localStream = await navigator.mediaDevices.getUserMedia({audio: true, video: true});
const pc = new RTCPeerConnection({iceServers: [{urls: "stun:stun.l.google.com:19302"}]});
localStream.getTracks().forEach(track => pc.addTrack(track, localStream));

// these will be the tracks that we added using `PeerConnection.add_track`
pc.ontrack = event => videoPlayer.srcObject = event.stream[0];

// sending/receiving the offer/answer/candidates to the other peer is your responsiblity
pc.onicecandidate = event => send_to_other_peer(event.candidate);
on_cand_received(cand => pc.addIceCandidate(cand));

// remember that we set up the Elixir app to just handle the incoming offer
// so we need to generate and send it (an thus, start the negotiation) here
const offer = await pc.createOffer();
await pc.setLocalDescription(offer)
send_offer_to_other_peer(offer);

const answer = await receive_answer_from_other_peer();
await pc.setRemoteDescription(answer);
```

And that's it! The other peer should be able to see and hear the echoed video and audio.

> #### PeerConnection state {: .info}
> Before we can send anything on a PeerConnection, its state must change to `connected` which is signaled
> by the `{:ex_webrtc, _from, {:connection_state_change, :connected}}` message. In this particular example, we want
> to send packets on the very same PeerConnection that we received the packets from, thus it must be connected
> from the first RTP packet received.

What you've seen here is a simplified version of the [echo](https://github.com/elixir-webrtc/ex_webrtc/tree/master/examples/echo) example available in the Github repo.
Check it out and play with it!

### To other peers

Well, forwarding the packets back to the same peer is not very useful in the real world, but you can use the gained knowledge to build more complex apps.

```mermaid
flowchart LR
  subgraph Elixir
    PC1[PeerConnection 1] <--> Forwarder <--> PC2[PeerConnection 2]
  end

  WB1((Web Browser 1)) <-.-> PC1
  WB2((Web Browser 2)) <-.-> PC2
```

In the scenario on the diagram, we just forward packets from one peer to the other one (or even a bunch of other peers).

> #### Why do the _forwarding_ at all? {: .info}
> You might think that this is also not very useful,
> WebRTC is peer-to-peer after all, so we can connect the `Web Browser1` and `Web Browser2` directly! But imagine that you can extend `Forwarder`
> to do other things, like save the recording of a conversation, make a transcription of the conversation using an ML model, or (in general) have more
> control over the stream. Also, assuming we would like to create a videoconferencing room with more than two peers, the upload in the peer-to-peer approach
> is becoming the limiting factor. When using some central forwarding unit, each of the peers uploads only to the unit, not all of the other peers.

This a bit more challanging for a bunch of reasons:

#### 1. Negotiation gets more complex

You need to decide who starts the negotiation for every PeerConnection created - it can be either the client/web browser (so the case we went through
in the previous section), the server, or both depending on when the peer joined. Also, don't forget that after you add or remove tracks from a PeerConnection,
new negotiation has to take place and is signaled by a `{:ex_webrtc, _from, :negotiation_needed}` message from the PeerConnection process!

> #### The caveats of negotiation {: .tip}
> But wait, the peer who added new tracks doesn't have to start the negotiation?
>
> Certainly, that's the simplest way, but as long as the *number of transceivers* of the offerer (or, to be specific, the number of m-lines in the offer SDP with the appropariate
> `direction` attribute set) is greater or equal to the number of all tracks added by the answerer, the tracks will be considered in the negotiation.
>
> But what does that even mean?
> Each transceiver is responsible for sending and/or receiving a single track. When you call `PeerConnection.add_track`, we actually look for a free transceiver
> (that is, one that is not sending a track already) and use it, or create a new transceiver if we don't not find anything suitable. If you are very sure
> that the remote peer added _N_ new video tracks, you can add _N_ video transceivers (using `PeerConnection.add_transceiver`) and begin the negotiation as
> the offerer. If you didn't add the transceivers, the tracks added by the remote peer (the answerer) would be ignored.

Let's look at an example:
1. The first peer (Peer 1) joins - here it probably makes more sense for the client (so the Web Browser) to start the negotiation, as the server (Elixir App/
`Forwarder` in the diagram) does not know how many tracks the client wants to add (the `2. offer/answer` message indicates exchange of offer where the direction of
the arrow means the direction of the offer message).

```mermaid
flowchart LR
  subgraph P1["Peer 1 (Web Browser)"]
    User-- "1. addTrack(track11)" -->PCW1[PeerConnection]
  end

  subgraph elixir [Elixir App]
    PCE1[PeerConnection 1]-- "3. {:track, track11}" -->Forwarder
  end

  PCW1-. "2. offer/answer" .->PCE1
```

2. The second peer (Peer 2) joins - now we need to make a decision: we want Peer 2 to receive track from Peer 1, but Peer 2 also wants to send some tracks.
We can either:
    - perform two negotiations: the first one, where Peer 2 is the offerer and adds their tracks, and the second one where the server is the offerer and adds
    Peer 1's tracks to Peer 2's PeerConnection.

    ```mermaid
    flowchart LR
      subgraph elixir [Elixir App]
        PCE1[PeerConnection 1]
        Forwarder-- "4. add_track(track12)" -->PCE2[PeerConnection 2]
        PCE2-- "3. {:track, track22}" -->Forwarder
      end

      subgraph P2["Peer 2 (Web Browser)"]
        U2[User]-- "1. addTrack(track22)" -->PCW2[PeerConnection]
        PCW2-- "6. ontrack(track12)" --> U2
      end

      PCW2-. "2. offer/answer" .->PCE2
      PCE2-. "5. offer/answer" .->PCW2
    ```

    - assuming that we expect only _N_ tracks from Peer 2, we can use the tip above and
    make sure that there are at least _N_ transceivers in Peer 2's PeerConnection on the Elixir side and do just a single negotiation.
    Note that you can also add transceivers without associated track, that's what you would need to do if
    _N_ in the diagram was greater than 1, because we only have a single track available.

    ```mermaid
    flowchart BR
      subgraph elixir [Elixir App]
        PCE1[PeerConnection 1]
        Forwarder-- "2. add_transceiver(track12)" -->PCE2[PeerConnection 2]
        PCE2-- "4. {:track, track22}" -->Forwarder
      end

      subgraph P2["Peer 2 (Web Browser)"]
        U2[User]-- "1. addTrack(track22)" -->PCW2[PeerConnection]
        PCW2-- "5. ontrack(track12)" --> U2
      end

      PCE2-. "3. offer/answer" .->PCW2
   ```

3. Lastly, Peer 1 also wants to receive Peer 2's tracks, so we need to add the new tracks to Peer 1's PeerConnection and perform the renegotiation there.

```mermaid
flowchart LR
  subgraph P1["Peer 1 (Web Browser)"]
    PCW1[PeerConnection]-- "3. ontrack(track12)" --> U1
  end

  subgraph elixir [Elixir App]
    Forwarder-- "1. add_track(21)" -->PCE1[PeerConnection 1]
    PCE2[PeerConnection 2]
  end

  PCE1-. "2. offer/answer" .->PCW1
```

> #### Who owns the tracks? {: .warning}
> Each of the tracks exists only in the context of its own PeerConnection. That means even if your Elixir App forwards media from one peer to
> another, it only takes RTP packets from a track in the first peer's PeerConnection and feeds them to another track in the second peer's PeerConnection.
> For instance, the role of `Forwarder` in the examples above would be to forward media in such way:
>
> ```mermaid
> flowchart LR
>   subgraph Forwarder
>     track11 -.-> track12
>     track22 -.-> track21
>   end
>   PC1[PeerConnection 1] --> track11
>   PC2[PeerConnection 2] --> track22
>   track12 --> PC2
>   track21 --> PC1
> ```
>
> This might be a bit counterintuitive, as in reality both of the tracks `track11` and `track12` still carry the same media stream.

A similar process would happen for all of the joining/leaving peers. If you want to check an actual working example, check out the
[Nexus](https://github.com/elixir-webrtc/apps/tree/master/nexus) - our Elixir, WebRTC-based videoconferencing demo app.
 
#### 2. Codecs

When connecting two peers, you also have to make sure that all of them use the same video and audio codec, as the codec negotiation happens
completely separately between independent PeerConnections.

You can tell what codec is carried in an RTP packet by inspecting its payload type (`packet.payload_type`, a non-negative integer field) and match it with one
of the codecs listed in this track's transceiver's `codecs` field (you have to find the `transceiver` by iterating over `PeerConnection.get_transceivers` as shown
previously in this tutorial).

In a real scenario, you'd have to receive the RTP packet from the PeerConnection, inspect its payload type, find the codec associated with that payload type, find the payload type
associated with that codec on the other PeerConnection, and use it to overwrite the original payload type in the packet.

Unfortunately, at the moment the `PeerConnection.send_rtp` API forces you to use the topmost negotiated codec, so there's no way to handle RTP streams with changing codecs.
The only real solution is to force `PeerConnection` to negotiate only one codec.

```elixir
codec = %ExWebRTC.RTPCodecParameters{
    payload_type: 96,
    mime_type: "video/VP8",
    clock_rate: 90_000
}
{:ok, pc} = PeerConnection.start_link(video_codecs: [codec])
```

This is not ideal as the remote PeerConnection might not support this particular codec. This tutorial will be appropriately updated once the `PeerConnection` API allows
for more in this regard.

#### 3. Types of video frames

When speaking about video codecs, we should also mention the idea of different types of frames.

We are interested in these types (although there can be more, depending on the codec):
* I-frames (/intra-frames/keyframes) - these are complete, independent images and do not require other frames to be decoded
* P-frames (predicted frames/delta-frames) - these only hold changes in the image from the previous frame.

Thanks to this, the size of all of the frames other than the keyframe can be greatly reduced, but:
* loss of a keyframe or P-frame will result in a freeze and the receiver signaling that something is wrong and video cannot be decoded
* video playback can only start from a keyframe

Thus, it's very important not to lose the keyframes, or in the case of loss, swiftly respond to keyframe requests from the receiving peer and produce a new keyframe, as
typically (at least in WebRTC) intervals between unprompted keyframes in a video stream can be counted in tens of seconds. As you probably realize, a 15-second video
freeze would be quite disastrous! It's also important to request a new keyframe when a new peer that's supposed to receive media joins, so they can start video
playback right away instead of waiting.

> #### WebRTC internals {: .tip}
> If you're developing using a Chromium-based browser, be sure to type out `chrome://webrtc-internals` in your address bar,
> you'll access a lot of WebRTC-related stats.
>
> If you ever see a black screen with the "loading" spinning circle instead of your video in the `video` HTML element, be sure
> to find your PeerConnection in the WebRTC internals, go to the `inbound-rtp(type=video, ...)` tab and check the `pliCount` stat.
> If you see it growing, but the video still does not load, you most likely are missing a keyframe and are not responding
> to the PLI (Picture Loss Indication) requests with a new keyframe.

In the case of a forwarding unit, like the example we have been examining in this section, we cannot really produce a keyframe, as we don't produce any video at all.
The only option is to send the keyframe request to the source, which in `ExWebRTC.PeerConnection` can be accomplished with the `PeerConnection.send_pli` function.
PLI (Picture Loss Indication) is simply a type of RTCP packet.

Usually, when forwarding media between peers, we would:
* send PLI to source tracks when a new receiving peer joins,
* forward PLI from source tracks to receiving tracks

This can be achieved with this piece of code similar to this:

```elixir
defp handle_info(:new_peer_joined, state) do
  for source <- state.sources do
    :ok = PeerConnection.send_pli(source.peer_connection, source.video_track_id);
  end
  {:noreply, state}
end

defp handle_info({:ex_webrtc, from, {:rtcp, packets}}, state) do
  for packet <- packets do
    case packet do
      %ExRTCP.Packet.PayloadFeedback.PLI{media_ssrc: ssrc} ->
        # TODO how to get the ids

        :ok = PeerConnection.send_pli(peer_connection, source_track_id)

      _other -> :ok
    end
  end

  {:noreply, state}
end
```

Just be careful to not overwhelm the source with PLIs! In a real application, we should probably implement some kind of rate limiting for the keyframe
requests.

### Depayloading and decoding the packets

_TBD_
