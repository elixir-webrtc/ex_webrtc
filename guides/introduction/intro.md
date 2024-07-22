# Introduction to WebRTC

In this series of tutorials, we are going to learn what is WebRTC, and go through some simple use cases of Elixir WebRTC.
Its purpose is to teach you where you'd want to use WebRTC, show you what the WebRTC API looks like, and how it should
be used, focusing on some common caveats.

> #### Before You Start {: .info}
> This guide assumes little prior knowledge of the WebRTC API, but it would be highly beneficial
> to go through the [MDN WebRTC tutorial](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API)
> as the Elixir API tries to closely mimic the browser JavaScript API.

## What is WebRTC

WebRTC is an open, real-time communication standard that allows you to send video, audio, and generic data between peers over the network.
It places a lot of emphasis on low latency (targeting values in low hundreds of milliseconds end-to-end) and was designed to be used peer-to-peer.

WebRTC is implemented by all of the major web browsers and is available as a JavaScript API, there's also native WebRTC clients for Android and iOS
and implementation in other programming languages ([Pion](https://github.com/pion/webrtc), [webrtc.rs](https://github.com/webrtc-rs/webrtc),
and now [Elixir WebRTC](https://github.com/elixir-webrtc/ex_webrtc)).

## Where would you use WebRTC

WebRTC is the obvious choice in applications where low latency is important. It's also probably the easiest way to obtain the voice and video from a user of
your web application. Here are some example use cases:

* videoconferencing apps (one-on-one meetings of fully fledged meeting rooms, like Microsoft Teams or Google Meet)
* ingress for broadcasting services (as a presenter, you can use WebRTC to get media to a server, which will then broadcast it to viewers using WebRTC or different protocols)
* obtaining voice and video from web app users to use it for machine learning model inference on the back end.

In general, all of the use cases come down to getting media from one peer to another. In the case of Elixir WebRTC, one of the peers is usually a server,
like your Phoenix app (although it doesn't have to - there's no concept of server/client in WebRTC, so you might as well connect two browsers or two Elixir peers).

This is what the next section of this tutorial series will focus on - we will try to get media from a web browser to a simple Elixir app.
