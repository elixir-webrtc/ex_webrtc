defmodule ExWebRTC.BrowserSDPTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.{MediaStreamTrack, PeerConnection, RTPTransceiver, SessionDescription}

  for peer <- ["chromium", "firefox", "obs"] do
    test "#{peer} SDP offer is functional and maintains tracks" do
      {:ok, pc} = PeerConnection.start_link()

      offer = %SessionDescription{
        type: :offer,
        sdp: File.read!("test/fixtures/sdp/#{unquote(peer)}_audio_video_sdp.txt")
      }

      :ok = PeerConnection.set_remote_description(pc, offer)

      assert [
               %RTPTransceiver{direction: :recvonly, kind: :audio},
               %RTPTransceiver{direction: :recvonly, kind: :video}
             ] = PeerConnection.get_transceivers(pc)

      assert_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{kind: :audio}}}
      assert_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{kind: :video}}}
      refute_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{}}}

      {:ok, answer} = PeerConnection.create_answer(pc)

      assert [
               %RTPTransceiver{direction: :recvonly, kind: :audio},
               %RTPTransceiver{direction: :recvonly, kind: :video}
             ] = PeerConnection.get_transceivers(pc)

      :ok = ExWebRTC.PeerConnection.set_local_description(pc, answer)

      assert [
               %RTPTransceiver{direction: :recvonly, kind: :audio},
               %RTPTransceiver{direction: :recvonly, kind: :video}
             ] = PeerConnection.get_transceivers(pc)
    end
  end
end
