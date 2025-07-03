defmodule ExWebRTC.RTP.Payloader.AV1 do
  @moduledoc false
  # Encapsulates AV1 video temporal units into RTP packets.
  #
  # Resources:
  # * [RTP Payload Format for AV1 (av1-rtp-spec)](https://aomediacodec.github.io/av1-rtp-spec/v1.0.0.html)
  # * [AV1 spec](https://aomediacodec.github.io/av1-spec/av1-spec.pdf).
  # * https://norkin.org/research/av1_decoder_model/index.html
  # * https://chromium.googlesource.com/external/webrtc/+/HEAD/modules/rtp_rtcp/source/video_rtp_depacketizer_av1.cc

  @behaviour ExWebRTC.RTP.Payloader.Behaviour

  alias ExWebRTC.RTP.AV1.{OBU, Payload}
  alias ExWebRTC.Utils

  @obu_sequence_header 1
  @obu_temporal_delimiter 2

  @aggregation_header_size_bytes 1

  @type t :: %__MODULE__{
          max_payload_size: non_neg_integer()
        }

  @enforce_keys [:max_payload_size]
  defstruct @enforce_keys

  @impl true
  def new(max_payload_size) when max_payload_size > 100 do
    %__MODULE__{max_payload_size: max_payload_size}
  end

  @impl true
  def payload(payloader, temporal_unit) when temporal_unit != <<>> do
    # In AV1, a temporal unit consists of all OBUs associated with a specific time instant.
    # Temporal units always start with a temporal delimiter OBU. They may contain multiple AV1 frames.
    #   av1-rtp-spec sec. 5: The temporal delimiter OBU should be removed when transmitting.
    obus =
      case parse_obus(temporal_unit) do
        [%OBU{type: @obu_temporal_delimiter} | next_obus] ->
          next_obus

        _ ->
          raise "Invalid AV1 temporal unit: does not start with temporal delimiter OBU"
      end

    # With the current implementation, each RTP packet will contain one OBU element.
    # This element can be an entire OBU, or a fragment of an OBU bigger than max_payload_size.
    rtp_packets =
      Stream.flat_map(obus, fn obu ->
        n_bit = Utils.to_int(obu.type == @obu_sequence_header)

        obu
        |> OBU.disable_dropping_in_decoder_if_applicable()
        |> OBU.serialize()
        |> Utils.chunk(payloader.max_payload_size - @aggregation_header_size_bytes)
        |> Payload.payload_obu_fragments(n_bit)
      end)
      |> Stream.map(&Payload.serialize/1)
      |> Enum.map(&ExRTP.Packet.new/1)
      |> List.update_at(-1, &%{&1 | marker: true})

    {rtp_packets, payloader}
  end

  defp parse_obus(data, obus \\ [])
  defp parse_obus(<<>>, obus), do: Enum.reverse(obus)

  defp parse_obus(data, obus) do
    case OBU.parse(data) do
      {:ok, obu, rest} ->
        parse_obus(rest, [obu | obus])

      {:error, :invalid_av1_bitstream} ->
        raise "Invalid AV1 bitstream: unable to parse OBU"
    end
  end
end
