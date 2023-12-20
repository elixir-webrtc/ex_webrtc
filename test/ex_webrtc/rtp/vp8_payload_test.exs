defmodule ExWebrtc.Rtp.Vp8PayloadTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTP.VP8Payload

  test "parse/1 and serialize/1" do
    # test vectors are based on RFC 7741, sec. 4.6

    # random vp8 data, not necessarily correct
    vp8_payload = <<0, 1, 2, 3>>

    # X=1, S=1, PID=0, I=1, pciture_id=17
    frame =
      <<1::1, 0::1, 0::1, 1::1, 0::1, 0::3, 1::1, 0::7, 0::1, 17::7, vp8_payload::binary>>

    parsed_frame =
      %VP8Payload{
        n: 0,
        s: 1,
        pid: 0,
        picture_id: 17,
        tl0picidx: nil,
        tid: nil,
        y: nil,
        keyidx: nil,
        payload: vp8_payload
      }

    assert {:ok, parsed_frame} == VP8Payload.parse(frame)
    assert frame == VP8Payload.serialize(parsed_frame)

    # X=0, S=1, PID=0
    frame = <<0::1, 0::1, 0::1, 1::1, 0::1, 0::3, vp8_payload::binary>>

    parsed_frame = %VP8Payload{
      n: 0,
      s: 1,
      pid: 0,
      picture_id: nil,
      tl0picidx: nil,
      tid: nil,
      y: nil,
      keyidx: nil,
      payload: vp8_payload
    }

    assert {:ok, parsed_frame} == VP8Payload.parse(frame)
    assert frame == VP8Payload.serialize(parsed_frame)

    # X=1, S=1, I=1, M=1, picture_id=4711
    frame =
      <<1::1, 0::1, 0::1, 1::1, 0::1, 0::3, 1::1, 0::7, 1::1, 4711::15, vp8_payload::binary>>

    parsed_frame = %VP8Payload{
      n: 0,
      s: 1,
      pid: 0,
      picture_id: 4711,
      tl0picidx: nil,
      tid: nil,
      y: nil,
      keyidx: nil,
      payload: vp8_payload
    }

    assert {:ok, parsed_frame} == VP8Payload.parse(frame)
    assert frame == VP8Payload.serialize(parsed_frame)

    assert {:error, :invalid_packet} = VP8Payload.parse(<<>>)

    # X=0 and no vp8_payload
    assert {:error, :invalid_packet} =
             VP8Payload.parse(<<0::1, 0::1, 0::1, 1::1, 0::1, 0::3>>)

    # X=1, I=1 picture_id=1 and no vp8_payload
    frame = <<1::1, 0::1, 0::1, 1::1, 0::1, 0::3, 1::1, 0::7, 0::1, 1::7>>
    assert {:error, :invalid_packet} = VP8Payload.parse(frame)

    # invalid reserved bit
    assert {:error, :invalid_packet} =
             VP8Payload.parse(<<0::1, 1::1, 0::1, 1::1, 1::1, 0::3>>)

    # missing picture id
    missing_picture_id = <<1::1, 0::1, 0::1, 1::1, 0::1, 0::3, 1::1, 0::7>>
    assert {:error, :invalid_packet} = VP8Payload.parse(missing_picture_id)

    # missing tl0picidx
    missing_tl0picidx = <<1::1, 0::1, 0::1, 1::1, 0::1, 0::3, 0::1, 1::1, 0::6>>
    assert {:error, :invalid_packet} = VP8Payload.parse(missing_tl0picidx)

    # missing tidykeyidx
    missing_tidykeyidx = <<1::1, 0::1, 0::1, 1::1, 0::1, 0::3, 0::2, 1::1, 0::1, 0::4>>
    assert {:error, :invalid_packet} = VP8Payload.parse(missing_tidykeyidx)
  end
end
