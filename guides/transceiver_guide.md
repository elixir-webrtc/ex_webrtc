# Transceiver Guide

Transceiver represents an entity responsible both for sending and receiving media data.
It consist of RTP sender and RTP receiver.
Each transceiver maps to one mline in the SDP offer/answer.

Why do we need transceivers and cannot just operate on tracks?
* We can establish P2P connection even before obtaining access to media devices (see [Warmup](#warmup)).
In the previous version of the API this was also possible but required creating
a dummy track and replacing it with the real one once it was finally available.
* They map directly to the SDP offer/answer giving high control over what is sent on which
transceiver.
This might have been especially important in the old days when media migh have not been bundled on
a single ICE socket.
In such a case, every mline could use a separate pair of ports.
On the other hand, `addTrack` always picks the first free transceiver, which limits this control.
* They allow for offering to receive media in a consistent to offering to send media method way.
In the previous version of the API, user had to call `addTrack` to offer to send media and 
`createOffer` with `{offerToReceiveVideo: 3}` to offer to only receive media, which was asymmetric and
counter-intuitve.

When speaking of transceivers there are also a couple of other notes worth mentioning before moving forward.
* `direction` is our (local), preffered direction of the transceiver and can never be changed by applying remote offer/answer.
When adding a transceiver, it is by default created with `sendrecv` direction.
When applying a remote offer that contains new mline(s), a new transceiver(s) is created with `recvonly` direction, even when the offer offers to receive media.
* `currentDirection` is a direction negotiated between local and remote side and it changes when applying local or remote SDP
* Transceiver is always created with `RTCRtpReceiver` with a `MediaStreamTrack`. 
See [Early Media](#early-media).
* Applying a remote offer never steals explicitly created transceiver (i.e. added via `addTransceiver`).
However, keep in mind this can happen when using `addTrack`.
See [Stealing Transceiver](#stealing-transceiver).

We also recommend reading those articles:
* [Plan B vs Unified Plan](https://docs.google.com/document/d/1-ZfikoUtoJa9k-GZG1daN0BU3IjIanQ_JSscHxQesvU/edit#heading=h.wuu7dx8tnifl)
* [The evolution of WebRTC 1.0](https://blog.mozilla.org/webrtc/the-evolution-of-webrtc/)
* [Exploring RTCRtpTransceiver](https://blog.mozilla.org/webrtc/rtcrtptransceiver-explored/)

## Warmup

Warmup is a technic where we establish or start establishing WebRTC connection
before we get access to media devices.
Once media becomes available, we attach `MediaStreamTrack` to the peer connection using `replaceTrack`.
This allows us to speed-up connection establishment time.

Read more at: https://www.w3.org/TR/webrtc/#advanced-peer-to-peer-example-with-warm-up

<!-- tabs-open -->

### JavaScript

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

This section outlines how you can establish bidirectional connection
using a single negotiation and a warmup technic. 

<!-- tabs-open -->

### JavaScript

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

## Reject incoming track

To reject incoming track, we simply change transceiver's direction to "inactive".
Things to note:
* track events are always emitted after applying remote offer
* if we change transceiver (that was created by applying remote offer) direction
to "inactive", we will get mute event on track emitted when applying remote offer

<!-- tabs-open -->

### JavaScript

```js
pc1 = new RTCPeerConnection();
pc2 = new RTCPeerConnection();

tr = pc1.addTransceiver("audio");

offer = await pc1.createOffer();
await pc1.setLocalDescription(offer);
// this will trigger track event
await pc2.setRemoteDescription(offer);

// reject incoming track by setting the direction to "inactive"
pc2.getTransceivers()[0].direction = "inactive";

answer = await pc2.createAnswer();
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
# this will trigger :track message
:ok = PeerConnection.set_local_description(pc1, offer)
:ok = PeerConnection.set_remote_description(pc2, offer)

[pc2_tr] = PeerConnection.get_transceivers(pc2)
:ok = PeerConnection.set_transceiver_direction(pc2, pc2_tr.id, :inactive)

{:ok, answer} = PeerConnection.create_answer(pc2)
# this will trigger :track_muted message
:ok = PeerConnection.set_local_description(pc2, answer)
:ok = PeerConnection.set_remote_description(pc1, answer)
```

<!-- tabs-close -->

## Stopping transceivers

Stopping a transceiver immediately results in stopping sending and receivng media data but 
it still requires renegotiation, after wich the transceiver is removed from connection's
set of transceivers.

Notes:
* after stopping a transceiver, SDP offer/answer will still contain its mline but with port
number set to 0, indicating that this mline is unused
* when applying remote offer with unused mlines, transceivers for those mlines will be created
but no track events will be emitted. 
Once an answer is generated and applied (i.e. we finialize negotiation process), 
transceivers created in the previous step will be removed.

<!-- tabs-open -->

### JavaScript

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

// observe that after setting remote offer with unused mlines,
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

dbg(PeerConnection.get_transceivers(pc2))

{:ok, answer} = PeerConnection.create_answer(pc2)
:ok = PeerConnection.set_local_description(pc2, answer)

dbg(PeerConnection.get_transceivers(pc2))

:ok = PeerConnection.set_remote_description(pc1, answer)
```

<!-- tabs-close -->

## Recycling mlines

When calling stop on `RTCRtpTransceiver`, it will be eventually removed from
a connection's set of transceivers.
However, the number of mlines in SDP offer/answer can never decrease.
`mlines` corresponding to stopped transceivers can be reused when a new transceiver appears.
This process is known as recycling mlines and it prevents SDP from becoming too large.

Things to note:
* a new transceiver will always try to reuse the first free mline, no matter of its kind i.e.
whether it is audio or video
* the order of transceivers in a connection's set of transceivers matches the order in which
transceivers were added but may be different than the order of mlines in SDP offer/answer

<!-- tabs-open -->

### JavaScript

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

// notice that after renegotiation
// pc1.getTransceivers() will only
// return one (video) transceiver

tr3 = pc1.addTransceiver("video");

// Notice that createOffer will reuse (recycle)
// free mline, even though its initiall type was audio.
// However, pc1.getTransceivers() will return [tr1, tr3].
// That's important as the order of transceivers doesn't
// have to match the order of mlines i.e. tr3 maps to mline
// with index 0 and tr1 maps to mline with index 1.
offer = await pc1.createOffer();
await pc1.setLocalDescription(offer);
await pc2.setRemoteDescription(offer);
answer = await pc2.createAnswer();
await pc2.setLocalDescription(answer);
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
```

<!-- tabs-close -->

## Stealing transceiver

When applying a remote offer that contains a new mline, peer connection
will try to find a transceiver it can use to associate with this mline
assuming this transceiver was created with `addTrack` and no `addTransceiver`.
Why so?
The assumption is that when user calls `addTrack` (and as a result creates a transceiver
under the hood), they don't pay attention to how this track is sent to the other side,
which is not the case when user explicitly creates transceiver with `addTransceiver`.


<!-- tabs-open -->

### JavaScript

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

dbg(PeerConnection.get_transceivers(pc2))
```

<!-- tabs-close -->


<!-- tabs-open -->

### Java Script

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

dbg(PeerConnection.get_transceivers(pc2))
```

<!-- tabs-close -->

## Early Media

When you create a new transceiver, it is always created with `RTCRtpReceiver` with `MediaStreamTrack`.
This track is never removed.
Even when the remote side calls `removeTrack`, only `mute` event will be emitted.
One of the purposes of `MediaStreamTrack` to be always present in `RTCRtpReceiver` was to support so called Early Media.
After the initial negotiation, when one side offers to receive new media, the other side may generate an answer and immediately start sending data.
The first peer (thanks to the `MediaStreamTrack` being created beforehand) will be able to receive incoming data 
and display it even before receiving and applying the answer.
However, support for early media has been removed (see [here](https://github.com/w3c/webrtc-pc/issues/2880#issuecomment-1875121429)).

It is unclear what are other use-cases for `MediaStreamTrack` to be always present and not removed when e.g. the other side calls `removeTrack`.
