# Consuming media data

Other than just forwarding, we probably would like to be able to use the media right in the Elixir app to
e..g feed it to a machine learning model or create a recording of a meeting.

In this tutorial, we are going to build on top of the simple app from the previous tutorial by, instead of just sending the packets back, depayloading and decoding
the media, using a machine learning model to somehow augment the video, encode and payload it back into RTP packets and only then send it to the web browser.

## Deplayloading RTP

We refer to the process of taking the media payload out of RTP packets as _depayloading_.

> #### Codecs {: .info}
> A media codec is a program used to encode/decode digital video and audio streams. Codecs also compress the media data,
> otherwise, it would be too big to send over the network (bitrate of raw 24-bit color depth, FullHD, 60 fps video is about 3 Gbit/s!).
>
> In WebRTC, most likely you will encounter VP8, H264 or AV1 video codecs and Opus audio codec. Codecs that will be used during the session are negotiated in
> the SDP offer/answer exchange. You can tell what codec is carried in an RTP packet by inspecting its payload type (`packet.payload_type`,
> a non-negative integer field) and match it with one of the codecs listed in this track's transceiver's `codecs` field (you have to find
> the `transceiver` by iterating over `PeerConnection.get_transceivers` as shown previously in this tutorial series).

_TBD_

## Decoding the media to raw format

_TBD_

