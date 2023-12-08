defmodule ExWebRTC.RTP.LEB128 do
  import Bitwise

  # see https://chromium.googlesource.com/external/webrtc/+/HEAD/modules/rtp_rtcp/source/rtp_packetizer_av1.cc#61
  def encode(value, acc \\ [])

  def encode(value, acc) when value < 0x80 do
    acc = acc ++ [value]

    for group <- acc, into: <<>> do
      <<group>>
    end
  end

  def encode(value, acc) do
    group = 0x80 ||| (value &&& 0x7F)
    acc = acc ++ [group]
    encode(value >>> 7, acc)
  end

  # see https://source.chromium.org/chromium/chromium/src/+/main:third_party/webrtc/rtc_base/byte_buffer.cc;drc=8e78783dc1f7007bad46d657c9f332614e240fd8;l=107
  def read(data, read_bits \\ 0, leb128_size \\ 0, value \\ 0)

  def read(<<0::1, group::7, _rest::binary>>, read_bits, leb128_size, value) do
    {leb128_size + 1, value ||| group <<< read_bits}
  end

  def read(<<1::1, group::7, rest::binary>>, read_bits, leb128_size, value) do
    read(rest, read_bits + 7, leb128_size + 1, value ||| group <<< read_bits)
  end
end
