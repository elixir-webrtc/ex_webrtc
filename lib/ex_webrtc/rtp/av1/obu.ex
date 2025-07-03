defmodule ExWebRTC.RTP.AV1.OBU do
  @moduledoc false
  # Defines the Open Bitstream Unit, the base packetization unit of all structures present in the AV1 bitstream.
  #
  # Based on [the AV1 spec](https://aomediacodec.github.io/av1-spec/av1-spec.pdf).
  #
  #  OBU syntax:
  #      0 1 2 3 4 5 6 7
  #     +-+-+-+-+-+-+-+-+
  #     |0| type  |X|S|-| (REQUIRED)
  #     +-+-+-+-+-+-+-+-+
  #  X: | TID |SID|-|-|-| (OPTIONAL)
  #     +-+-+-+-+-+-+-+-+
  #     |1|             |
  #     +-+ OBU payload |
  #  S: |1|             | (OPTIONAL, variable length leb128 encoded)
  #     +-+    size     |
  #     |0|             |
  #     +-+-+-+-+-+-+-+-+
  #     |  OBU payload  |
  #     |     ...       |

  alias ExWebRTC.RTP.AV1.LEB128

  @obu_sequence_header 1
  @obu_temporal_delimiter 2
  @obu_padding 15

  @type t :: %__MODULE__{
          type: 0..15,
          x: 0 | 1,
          s: 0 | 1,
          tid: 0..7 | nil,
          sid: 0..3 | nil,
          payload: binary()
        }

  @enforce_keys [:type, :x, :s, :payload]
  defstruct @enforce_keys ++ [:tid, :sid]

  @doc """
  Parses the low overhead bitstream format defined in AV1 spec section 5.2.
  On success, returns the parsed OBU as well as the remainder of the AV1 bitstream.
  """
  @spec parse(binary()) :: {:ok, t(), binary()} | {:error, :invalid_av1_bitstream}
  def parse(av1_bitstream_binary)

  def parse(<<0::1, type::4, x::1, s::1, 0::1, rest::binary>>) do
    with {:ok, tid, sid, rest} <- parse_extension_header(x, rest),
         {:ok, payload, rest} <- parse_payload(s, rest),
         :ok <- validate_payload(type, payload) do
      {:ok,
       %__MODULE__{
         type: type,
         x: x,
         s: s,
         tid: tid,
         sid: sid,
         payload: payload
       }, rest}
    else
      {:error, _} = err -> err
    end
  end

  def parse(_), do: {:error, :invalid_av1_bitstream}

  defp parse_extension_header(0, rest), do: {:ok, nil, nil, rest}

  defp parse_extension_header(1, <<tid::3, sid::2, 0::3, rest::binary>>),
    do: {:ok, tid, sid, rest}

  defp parse_extension_header(_, _), do: {:error, :invalid_av1_bitstream}

  defp parse_payload(0, rest), do: {:ok, rest, <<>>}

  defp parse_payload(1, rest) do
    with {:ok, leb128_size, payload_size} <- LEB128.read(rest),
         <<_::binary-size(leb128_size), payload::binary-size(payload_size), rest::binary>> <- rest do
      {:ok, payload, rest}
    else
      _ -> {:error, :invalid_av1_bitstream}
    end
  end

  defp validate_payload(@obu_padding, _), do: :ok
  defp validate_payload(@obu_temporal_delimiter, <<>>), do: :ok
  defp validate_payload(type, data) when type != @obu_temporal_delimiter and data != <<>>, do: :ok
  defp validate_payload(_, _), do: {:error, :invalid_av1_bitstream}

  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{type: type, x: x, s: s, payload: payload} = obu) do
    obu_binary =
      <<0::1, type::4, x::1, s::1, 0::1>>
      |> add_extension_header(obu)
      |> add_payload_size(obu)

    <<obu_binary::binary, payload::binary>>
  end

  defp add_extension_header(obu_binary, %__MODULE__{x: 0, tid: nil, sid: nil}), do: obu_binary

  defp add_extension_header(obu_binary, %__MODULE__{x: 1, tid: tid, sid: sid})
       when tid != nil and sid != nil do
    <<obu_binary::binary, tid::3, sid::2, 0::3>>
  end

  defp add_extension_header(_obu_binary, _invalid_obu),
    do: raise("AV1 TID and SID must be set if, and only if X bit is set")

  defp add_payload_size(obu_binary, %__MODULE__{s: 0}), do: obu_binary

  defp add_payload_size(obu_binary, %__MODULE__{s: 1, payload: payload}) do
    payload_size = payload |> byte_size() |> LEB128.encode()
    <<obu_binary::binary, payload_size::binary>>
  end

  @doc """
  Rewrites a specific case of the sequence header OBU to disable OBU dropping in the AV1 decoder
  in accordance with av1-rtp-spec sec. 5. Leaves other OBUs unchanged.
  """
  @spec disable_dropping_in_decoder_if_applicable(t()) :: t()
  def disable_dropping_in_decoder_if_applicable(obu)

  # We're handling the following case:
  #   - still_picture = 0
  #   - reduced_still_picture_header = 0
  #   - timing_info_present_flag = 0
  #   - operating_points_cnt_minus_1 = 0
  #   - seq_level_idx[0] = 0
  # and setting operating_point_idc[0] = 0xFFF
  #
  # For the sequence header OBU syntax, refer to the AV1 spec sec. 5.5.
  def disable_dropping_in_decoder_if_applicable(
        %__MODULE__{
          type: @obu_sequence_header,
          payload: <<seq_profile::3, 0::3, iddpf::1, 0::5, _op_idc_0::12, 0::5, rest::bitstring>>
        } = obu
      ) do
    %{obu | payload: <<seq_profile::3, 0::3, iddpf::1, 0::5, 0xFFF::12, 0::5, rest::bitstring>>}
  end

  def disable_dropping_in_decoder_if_applicable(obu), do: obu
end
