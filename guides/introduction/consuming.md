# Consuming media data

Other than just forwarding, we would like to be able to use the media right in the Elixir app to e.g.
use it as a machine learning model input, or create a recording of a meeting.

In this tutorial, we are going to depayload and decode received video data to use it for ML inference.

## Depayloading RTP

We refer to the process of getting the media payload out of RTP packets as _depayloading_. It may seem straightforward at first,
we just take the payload of the packets and we get a stream of media data. Sometimes it is that simple, like in the
case of Opus-encoded audio, where each of the RTP packets is, more or less, 20 milliseconds of audio, and that's it.

> #### Codecs {: .info}
> A media codec is a program/technique used to encode/decode digital video and audio streams. Codecs also compress the media data,
> otherwise, it would be too big to send over the network (bitrate of raw 24-bit color depth, FullHD, 60 fps video is about 3 Gbit/s!).
>
> In WebRTC, most likely you will encounter VP8, H264 or AV1 video codecs and Opus audio codec. Codecs used during the session are negotiated in
> the SDP offer/answer exchange. You can tell what codec is carried in an RTP packet by inspecting its payload type (`payload_type` field in the case of Elixir WebRTC).
> This value should correspond to one of the codecs included in the SDP offer/answer.

Unfortunately, in other cases, we need to do more work. In video, things are more complex: each video frame is usually split into multiple packets (and
we need complete frames, not some pieces of encoded video out of context), the video codec does not keep track of timestamps, and many other quirks.

Elixir WebRTC provides depayloading utilities for some codecs (see the `ExWebRTC.RTP.<codec>` submodules). For instance, when receiving VP8 RTP packets, we could depayload
the video by doing:

```elixir
def init(_) do
  # ...
  state = %{depayloader: ExWebRTC.Media.VP8.Depayloader.new()}
  {:ok, state}
end

def handle_info({:ex_webrtc, _from, {:rtp, _track_id, nil, packet}}, state) do
  depayloader =
    case ExWebRTC.RTP.VP8.Depayloader.write(state.depayloader, packet) do
      {:ok, depayloader} -> depayloader
      {:ok, frame, depayloader} ->
        # we collected a whole frame (it is just a binary)!
        # we will learn what to do with it in a moment
        depayloader
    end

  {:noreply, %{state | depayloader: depayloader}}
end
```

Every time we collect a whole video frame consisting of a bunch of RTP packets, the `VP8.Depayloader.write` returns it for further processing.

> #### Codec configuration {: .warning}
> By default, `ExWebRTC.PeerConnection` will use a set of default codecs when negotiating the connection. In such case, you have to either:
>
> * support depayloading/decoding for all of the negotiated codecs
> * force some specific set of codecs (or even a single codec) in the `PeerConnection` configuration.
>
> Of course, the second option is much simpler, but it increases the risk of failing the negotiation, as the other peer might not support your codec of choice.
> If you still want to do it the simple way, set the codecs in `PeerConnection.start_link`
> ```elixir
> codec = %ExWebRTC.RTPCodecParameters{
>     payload_type: 96,
>     mime_type: "video/VP8",
>     clock_rate: 90_000
> }
> {:ok, pc} = ExWebRTC.PeerConnection.start_link(video_codecs: [codec])
> ```
> This way, you either will always have to send/receive VP8 video codec, or you won't be able to negotiate a video stream at all. At least you won't encounter
> unpleasant bugs in video decoding!

## Decoding the media to raw format

Before we use the video as an input to the machine learning model, we need to decode it into raw format. Video decoding or encoding is a very
complex and resource-heavy process, so we don't provide anything for that in Elixir WebRTC, but you can use the `xav` library, a simple wrapper over `ffmpeg`,
to decode the VP8 video. Let's modify the snippet from the previous section to do so.

```elixir
def init(_) do
  # ...
  serving = # setup your machine learning model (i.e. using Bumblebee)
  state = %{
    depayloader: ExWebRTC.Media.VP8.Depayloader.new(),
    decoder: Xav.Decoder.new(:vp8),
    serving: serving
  }
  {:ok, state}
end

def handle_info({:ex_webrtc, _from, {:rtp, _track_id, nil, packet}}, state) do
  depayloader =
    with {:ok, frame, depayloader} <- ExWebRTC.RTP.VP8.Depayloader.write(state.depayloader, packet),
         {:ok, raw_frame} <- Xav.Decoder.decode(state.decoder, frame) do
      # raw frame is just a 3D matrix with the shape of resolution x colors (e.g 1920 x 1080 x 3 for FullHD, RGB frame)
      # we can cast it to Elixir Nx tensor and use it as the machine learning model input
      # machine learning stuff is out of scope of this tutorial, but you probably want to check out Elixir Nx and friends
      tensor = Xav.Frame.to_nx(raw_frame)
      prediction = Nx.Serving.run(state.serving, tensor)
      # do something with the prediction

      depayloader
    else
      {:ok, depayloader} -> depayloader
      {:error, _err} -> # handle the error
    end

  {:noreply, %{state | depayloader: depayloader}}
end
```

We decoded the video and used it as an input of the machine learning model and got some kind of prediction - do whatever you want with it.

> #### Jitter buffer {: .warning}
> Do you recall that WebRTC uses UDP under the hood, and UDP does not ensure packet ordering? We could ignore this fact when forwarding the packets (as
> it was not our job to decode/play/save the media), but now packets out of order can seriously mess up the process of decoding.
> To remedy this issue, something called _jitter buffer_ can be used. Its basic function
> is to delay/buffer incoming packets by some time, let's say 100 milliseconds, waiting for the packets that might be late. Only if the packets do not arrive after the
> additional 100 milliseconds, we count them as lost. To learn more about jitter buffer, read [this](https://bloggeek.me/webrtcglossary/jitter-buffer/).
>
> As of now, Elixir WebRTC does not provide a jitter buffer, so you either have to build something yourself or wish that such issues won't occur, but if anything
> is wrong with the decoded video, this might be the problem.

This tutorial shows, more or less, what the [Recognizer](https://github.com/elixir-webrtc/apps/tree/master/recognizer) app does. Check it out, along with other
example apps in the [apps](https://github.com/elixir-webrtc/apps) repository, it's a great reference on how to implement fully-fledged apps based on Elixir WebRTC.

