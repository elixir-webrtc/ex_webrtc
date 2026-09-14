defmodule ExWebRTC.RTP.AV1Test do
  use ExUnit.Case, async: true

  alias ExRTP.Packet
  alias ExWebRTC.RTP.AV1

  @obu_temporal_delimiter 2
  @obu_frame 6

  describe "keyframe?/1" do
    test "detects keyframe from single complete OBU" do
      # Create a frame OBU with KEY_FRAME type (0)
      # OBU header: forbidden=0, type=6 (frame), extension=0, has_size=1, reserved=0
      # Frame header: show_existing_frame=0, frame_type=0 (KEY_FRAME)
      frame_payload = <<0::1, 0::2, 1::1, 0::4>>

      # Create complete OBU with size
      obu_header = <<0::1, @obu_frame::4, 0::1, 1::1, 0::1>>
      obu_size = <<byte_size(frame_payload)>>
      complete_obu = obu_header <> obu_size <> frame_payload

      # Create AV1 RTP payload with Z=0, Y=0 (single complete OBU)
      rtp_payload = <<0::1, 0::1, 1::2, 0::1, 0::3, complete_obu::binary>>

      packet = %Packet{
        payload_type: 45,
        sequence_number: 1,
        timestamp: 1000,
        ssrc: 12345,
        payload: rtp_payload
      }

      assert AV1.keyframe?(packet)
    end

    test "detects non-keyframe from single complete OBU" do
      # Create a frame OBU with INTER_FRAME type (1)
      # Frame header: show_existing_frame=0, frame_type=1 (INTER_FRAME)
      frame_payload = <<0::1, 1::2, 1::1, 0::4>>

      # Create complete OBU with size
      obu_header = <<0::1, @obu_frame::4, 0::1, 1::1, 0::1>>
      obu_size = <<byte_size(frame_payload)>>
      complete_obu = obu_header <> obu_size <> frame_payload

      # Create AV1 RTP payload with Z=0, Y=0 (single complete OBU)
      rtp_payload = <<0::1, 0::1, 1::2, 0::1, 0::3, complete_obu::binary>>

      packet = %Packet{
        payload_type: 45,
        sequence_number: 1,
        timestamp: 1000,
        ssrc: 12345,
        payload: rtp_payload
      }

      refute AV1.keyframe?(packet)
    end

    test "returns false for non-frame OBU" do
      # Create a temporal delimiter OBU (not a frame)
      obu_header = <<0::1, @obu_temporal_delimiter::4, 0::1, 1::1, 0::1>>
      obu_size = <<0>>
      complete_obu = obu_header <> obu_size

      # Create AV1 RTP payload
      rtp_payload = <<0::1, 0::1, 1::2, 0::1, 0::3, complete_obu::binary>>

      packet = %Packet{
        payload_type: 45,
        sequence_number: 1,
        timestamp: 1000,
        ssrc: 12345,
        payload: rtp_payload
      }

      refute AV1.keyframe?(packet)
    end

    test "returns false when only sequence header is present" do
      sequence_payload = <<0xAA>>
      obu_header = <<0::1, 1::4, 0::1, 1::1, 0::1>>
      obu_size = <<byte_size(sequence_payload)>>
      complete_obu = obu_header <> obu_size <> sequence_payload

      rtp_payload = <<0::1, 0::1, 1::2, 0::1, 0::3, complete_obu::binary>>

      packet = %Packet{
        payload_type: 45,
        sequence_number: 1,
        timestamp: 1000,
        ssrc: 12345,
        payload: rtp_payload
      }

      refute AV1.keyframe?(packet)
    end

    test "returns false when frame is not displayed" do
      frame_payload = <<0::1, 0::2, 0::1, 0::4>>
      obu_header = <<0::1, @obu_frame::4, 0::1, 1::1, 0::1>>
      obu_size = <<byte_size(frame_payload)>>
      complete_obu = obu_header <> obu_size <> frame_payload

      rtp_payload = <<0::1, 0::1, 1::2, 0::1, 0::3, complete_obu::binary>>

      packet = %Packet{
        payload_type: 45,
        sequence_number: 1,
        timestamp: 1000,
        ssrc: 12345,
        payload: rtp_payload
      }

      refute AV1.keyframe?(packet)
    end

    test "returns false for fragmented OBU (last fragment)" do
      # Z=1, Y=0: last fragment
      frame_payload = <<0::1, 0::2, 0::5>>
      rtp_payload = <<1::1, 0::1, 1::2, 0::1, 0::3, frame_payload::binary>>

      packet = %Packet{
        payload_type: 45,
        sequence_number: 2,
        timestamp: 1000,
        ssrc: 12345,
        payload: rtp_payload
      }

      refute AV1.keyframe?(packet)
    end

    test "returns false for fragmented OBU (middle fragment)" do
      # Z=1, Y=1: middle fragment
      frame_payload = <<0::1, 0::2, 0::5>>
      rtp_payload = <<1::1, 1::1, 1::2, 0::1, 0::3, frame_payload::binary>>

      packet = %Packet{
        payload_type: 45,
        sequence_number: 2,
        timestamp: 1000,
        ssrc: 12345,
        payload: rtp_payload
      }

      refute AV1.keyframe?(packet)
    end

    test "detects keyframe from N bit (new coded video sequence)" do
      # N bit = 1 indicates new coded video sequence (keyframe with sequence header)
      # This is the primary way to detect keyframes per RFC
      # Create any payload - the N bit is what matters
      obu_header = <<0::1, @obu_temporal_delimiter::4, 0::1, 1::1, 0::1>>
      obu_size = <<0>>
      complete_obu = obu_header <> obu_size

      # Create AV1 RTP payload with N=1 (new coded video sequence)
      rtp_payload = <<0::1, 1::1, 0::2, 1::1, 0::3, complete_obu::binary>>

      packet = %Packet{
        payload_type: 45,
        sequence_number: 1,
        timestamp: 1000,
        ssrc: 12345,
        payload: rtp_payload
      }

      assert AV1.keyframe?(packet)
    end

    test "returns false for invalid payload" do
      packet = %Packet{
        payload_type: 45,
        sequence_number: 1,
        timestamp: 1000,
        ssrc: 12345,
        payload: <<0xFF, 0xFF>>
      }

      refute AV1.keyframe?(packet)
    end

    test "detects keyframe when RTP payload uses length prefix" do
      frame_payload = <<0::1, 0::2, 1::1, 0::4>> <> :binary.copy(<<0>>, 130)
      obu_header = <<0::1, @obu_frame::4, 0::1, 0::1, 0::1>>
      complete_obu = obu_header <> frame_payload
      leb_prefix = AV1.LEB128.encode(byte_size(complete_obu))

      rtp_payload = <<0::1, 0::1, 0::2, 0::1, 0::3, leb_prefix::binary, complete_obu::binary>>

      packet = %Packet{
        payload_type: 45,
        sequence_number: 3,
        timestamp: 2000,
        ssrc: 6789,
        payload: rtp_payload
      }

      assert AV1.keyframe?(packet)
    end

    test "detects keyframe when OBU size exceeds fragment" do
      declared_size = 200
      frame_payload = <<0::1, 0::2, 1::1, 0::4>>
      obu_header = <<0::1, @obu_frame::4, 0::1, 1::1, 0::1>>
      obu_size = AV1.LEB128.encode(declared_size)
      truncated_obu = obu_header <> obu_size <> frame_payload

      rtp_payload = <<0::1, 0::1, 1::2, 0::1, 0::3, truncated_obu::binary>>

      packet = %Packet{
        payload_type: 45,
        sequence_number: 4,
        timestamp: 3000,
        ssrc: 6789,
        payload: rtp_payload
      }

      assert AV1.keyframe?(packet)
    end
  end
end
