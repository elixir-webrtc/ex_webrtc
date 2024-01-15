# Mastering Transceivers

> #### Before You Start {: .info}
> This guide assumes you have a basic understanding of the WebRTC API
> and are looking for more advanced examples that demonstrate what you can accomplish with transceivers.
> If you are new to this, a good starting point might be to first look at the 
> [MDN WebRTC tutorial](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API).

A transceiver is an entity responsible both for sending and receiving media data.
It consist of an RTP sender and RTP receiver.
Each transceiver maps to one m-line in the SDP offer/answer.

Why do we need transceivers and cannot just operate on tracks?
* We can establish a P2P connection even before obtaining access to media devices (see [Warmup](#warmup)).
In the previous version of the API, this was also possible but required creating
a dummy track and replacing it with the real one once it became available.
* Transceivers map directly to the SDP offer/answer, providing high control over what is sent on which
transceiver.
This might have been especially important in the old days when media often wasn't bundled on a single ICE socket.
In such a case, every m-line could use a separate pair of ports.
On the other hand, `addTrack` always selects the first free transceiver, limiting this control.
* They allow for offering to receive media in a manner consistent with offering to send media.
In the previous version of the API, the user had to call `addTrack` to offer to send media and 
`createOffer` with `{offerToReceiveVideo: 3}` to offer to only receive media, which was asymmetric and
counter-intuitve.

There're also a couple of other notes worth mentioning before moving forward.
* `direction` is our (local) preffered direction of the transceiver and can never be changed by applying a remote offer/answer.
When adding a transceiver, it is created with `sendrecv` direction by default.
When applying a remote offer that contains new m-lines, a new transceiver is created with the `recvonly` direction,
even when the offerer only wants to receive media.
This direction can later be changed with `addTrack`, which sends media data on the first available transceiver, 
provided this transceiver wasn't initially created by `addTransceiver`.
See [Stealing Transceiver](#stealing-transceiver).
* `currentDirection` is a direction negotiated between the local and remote side, 
and it changes when applying local or remote SDP.
* A transceiver is always created with an `RTCRtpReceiver` with a `MediaStreamTrack`. 
See [Early Media](#early-media).
* Applying a remote offer never steals explicitly created transceiver (i.e., added via `addTransceiver`).
However, keep in mind this can happen when using `addTrack`.
See [Stealing Transceiver](#stealing-transceiver).

We also recommend reading these articles:
* [Plan B vs Unified Plan](https://docs.google.com/document/d/1-ZfikoUtoJa9k-GZG1daN0BU3IjIanQ_JSscHxQesvU/edit#heading=h.wuu7dx8tnifl)
* [The evolution of WebRTC 1.0](https://blog.mozilla.org/webrtc/the-evolution-of-webrtc/)
* [Exploring RTCRtpTransceiver](https://blog.mozilla.org/webrtc/rtcrtptransceiver-explored/)

## Warmup

*Warmup* is a technique where we establish or begin to establish WebRTC connection
before gaining access to media devices.
Once the media becomes available, we attach a `MediaStreamTrack` to the peer connection using `replaceTrack`.
This process allows us to speed up the connection establishment time.

Read more at: https://www.w3.org/TR/webrtc/#advanced-peer-to-peer-example-with-warm-up

<!-- tabs-open -->

### JavaScript

[![JS FIDDLE](https://img.shields.io/badge/-JS%20FIDDLE-blueviolet)](https://jsfiddle.net/mickel8/46nozkbj/)

```js
pc1 = new RTCPeerConnection();
pc2 = new RTCPeerConnection();

tr = pc1.addTransceiver("audio");

offer = await pc1.createOffer();
await pc1.setLocalDescription(offer);
await pc2.setRemoteDescription(offer);
answer = await pc2.createAnswer();
await pc2.setLocalDescription(answer);
await pc1.setRemoteDescription(answer);

// once MediaStreamTrack is ready,
// start sending it with replaceTrack
const localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false});
await tr.sender.replaceTrack(localStream.getTracks()[0]);
```

### Elixir WebRTC

```elixir
{:ok, pc1} = PeerConnection.start_link()
{:ok, pc2} = PeerConnection.start_link()

{:ok, tr} = PeerConnection.add_transceiver(pc1, :audio)

{:ok, offer} = PeerConnection.create_offer(pc1)
:ok = PeerConnection.set_local_description(pc1, offer)
:ok = PeerConnection.set_remote_description(pc2, offer)
{:ok, answer} = PeerConnection.create_answer(pc2)
:ok = PeerConnection.set_local_description(pc2, answer)
:ok = PeerConnection.set_remote_description(pc1, answer)

# altough in Elixir WebRTC user has to send media on their own,
# using send_rtp function, we also added replace_track function
# for parity with JavaScript API
track = MediaStreamTrack.new(:audio)
:ok = PeerConnection.replace_track(pc1, tr.sender.id, track)
```

<!-- tabs-close -->


## Bidirectional connection using a single negotiation

This section outlines how you can establish a bidirectional connection
using a single negotiation and the *Warmup* technique. 

<!-- tabs-open -->

### JavaScript

[![JS FIDDLE](https://img.shields.io/badge/-JS%20FIDDLE-blueviolet)](https://jsfiddle.net/mickel8/om0fk1ve/)

```js
pc1 = new RTCPeerConnection();
pc2 = new RTCPeerConnection();

tr = pc1.addTransceiver("audio");

offer = await pc1.createOffer();
await pc1.setLocalDescription(offer);
await pc2.setRemoteDescription(offer);

// change direction from default "recvonly" to "sendrecv"
pc2.getTransceivers()[0].direction = "sendrecv";

answer = await pc2.createAnswer();
await pc2.setLocalDescription(answer);
await pc1.setRemoteDescription(answer);
```

### Elixir WebRTC

```elixir
{:ok, pc1} = PeerConnection.start_link()
{:ok, pc2} = PeerConnection.start_link()

{:ok, _tr} = PeerConnection.add_transceiver(pc1, :audio)

{:ok, offer} = PeerConnection.create_offer(pc1)
:ok = PeerConnection.set_local_description(pc1, offer)
:ok = PeerConnection.set_remote_description(pc2, offer)

[pc2_tr] = PeerConnection.get_transceivers(pc2)
:ok = PeerConnection.set_transceiver_direction(pc2, pc2_tr.id, :sendrecv)

{:ok, answer} = PeerConnection.create_answer(pc2)
:ok = PeerConnection.set_local_description(pc2, answer)
:ok = PeerConnection.set_remote_description(pc1, answer)
```

<!-- tabs-close -->

## Rejecting Incoming Track

To reject incoming track, we simply change the transceiver's direction to "inactive".
Things to note:
* Track events are always emitted after applying the remote offer.
* If we change the transceiver's direction to "inactive", 
we will get a mute event on the track emitted when applying the remote offer.

<!-- tabs-open -->

### JavaScript

[![JS FIDDLE](https://img.shields.io/badge/-JS%20FIDDLE-blueviolet)](https://jsfiddle.net/mickel8/qp9mLeag/)

```js
pc1 = new RTCPeerConnection();
pc2 = new RTCPeerConnection();

pc2.ontrack = ev => {
  ev.track.onmute = _ => console.log("pc2 track onmute");
  console.log("pc2 ontrack");
}

tr = pc1.addTransceiver("audio");

offer = await pc1.createOffer();
await pc1.setLocalDescription(offer);
// this will trigger track event
await pc2.setRemoteDescription(offer);

// reject incoming track by setting the direction to "inactive"
pc2.getTransceivers()[0].direction = "inactive";

answer = await pc2.createAnswer();
console.log("Setting local description on pc2");
// this will trigger mute event 
await pc2.setLocalDescription(answer);
await pc1.setRemoteDescription(answer);
```

### Elixir WebRTC

```elixir
{:ok, pc1} = PeerConnection.start_link()
{:ok, pc2} = PeerConnection.start_link()

{:ok, _tr} = PeerConnection.add_transceiver(pc1, :audio)

{:ok, offer} = PeerConnection.create_offer(pc1)
:ok = PeerConnection.set_local_description(pc1, offer)
:ok = PeerConnection.set_remote_description(pc2, offer)

receive do {:ex_webrtc, _pc, {:track, _track}} = msg -> IO.inspect(msg) end

[pc2_tr] = PeerConnection.get_transceivers(pc2)
:ok = PeerConnection.set_transceiver_direction(pc2, pc2_tr.id, :inactive)

{:ok, answer} = PeerConnection.create_answer(pc2)

IO.inspect("Setting local description on pc2");
:ok = PeerConnection.set_local_description(pc2, answer)

receive do {:ex_webrtc, _pc, {:track_muted, _track_id}} = msg -> IO.inspect(msg) end

:ok = PeerConnection.set_remote_description(pc1, answer)
```

<!-- tabs-close -->

## Stopping Transceivers

Stopping a transceiver immediately results in ceasing media transmission, 
but it still requires renegotiation - after which the transceiver is removed from the connection's set of transceivers.

Notes:
* After stopping a transceiver, the SDP offer/answer will still contain its m-line, 
but with the port number set to 0, indicating that this m-line is unused.
* When applying a remote offer with unused m-lines, transceivers for those m-lines will be created, 
but no track events will be emitted. 
Once an answer is generated and applied (i.e., we finalize the negotiation process), 
the transceivers created in the previous step will be removed.

<!-- tabs-open -->

### JavaScript

[![JS FIDDLE](https://img.shields.io/badge/-JS%20FIDDLE-blueviolet)](https://jsfiddle.net/mickel8/r096z8o4/)

```js
pc1 = new RTCPeerConnection();
pc2 = new RTCPeerConnection();

tr1 = pc1.addTransceiver("audio");
tr2 = pc1.addTransceiver("video");

offer = await pc1.createOffer();
await pc1.setLocalDescription(offer);
await pc2.setRemoteDescription(offer);
answer = await pc2.createAnswer();
await pc2.setLocalDescription(answer);
await pc1.setRemoteDescription(answer);

tr1.stop();
tr2.stop();

offer = await pc1.createOffer();
await pc1.setLocalDescription(offer);
await pc2.setRemoteDescription(offer);
answer = await pc2.createAnswer();
await pc2.setLocalDescription(answer);
await pc1.setRemoteDescription(answer);

// negotiate once again even though negotiation is not needed
offer = await pc1.createOffer();
await pc1.setLocalDescription(offer);

// observe that after setting remote offer with unused m-lines,
// stopped transceivers are created...
await pc2.setRemoteDescription(offer);
console.log(pc2.getTransceivers());

answer = await pc2.createAnswer();
// ...and removed 
await pc2.setLocalDescription(answer);
console.log(pc2.getTransceivers());

await pc1.setRemoteDescription(answer);
```

### Elixir WebRTC

```elixir
{:ok, pc1} = PeerConnection.start_link()
{:ok, pc2} = PeerConnection.start_link()

{:ok, tr1} = PeerConnection.add_transceiver(pc1, :audio)
{:ok, tr2} = PeerConnection.add_transceiver(pc1, :video)

{:ok, offer} = PeerConnection.create_offer(pc1)
:ok = PeerConnection.set_local_description(pc1, offer)
:ok = PeerConnection.set_remote_description(pc2, offer)
{:ok, answer} = PeerConnection.create_answer(pc2)
:ok = PeerConnection.set_local_description(pc2, answer)
:ok = PeerConnection.set_remote_description(pc1, answer)

:ok = PeerConnection.stop_transceiver(pc1, tr1.id)
:ok = PeerConnection.stop_transceiver(pc1, tr2.id)

{:ok, offer} = PeerConnection.create_offer(pc1)
:ok = PeerConnection.set_local_description(pc1, offer)
:ok = PeerConnection.set_remote_description(pc2, offer)
{:ok, answer} = PeerConnection.create_answer(pc2)
:ok = PeerConnection.set_local_description(pc2, answer)
:ok = PeerConnection.set_remote_description(pc1, answer)

{:ok, offer} = PeerConnection.create_offer(pc1)
:ok = PeerConnection.set_local_description(pc1, offer)
:ok = PeerConnection.set_remote_description(pc2, offer)

IO.inspect(PeerConnection.get_transceivers(pc2))

{:ok, answer} = PeerConnection.create_answer(pc2)
:ok = PeerConnection.set_local_description(pc2, answer)

transceivers = PeerConnection.get_transceivers(pc2)
[] = transceivers
IO.inspect(transceivers)

:ok = PeerConnection.set_remote_description(pc1, answer)
```

<!-- tabs-close -->

## Recycling m-lines

When calling stop on an `RTCRtpTransceiver`, it will eventually be removed from
the connection's set of transceivers.
However, the number of m-lines in SDP offer/answer can never decrease.
m-lines corresponding to stopped transceivers can be reused when a new transceiver appears.
This process is known as recycling m-lines, and it prevents SDP from becoming excessively large.

Things to note:
* A new transceiver will always attempt to reuse the first free m-line, regardless of its kind i.e.,
whether it's audio or video
* The order of transceivers in a connection's set of transceivers matches the order in which
the transceivers were added, but it may be different than the order of m-lines in SDP offer/answer.

<!-- tabs-open -->

### JavaScript

[![JS FIDDLE](https://img.shields.io/badge/-JS%20FIDDLE-blueviolet)](https://jsfiddle.net/mickel8/m7yq3fv0/)

```js
pc1 = new RTCPeerConnection();
pc2 = new RTCPeerConnection();

tr1 = pc1.addTransceiver("audio");
tr2 = pc1.addTransceiver("video");

offer = await pc1.createOffer();
await pc1.setLocalDescription(offer);
await pc2.setRemoteDescription(offer);
answer = await pc2.createAnswer();
await pc2.setLocalDescription(answer);
await pc1.setRemoteDescription(answer);

tr1.stop();

offer = await pc1.createOffer();
await pc1.setLocalDescription(offer);
await pc2.setRemoteDescription(offer);
answer = await pc2.createAnswer();
await pc2.setLocalDescription(answer);
await pc1.setRemoteDescription(answer);

tr3 = pc1.addTransceiver("video");

// Notice that createOffer will reuse (recycle)
// free m-line, even though its initiall type was audio.
// However, pc1.getTransceivers() will return [tr1, tr3].
// That's important as the order of transceivers doesn't
// have to match the order of m-lines i.e. tr3 maps to m-line
// with index 0 and tr1 maps to m-line with index 1.
offer = await pc1.createOffer();
await pc1.setLocalDescription(offer);
await pc2.setRemoteDescription(offer);
answer = await pc2.createAnswer();
await pc2.setLocalDescription(answer);
await pc1.setRemoteDescription(answer);

// notice that after renegotiation
// pc1.getTransceivers() will only
// return two (video) transceivers
console.log(pc1.getTransceivers());
```

### Elixir WebRTC

```elixir
{:ok, pc1} = PeerConnection.start_link()
{:ok, pc2} = PeerConnection.start_link()

{:ok, tr1} = PeerConnection.add_transceiver(pc1, :audio)
{:ok, tr2} = PeerConnection.add_transceiver(pc1, :video)

{:ok, offer} = PeerConnection.create_offer(pc1)
:ok = PeerConnection.set_local_description(pc1, offer)
:ok = PeerConnection.set_remote_description(pc2, offer)
{:ok, answer} = PeerConnection.create_answer(pc2)
:ok = PeerConnection.set_local_description(pc2, answer)
:ok = PeerConnection.set_remote_description(pc1, answer)

:ok = PeerConnection.stop_transceiver(pc1, tr1.id)

{:ok, offer} = PeerConnection.create_offer(pc1)
:ok = PeerConnection.set_local_description(pc1, offer)
:ok = PeerConnection.set_remote_description(pc2, offer)
{:ok, answer} = PeerConnection.create_answer(pc2)
:ok = PeerConnection.set_local_description(pc2, answer)
:ok = PeerConnection.set_remote_description(pc1, answer)

{:ok, tr3} = PeerConnection.add_transceiver(pc1, :video)

{:ok, offer} = PeerConnection.create_offer(pc1)
:ok = PeerConnection.set_local_description(pc1, offer)
:ok = PeerConnection.set_remote_description(pc2, offer)
{:ok, answer} = PeerConnection.create_answer(pc2)
:ok = PeerConnection.set_local_description(pc2, answer)
:ok = PeerConnection.set_remote_description(pc1, answer)

[%{kind: :video}, %{kind: :video}] = PeerConnection.get_transceivers(pc1)
```

<!-- tabs-close -->

## Stealing Transceiver

When a remote offer that contains a new m-line is applied, 
the peer connection will attempt to find a transceiver it can use to associate with this m-line. 
This is provided that the transceiver was created with `addTrack` and not with `addTransceiver`. 
But why is this so? 
The assumption is that when the user calls `addTrack` (and thereby creates a transceiver under the hood), 
they might not pay attention to how this track is sent to the other side. 
However, this is not the case when a user explicitly creates a transceiver with `addTransceiver`.

<!-- tabs-open -->

### JavaScript

[![JS FIDDLE](https://img.shields.io/badge/-JS%20FIDDLE-blueviolet)](https://jsfiddle.net/mickel8/to4g8erf/)

```js
pc1 = new RTCPeerConnection();
pc2 = new RTCPeerConnection();

pc1_tr1 = pc1.addTransceiver("audio");
pc2_tr1 = pc2.addTransceiver("audio");

offer = await pc1.createOffer();
await pc1.setLocalDescription(offer);
await pc2.setRemoteDescription(offer);
answer = await pc2.createAnswer();
await pc2.setLocalDescription(answer);
await pc1.setRemoteDescription(answer);

// observe that pc2 has two transceivers
console.log(pc2.getTransceivers());
```

### Elixir WebRTC

```elixir
{:ok, pc1} = PeerConnection.start_link()
{:ok, pc2} = PeerConnection.start_link()

{:ok, pc1_tr1} = PeerConnection.add_transceiver(pc1, :audio)
{:ok, pc2_tr1} = PeerConnection.add_transceiver(pc2, :audio)

{:ok, offer} = PeerConnection.create_offer(pc1)
:ok = PeerConnection.set_local_description(pc1, offer)
:ok = PeerConnection.set_remote_description(pc2, offer)
{:ok, answer} = PeerConnection.create_answer(pc2)
:ok = PeerConnection.set_local_description(pc2, answer)
:ok = PeerConnection.set_remote_description(pc1, answer)

transceivers = PeerConnection.get_transceivers(pc2)
2 = Enum.count(transceivers)
IO.inspect(transceivers)
```

<!-- tabs-close -->


<!-- tabs-open -->

### Java Script

[![JS FIDDLE](https://img.shields.io/badge/-JS%20FIDDLE-blueviolet)](https://jsfiddle.net/mickel8/agLzxuo9/)

```js
const localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false});

pc1 = new RTCPeerConnection();
pc2 = new RTCPeerConnection();

pc1_tr1 = pc1.addTransceiver("audio");
pc2_sender = pc2.addTrack(localStream.getTracks()[0]);

offer = await pc1.createOffer();
await pc1.setLocalDescription(offer);
await pc2.setRemoteDescription(offer);
answer = await pc2.createAnswer();
await pc2.setLocalDescription(answer);
await pc1.setRemoteDescription(answer);

// observe that pc2 has one transceiver
console.log(pc2.getTransceivers());
```

### Elixir WebRTC

```elixir
# TODO not supported yet 
{:ok, pc1} = PeerConnection.start_link()
{:ok, pc2} = PeerConnection.start_link()

track = MediaStreamTrack.new(:audio)
{:ok, pc1_tr1} = PeerConnection.add_transceiver(pc1, :audio)
{:ok, _pc2_sender} = PeerConnection.add_track(pc2, track)

{:ok, offer} = PeerConnection.create_offer(pc1)
:ok = PeerConnection.set_local_description(pc1, offer)
:ok = PeerConnection.set_remote_description(pc2, offer)
{:ok, answer} = PeerConnection.create_answer(pc2)
:ok = PeerConnection.set_local_description(pc2, answer)
:ok = PeerConnection.set_remote_description(pc1, answer)

IO.inspect(PeerConnection.get_transceivers(pc2))
```

<!-- tabs-close -->

## Early Media

A new transceiver is always created with an `RTCRtpReceiver` with a `MediaStreamTrack`.
This track is never removed.
Even when the remote side calls `removeTrack`, only a `mute` event will be emitted.

One of the reasons of `MediaStreamTrack` to be always present in the `RTCRtpReceiver` was to support *Early Media*.
After the initial negotiation, when one side offers to receive new media, the other side might generate an answer 
and immediately start sending data.
The first peer (thanks to the `MediaStreamTrack` being created beforehand) would be able to receive incoming data 
and display it even before the answer was received and applied.
However, support for *Early Media* has been removed (see [here](https://github.com/w3c/webrtc-pc/issues/2880#issuecomment-1875121429)).

It is unclear what are other use-cases for the `MediaStreamTrack` to be always present and not removed when e.g. the other side calls `removeTrack`.
