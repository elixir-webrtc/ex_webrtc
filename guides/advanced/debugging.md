# Debugging WebRTC

WebRTC is a very complex technology with a lot of moving pieces under the hood, which can make debugging very challanging.
Furtunately, there quite a lot of tools and techiniques created to make this process a bit easier.

This tutorial will teach you a range of WebRTC debugging metchods - from simple to advanced ones. We will go through
how you can inspect and monitor information about ICE connection establishment, negotiation and RTP packets streams both
from the web browser and Elixir side of things.

## WebRTC Internals

If you're using Chromium-based web browser, you're in luck. Chromium provides `chrome:://webrtc-internals` - page with WebRTC stats
about currently used PeerConnections in you browser. If you access this address, you'll see something like this:

<video width="100%" controls muted autoplay loop>
  <source src="assets/webrtc_internals.mp4" type="video/mp4">
</video>

The visual aspects may not knock you off your feet, but it provides a lot very useful information, like:

1. **PeerConnection picker** - it allows you to choose which PeerConnection to inspect. In this case, I opened our [Nexus](nexus.elixir-webrtc.org) example
in another tab. It uses a single PeerConnection, which can be seen in the picker.

2. **Connection state and ICE candidates** - here you can see how the state of PeerConnection changed. You can also expand the `ICE candidate grid` to see all of the local
and remote ICE candidates used by this PeerConnection.

3. **Stats Tables** - metrics gathered by PeerConnection. There's a lot of stuff here, but the most interesting tabs are:
    * bolded `candidate-pair` - this is the ICE candidate pair currently used by the PeerConnection. It will show network stats about the aggregated network
    traffic between the WebRTC peers.
    * `outbound-rtp` - you'll see a separate `outbound-rtp` section for every track and Simulcast layer you are sending. It provides you with stats like
    bitrate of the media sent, resolution of the video, frame rate or the number of NACKs (negative acknowledgments, basically tells you how many packets send on
    this track were lost)
    * `inbound-rtp` - similar to `outbound-rtp`, but for the media received. It can tell you a bunch of very useful things, like:
        * if `packetsReceived` is 0, make sure you're sending the packets, that you're using a proper `track_id` (assuming that the sending peer uses Elixir WebRTC),
        that the transceiver responsible for this track has either `recvonly` or `sendrecv` direction,
        * if `packetsReceived` is growing, but `framesDecoded` is 0 or simply not moving, something is wrong with the video. Take a look at `pliCount` stat, if
        it's growing indefinitely, it means that the track is expecting to receive a keyframe, but it is not arriving. Make sure that you're properly handling
        PLI on the WebRTC peer that is sending the data.

![WebRTC Internals](assets/webrtc_internals_1.png)

4. **Stats graphs** - these are real-time graphs showing metrics that we've seen in the "Stats Table".

5. **Negotiation timeline** - timline of events that happend around the PeerConnection related to the API. It shows you what functions were called, what event fired etc.
You could gather similar information by adding handlers and logs for events on the `RTCPeerConnection` object, but this is easier and nicely formatted.

![WebRTC Internals](assets/webrtc_internals_2.png)

Of course, it's best to explore the WebRTC internals a bit and find infromation that will be beneficial to your specific case.

> #### Other browsers {: .info}
> Chromium's WebRTC Internals is arguably the best tool of this kind. Firefox provides `about:webrtc` page, but it's not nearly as featureful as `chrome::/webrtc-internals`.
> Safari does not have an equivalent, but it allows you to enable verbose logging of WebRTC-related stuff.

## Elixir WebRTC Dashboard

While Chromium's `chrome://webrtc-internals` provides you with stats about PeerConnection in the browser, Elixir WebRTC has its own [dashboard](https://github.com/elixir-webrtc/ex_webrtc_dashboard).
It is an extension to [Phoenix LiveDashboard](https://github.com/phoenixframework/phoenix_live_dashboard). It can be added with a few lines of coded to your Phoenix
project and it provides iformation about PeerConnection state, ICE candidates, inbound and outbound RTP etc. It is not as rich as the WebRTC internals, but still may
be very helpful when debugging.

<video width="100%" controls muted autoplay loop>
  <source src="assets/dashboard.mp4" type="video/mp4">
</video>

We won't go throught each of the sections - if you're familiar with WebRTC internals, you'll feel right at home in the dashborad.

> #### getStats {: .info}
> Be aware that the WebRTC API provides `getStats` function, which (not suprisingly) returns an object containing various WebRTC stats.
> This is what the `chrome://webrtc-internals` and our dashboard use under the hood. `getStats` might not be an ideal aid when debugging,
> but there's plenty of tools (e.g. for observability) that use the `getState` output.

## Dumping raw RTP packets in Chromium

TODO
