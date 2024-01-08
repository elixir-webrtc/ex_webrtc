defmodule ExWebRTC.BrowserSDPTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.{MediaStreamTrack, PeerConnection, RTPTransceiver, SessionDescription}

  for browser <- ["chromium", "firefox"] do
    test "#{browser} SDP offer" do
      {:ok, pc} = PeerConnection.start_link()

      offer = %SessionDescription{
        type: :offer,
        sdp: File.read!("test/fixtures/sdp/#{unquote(browser)}_audio_video_sdp.txt")
      }

      :ok = PeerConnection.set_remote_description(pc, offer)

      [
        %RTPTransceiver{direction: :recvonly, kind: :audio},
        %RTPTransceiver{direction: :recvonly, kind: :video}
      ] = PeerConnection.get_transceivers(pc)

      assert_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{kind: :audio}}}
      assert_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{kind: :video}}}
      refute_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{}}}
    end
  end
end
