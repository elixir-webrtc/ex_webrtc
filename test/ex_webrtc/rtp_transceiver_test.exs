defmodule ExWebRTC.RTPTransceiverTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.{MediaStreamTrack, PeerConnection, RTPTransceiver, Utils}

  {:ok, pc} = PeerConnection.start_link()
  @config PeerConnection.get_configuration(pc)
  :ok = PeerConnection.stop(pc)

  @ssrc 1234
  @rtx_ssrc 2345

  @stream_id MediaStreamTrack.generate_stream_id()
  @track MediaStreamTrack.new(:video, [@stream_id])

  {_key, cert} = ExDTLS.generate_key_cert()

  @opts [
    ice_ufrag: "ice_ufrag",
    ice_pwd: "ice_pwd",
    ice_options: "trickle",
    fingerprint: {:sha256, Utils.hex_dump(cert)},
    setup: :actpass
  ]

  describe "to_offer_mline/1" do
    test "with sendrecv direction" do
      tr = RTPTransceiver.new(:video, @track, @config, ssrc: @ssrc, rtx_ssrc: @rtx_ssrc)
      test_sender_attrs_present(tr)
    end

    test "with sendonly direction" do
      tr =
        RTPTransceiver.new(:video, @track, @config,
          ssrc: @ssrc,
          rtx_ssrc: @rtx_ssrc,
          direction: :sendonly
        )

      test_sender_attrs_present(tr)
    end

    test "with recvonly direction" do
      tr =
        RTPTransceiver.new(:video, @track, @config,
          ssrc: @ssrc,
          rtx_ssrc: @rtx_ssrc,
          direction: :recvonly
        )

      test_sender_attrs_not_present(tr)
    end

    test "with inactive direction" do
      tr =
        RTPTransceiver.new(:video, @track, @config,
          ssrc: @ssrc,
          rtx_ssrc: @rtx_ssrc,
          direction: :inactive
        )

      test_sender_attrs_not_present(tr)
    end

    test "without rtx" do
      {:ok, pc} = PeerConnection.start_link(features: [])
      config = PeerConnection.get_configuration(pc)

      tr =
        RTPTransceiver.new(:video, @track, config,
          ssrc: @ssrc,
          rtx_ssrc: @rtx_ssrc,
          direction: :sendrecv
        )

      mline = RTPTransceiver.to_offer_mline(tr, @opts)
      ssrc_value = ssrc_msid_value(@stream_id, @track.id)

      assert [%ExSDP.Attribute.MSID{id: @stream_id}] =
               ExSDP.get_attributes(mline, ExSDP.Attribute.MSID)

      assert [] = ExSDP.get_attributes(mline, ExSDP.Attribute.SSRCGroup)

      assert [%ExSDP.Attribute.SSRC{id: @ssrc, attribute: "msid", value: ^ssrc_value}] =
               ExSDP.get_attributes(mline, ExSDP.Attribute.SSRC)
    end

    test "with rtx" do
      tr =
        RTPTransceiver.new(:video, @track, @config,
          ssrc: @ssrc,
          rtx_ssrc: @rtx_ssrc,
          direction: :sendrecv
        )

      mline = RTPTransceiver.to_offer_mline(tr, @opts)
      ssrc_value = ssrc_msid_value(@stream_id, @track.id)

      assert [%ExSDP.Attribute.MSID{id: @stream_id, app_data: @track.id}] ==
               ExSDP.get_attributes(mline, ExSDP.Attribute.MSID)

      assert [%ExSDP.Attribute.SSRCGroup{semantics: "FID", ssrcs: [@ssrc, @rtx_ssrc]}] =
               ExSDP.get_attributes(mline, ExSDP.Attribute.SSRCGroup)

      assert [
               %ExSDP.Attribute.SSRC{id: @ssrc, attribute: "msid", value: ^ssrc_value},
               %ExSDP.Attribute.SSRC{id: @rtx_ssrc, attribute: "msid", value: ^ssrc_value}
             ] = ExSDP.get_attributes(mline, ExSDP.Attribute.SSRC)
    end

    test "without media stream" do
      track = MediaStreamTrack.new(:video)

      tr =
        RTPTransceiver.new(:video, track, @config,
          ssrc: @ssrc,
          rtx_ssrc: @rtx_ssrc,
          direction: :sendrecv
        )

      mline = RTPTransceiver.to_offer_mline(tr, @opts)

      assert [%ExSDP.Attribute.MSID{id: "-", app_data: track.id}] ==
               ExSDP.get_attributes(mline, ExSDP.Attribute.MSID)

      assert [%ExSDP.Attribute.SSRCGroup{semantics: "FID", ssrcs: [@ssrc, @rtx_ssrc]}] =
               ExSDP.get_attributes(mline, ExSDP.Attribute.SSRCGroup)

      assert [
               %ExSDP.Attribute.SSRC{id: @ssrc, attribute: "msid", value: "- #{track.id}"},
               %ExSDP.Attribute.SSRC{id: @rtx_ssrc, attribute: "msid", value: "- #{track.id}"}
             ] == ExSDP.get_attributes(mline, ExSDP.Attribute.SSRC)
    end

    test "with multiple media streams" do
      s1_id = MediaStreamTrack.generate_stream_id()
      s2_id = MediaStreamTrack.generate_stream_id()

      track = MediaStreamTrack.new(:video, [s1_id, s2_id])

      tr =
        RTPTransceiver.new(:video, track, @config,
          ssrc: @ssrc,
          rtx_ssrc: @rtx_ssrc,
          direction: :sendrecv
        )

      mline = RTPTransceiver.to_offer_mline(tr, @opts)

      ssrc1_value = ssrc_msid_value(s1_id, track.id)
      ssrc2_value = ssrc_msid_value(s2_id, track.id)

      assert [
               %ExSDP.Attribute.MSID{id: s1_id, app_data: track.id},
               %ExSDP.Attribute.MSID{id: s2_id, app_data: track.id}
             ] == ExSDP.get_attributes(mline, ExSDP.Attribute.MSID)

      assert [%ExSDP.Attribute.SSRCGroup{semantics: "FID", ssrcs: [@ssrc, @rtx_ssrc]}] =
               ExSDP.get_attributes(mline, ExSDP.Attribute.SSRCGroup)

      assert [
               %ExSDP.Attribute.SSRC{id: @ssrc, attribute: "msid", value: ssrc1_value},
               %ExSDP.Attribute.SSRC{id: @ssrc, attribute: "msid", value: ssrc2_value},
               %ExSDP.Attribute.SSRC{id: @rtx_ssrc, attribute: "msid", value: ssrc1_value},
               %ExSDP.Attribute.SSRC{id: @rtx_ssrc, attribute: "msid", value: ssrc2_value}
             ] == ExSDP.get_attributes(mline, ExSDP.Attribute.SSRC)
    end

    test "without codecs" do
      {:ok, pc} = PeerConnection.start_link(audio_codecs: [], video_codecs: [])
      config = PeerConnection.get_configuration(pc)

      tr =
        RTPTransceiver.new(:video, @track, config,
          ssrc: @ssrc,
          rtx_ssrc: @rtx_ssrc,
          direction: :sendrecv
        )

      mline = RTPTransceiver.to_offer_mline(tr, @opts)

      assert [%ExSDP.Attribute.MSID{id: @stream_id, app_data: @track.id}] ==
               ExSDP.get_attributes(mline, ExSDP.Attribute.MSID)

      assert [] = ExSDP.get_attributes(mline, ExSDP.Attribute.SSRCGroup)
      assert [] = ExSDP.get_attributes(mline, ExSDP.Attribute.SSRC)
    end

    test "without track" do
      tr =
        RTPTransceiver.new(:video, nil, @config,
          ssrc: @ssrc,
          rtx_ssrc: @rtx_ssrc,
          direction: :sendrecv
        )

      mline = RTPTransceiver.to_offer_mline(tr, @opts)

      assert [%ExSDP.Attribute.MSID{id: "-", app_data: tr.sender.id}] ==
               ExSDP.get_attributes(mline, ExSDP.Attribute.MSID)

      assert [
               %ExSDP.Attribute.SSRC{id: @ssrc, attribute: "msid", value: "- #{tr.sender.id}"},
               %ExSDP.Attribute.SSRC{id: @rtx_ssrc, attribute: "msid", value: "- #{tr.sender.id}"}
             ] == ExSDP.get_attributes(mline, ExSDP.Attribute.SSRC)
    end
  end

  defp test_sender_attrs_present(tr) do
    mline = RTPTransceiver.to_offer_mline(tr, @opts)

    # Assert rtp sender attributes are present.
    assert [%ExSDP.Attribute.MSID{}] = ExSDP.get_attributes(mline, ExSDP.Attribute.MSID)
    assert [%ExSDP.Attribute.SSRCGroup{}] = ExSDP.get_attributes(mline, ExSDP.Attribute.SSRCGroup)

    assert [%ExSDP.Attribute.SSRC{}, %ExSDP.Attribute.SSRC{}] =
             ExSDP.get_attributes(mline, ExSDP.Attribute.SSRC)
  end

  defp test_sender_attrs_not_present(tr) do
    mline = RTPTransceiver.to_offer_mline(tr, @opts)

    # assert there are no sender attributes
    assert [] == ExSDP.get_attributes(mline, ExSDP.Attribute.MSID)
    assert [] == ExSDP.get_attributes(mline, ExSDP.Attribute.SSRCGroup)
    assert [] == ExSDP.get_attributes(mline, ExSDP.Attribute.SSRC)
  end

  defp ssrc_msid_value(stream, app_data), do: "#{stream} #{app_data}"
end
