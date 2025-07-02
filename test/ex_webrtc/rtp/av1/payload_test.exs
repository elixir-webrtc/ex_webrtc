defmodule ExWebRTC.RTP.AV1.PayloadTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTP.AV1.Payload
  alias ExWebRTC.Utils

  test "parse/1 and serialize/1" do
    # test vectors are based on av1-rtp-spec

    # random av1 data, not necessarily correct
    av1_payload = <<0, 1, 2, 3>>

    # Z=0, Y=0, W=1, N=1
    rtp_payload =
      <<0::1, 0::1, 1::2, 1::1, 0::3, av1_payload::binary>>

    parsed_payload =
      %Payload{
        z: 0,
        y: 0,
        w: 1,
        n: 1,
        payload: av1_payload
      }

    assert {:ok, parsed_payload} == Payload.parse(rtp_payload)
    assert rtp_payload == Payload.serialize(parsed_payload)

    # Z=1, Y=0, W=3, N=0
    rtp_payload =
      <<1::1, 0::1, 3::2, 0::1, 0::3, av1_payload::binary>>

    parsed_payload =
      %Payload{
        z: 1,
        y: 0,
        w: 3,
        n: 0,
        payload: av1_payload
      }

    assert {:ok, parsed_payload} == Payload.parse(rtp_payload)
    assert rtp_payload == Payload.serialize(parsed_payload)

    assert {:error, :invalid_packet} = Payload.parse(<<>>)

    # No av1_payload
    assert {:error, :invalid_packet} = Payload.parse(<<1::1, 1::1, 1::2, 0::1, 0::3>>)
  end

  test "payload_obu_fragments/2" do
    obu =
      for i <- 0..9001, into: <<>> do
        <<rem(i, 255)>>
      end

    # Chunk size greater than OBU size, OBU not split
    chunked_obu = Utils.chunk(obu, 10_000)
    assert length(chunked_obu) == 1

    # N=0. Expecting single RTP packet, Z=0, Y=0
    [obu_payload] = Payload.payload_obu_fragments(chunked_obu, 0)

    assert %Payload{
             z: 0,
             y: 0,
             w: 1,
             n: 0,
             payload: ^obu
           } = obu_payload

    # OBU split in two
    chunked_obu = Utils.chunk(obu, 5_000)
    assert length(chunked_obu) == 2

    # N=1. Expecting two RTP packets, first with Z=0, Y=1, N=1, second with Z=1, Y=0, N=0
    [obu_payload_1, obu_payload_2] = Payload.payload_obu_fragments(chunked_obu, 1)

    assert %Payload{
             z: 0,
             y: 1,
             w: 1,
             n: 1,
             payload: obu_chunk_1
           } = obu_payload_1

    assert %Payload{
             z: 1,
             y: 0,
             w: 1,
             n: 0,
             payload: obu_chunk_2
           } = obu_payload_2

    assert obu_chunk_1 <> obu_chunk_2 == obu

    # OBU split into more than two chunks
    chunked_obu = Utils.chunk(obu, 100)
    assert length(chunked_obu) > 2

    # N=0. Expecting the RTP packets in the middle to have Z=1, Y=1
    obu_payloads = Payload.payload_obu_fragments(chunked_obu)
    assert length(chunked_obu) == length(obu_payloads)

    [first_obu_payload | next_obu_payloads] = obu_payloads
    {last_obu_payload, middle_obu_payloads} = List.pop_at(next_obu_payloads, -1)

    assert %Payload{
             z: 0,
             y: 1,
             w: 1,
             n: 0,
             payload: first_obu_chunk
           } = first_obu_payload

    assert %Payload{
             z: 1,
             y: 0,
             w: 1,
             n: 0,
             payload: last_obu_chunk
           } = last_obu_payload

    middle_obu_chunks =
      for payload <- middle_obu_payloads, into: <<>> do
        assert %Payload{
                 z: 1,
                 y: 1,
                 w: 1,
                 n: 0,
                 payload: obu_chunk
               } = payload

        obu_chunk
      end

    assert first_obu_chunk <> middle_obu_chunks <> last_obu_chunk == obu
  end
end
