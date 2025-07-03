defmodule ExWebRTC.RTP.VP8.OBUTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTP.AV1.{LEB128, OBU}

  @obu_sequence_header 1
  @obu_temporal_delimiter 2
  @obu_padding 15

  test "parse/1 and serialize/1" do
    # test vectors are based on AV1 spec

    # random av1 data, not necessarily correct
    obu_payload = <<0, 1, 2, 3, 42, 43, 44>>

    # Parse single OBU: type=3, X=0, S=0
    obu = obu_header(3, 0, 0) <> obu_payload

    parsed_obu =
      %OBU{
        type: 3,
        x: 0,
        s: 0,
        payload: obu_payload
      }

    assert {:ok, parsed_obu, <<>>} == OBU.parse(obu)
    assert obu == OBU.serialize(parsed_obu)

    # Parse single OBU: type=TD, X=1, TID=4, SID=1, S=0. TD must have empty payload
    obu = obu_header(@obu_temporal_delimiter, 1, 0) <> <<4::3, 1::2, 0::3>>

    parsed_obu =
      %OBU{
        type: @obu_temporal_delimiter,
        x: 1,
        s: 0,
        tid: 4,
        sid: 1,
        payload: <<>>
      }

    assert {:ok, parsed_obu, <<>>} == OBU.parse(obu)
    assert obu == OBU.serialize(parsed_obu)

    # Parse AV1 low overhead bitstream: all OBUs must have S=1
    # OBU 1: type=TD, X=0
    obu_1 = obu_header(@obu_temporal_delimiter, 0, 1) <> LEB128.encode(0)

    parsed_obu_1 =
      %OBU{
        type: @obu_temporal_delimiter,
        x: 0,
        s: 1,
        payload: <<>>
      }

    # OBU 2: type=SEQ_HDR, X=1, TID=0, SID=0
    obu_2 =
      obu_header(@obu_sequence_header, 1, 1) <>
        <<0::3, 0::2, 0::3>> <> LEB128.encode(byte_size(obu_payload)) <> obu_payload

    parsed_obu_2 =
      %OBU{
        type: @obu_sequence_header,
        x: 1,
        s: 1,
        tid: 0,
        sid: 0,
        payload: obu_payload
      }

    # OBU 3: type=PAD, X=0
    obu_padding_payload = for _ <- 1..44, into: <<>>, do: <<0>>

    obu_3 =
      obu_header(@obu_padding, 0, 1) <>
        LEB128.encode(byte_size(obu_padding_payload)) <> obu_padding_payload

    parsed_obu_3 =
      %OBU{
        type: @obu_padding,
        x: 0,
        s: 1,
        payload: obu_padding_payload
      }

    av1_bitstream = obu_1 <> obu_2 <> obu_3

    assert {:ok, ^parsed_obu_1, av1_bitstream} = OBU.parse(av1_bitstream)
    assert {:ok, ^parsed_obu_2, av1_bitstream} = OBU.parse(av1_bitstream)
    assert {:ok, ^parsed_obu_3, <<>>} = OBU.parse(av1_bitstream)

    assert obu_1 == OBU.serialize(parsed_obu_1)
    assert obu_2 == OBU.serialize(parsed_obu_2)
    assert obu_3 == OBU.serialize(parsed_obu_3)

    # Errors
    # Empty bitstream
    assert {:error, :invalid_av1_bitstream} == OBU.parse(<<>>)

    # First bit set
    assert {:error, :invalid_av1_bitstream} == OBU.parse(<<1::1, 0::7>>)

    # Last bit of first byte set
    assert {:error, :invalid_av1_bitstream} == OBU.parse(<<0::7, 1::1>>)

    # X set but extension header absent
    assert {:error, :invalid_av1_bitstream} == OBU.parse(obu_header(4, 1, 0))

    # S set but no size
    assert {:error, :invalid_av1_bitstream} == OBU.parse(obu_header(4, 0, 1))

    # S set but invalid LEB128 data
    assert {:error, :invalid_av1_bitstream} == OBU.parse(obu_header(4, 0, 1) <> <<255>>)

    # S set, size valid, but bitstream too short
    assert {:error, :invalid_av1_bitstream} ==
             OBU.parse(obu_header(4, 0, 1) <> LEB128.encode(1234) <> <<9, 9, 7>>)

    # Temporal delimiter with payload
    assert {:error, :invalid_av1_bitstream} ==
             OBU.parse(obu_header(@obu_temporal_delimiter, 0, 0) <> obu_payload)

    # OBU without payload that's neither TD nor padding
    assert {:error, :invalid_av1_bitstream} == OBU.parse(obu_header(10, 0, 0))
  end

  test "disable_dropping_in_decoder_if_applicable/1" do
    # Set op_idc_0 to 0xFFF in a specific case of the sequence header OBU
    seq_profile = 5
    iddpf = 1
    op_idc_0 = 0xABC
    rest = <<3::3, 42, 43, 44>>

    obu_to_modify = %OBU{
      type: @obu_sequence_header,
      x: 0,
      s: 0,
      payload: dummy_sequence_header_obu(seq_profile, iddpf, 0, op_idc_0, 0, rest)
    }

    modified_obu = %OBU{
      type: @obu_sequence_header,
      x: 0,
      s: 0,
      payload: dummy_sequence_header_obu(seq_profile, iddpf, 0, 0xFFF, 0, rest)
    }

    assert obu_to_modify != modified_obu
    assert modified_obu == OBU.disable_dropping_in_decoder_if_applicable(obu_to_modify)

    # Don't touch other OBUa
    obu_to_leave_unchanged = %OBU{
      type: @obu_sequence_header,
      x: 0,
      s: 0,
      payload: dummy_sequence_header_obu(seq_profile, iddpf, 8, op_idc_0, 0, rest)
    }

    assert obu_to_leave_unchanged ==
             OBU.disable_dropping_in_decoder_if_applicable(obu_to_leave_unchanged)

    obu_to_leave_unchanged = %OBU{
      type: @obu_sequence_header,
      x: 0,
      s: 0,
      payload: dummy_sequence_header_obu(seq_profile, iddpf, 0, op_idc_0, 8, rest)
    }

    assert obu_to_leave_unchanged ==
             OBU.disable_dropping_in_decoder_if_applicable(obu_to_leave_unchanged)

    obu_to_leave_unchanged = %OBU{
      type: @obu_temporal_delimiter,
      x: 0,
      s: 0,
      payload: <<>>
    }

    assert obu_to_leave_unchanged ==
             OBU.disable_dropping_in_decoder_if_applicable(obu_to_leave_unchanged)
  end

  defp obu_header(type, x, s), do: <<0::1, type::4, x::1, s::1, 0::1>>

  defp dummy_sequence_header_obu(
         seq_profile,
         iddpf,
         op_cnt_minus_1,
         op_idc_0,
         seq_level_idx_0,
         rest
       ) do
    # still_picture=0, reduced_still_picture_header=0 (always 0 for video)
    # timing_info_present_flag=0 (SEQ_HDR OBU has simpler structure without timing info)
    <<seq_profile::3, 0::3, iddpf::1, op_cnt_minus_1::5, op_idc_0::12, seq_level_idx_0::5,
      rest::bitstring>>
  end
end
