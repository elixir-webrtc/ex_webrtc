defmodule ExWebRTC.RTPTransceiverTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.{MediaStreamTrack, PeerConnection, RTPTransceiver, Utils}

  {:ok, pc} = PeerConnection.start_link()
  @config PeerConnection.get_configuration(pc)
  :ok = PeerConnection.close(pc)

  @ssrc 1234
  @rtx_ssrc 2345

  @track MediaStreamTrack.new(:video, [MediaStreamTrack.generate_stream_id()])

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
  end

  defp test_sender_attrs_present(tr) do
    mline = RTPTransceiver.to_offer_mline(tr, @opts)

    # Assert rtp sender attributes are present.
    # Their exact values are checked in rtp_sender_test.exs.
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
end
