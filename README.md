<p align="center">
  <img src="https://raw.githubusercontent.com/elixir-webrtc/ex_webrtc/8404c58384a42f1173ac391e0ad9f69be47881d0/logo_text.svg">
  <br />
  <a href="https://hex.pm/packages/ex_webrtc"><img src="https://img.shields.io/hexpm/v/ex_webrtc.svg" /></a>
  <a href="https://hexdocs.pm/ex_webrtc"><img src="https://img.shields.io/badge/api-docs-yellow.svg?style=flat"  /></a>
  <a href="https://github.com/elixir-webrtc/ex_webrtc/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/elixir-webrtc/ex_webrtc/ci.yml?logo=github&label=CI"  /></a>
  <a href="https://codecov.io/gh/elixir-webrtc/ex_webrtc"><img src="https://codecov.io/gh/elixir-webrtc/ex_webrtc/graph/badge.svg?token=PdnXfnnmNw"  /></a>
</p>

---

**Elixir WebRTC** is an implementation of the [W3C WebRTC API](https://www.w3.org/TR/webrtc/) in the Elixir programming language.

## Installation

Add `ex_webrtc` to the list of dependencies in `mix.exs`

```elixir
def deps do
  [
    {:ex_webrtc, "~> 0.5.0"}
  ]
end
```

Elixir WebRTC comes with optional support for DataChannels, but it must be explicitely turned on by
adding optional `ex_sctp` dependency

```elixir
def deps do
  [
    {:ex_webrtc, "~> 0.5.0"},
    {:ex_sctp, "~> 0.1.0"}
  ]
end
```

Please note that `ex_sctp` requires you to have Rust installed in order to compile.

## Getting started

To get started with Elixir WebRTC, check out:
* the [Introduction to Elixir Webrtc](https://hexdocs.pm/ex_webrtc/intro.html) tutorial
* the [examples directory](https://github.com/elixir-webrtc/ex_webrtc/tree/master/examples) that contains a bunch of very simple usage examples of the library
* the [`apps` repo](https://github.com/elixir-webrtc/apps) with example applications built on top of `ex_webrtc`
* the [documentation](https://hexdocs.pm/ex_webrtc/readme.html), especially the [`PeerConnection` module page](https://hexdocs.pm/ex_webrtc/ExWebRTC.PeerConnection.html)

If you have any questions, ideas or topics to discuss about Elixir WebRTC, head to the [discussions page](https://github.com/orgs/elixir-webrtc/discussions).


## Credits

Elixir WebRTC is created by [Software Mansion](https://swmansion.com/).

Since 2012 Software Mansion is a software agency with experience in building web and mobile apps as well as complex multimedia solutions. We are Core React Native Contributors and experts in live streaming and broadcasting technologies. We can help you build your next dream product – [Hire us](https://swmansion.com/contact/projects).

[![swm](https://logo.swmansion.com/logo?color=white&variant=desktop&width=150 'Software Mansion')](https://swmansion.com)
