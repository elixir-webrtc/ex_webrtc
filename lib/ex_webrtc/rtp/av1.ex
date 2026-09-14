defmodule ExWebRTC.RTP.AV1 do
  @moduledoc """
  Utilities for RTP packets carrying AV1 encoded payload.
  """

  alias ExRTP.Packet
  alias ExWebRTC.RTP.AV1

  @obu_frame 6
  @obu_sequence_header 1
  @obu_temporal_delimiter 2

  @doc """
  Checks whether RTP payload contains an AV1 keyframe.

  According to the [AV1 RTP spec](https://aomediacodec.github.io/av1-rtp-spec/v1.0.0.html) §4.4,
  the RTP aggregation header's N bit marks the start of a new coded video sequence (CVS).
  A CVS must contain a sequence header and the first frame must be a KEY_FRAME as defined
  by ISO/IEC 23094-1 §6.8:
  - `show_existing_frame` = 0 (a new frame, not a reference reuse)
  - `frame_type` = KEY_FRAME (0)
  - `show_frame` = 1 (displayed frame)

  Some encoders repeat sequence headers in non-key frames, therefore the
  presence of a sequence header alone is not considered sufficient for keyframe
  detection.
  """
  @spec keyframe?(Packet.t()) :: boolean()
  def keyframe?(%Packet{payload: rtp_payload}) do
    # Parse the AV1 RTP payload
    # First check N bit (primary indicator per AV1 RTP spec)
    # Then fall back to checking for sequence header or frame OBU content
    case AV1.Payload.parse(rtp_payload) do
      {:ok, av1_payload} ->
        # N bit = 1 indicates new coded video sequence (keyframe with sequence header)
        # Per AV1 RTP spec §4.4:
        # - Z bit: first OBU is continuation from previous packet
        # - Y bit: last OBU will continue in next packet
        # - W bits: number of OBU elements (0=use length fields, 1-3=count)
        # 
        # For keyframe detection:
        # - If N=1, it's definitely a keyframe
        # - If Z=0 (not a continuation), check for sequence header or KEY_FRAME
        # - If Z=1 (continuation), we can't reliably detect keyframe from this packet
        av1_payload.n == 1 or
          (av1_payload.z == 0 and check_keyframe_in_payload(av1_payload.payload))

      {:error, _reason} ->
        false
    end
  end

  # Check keyframe using Z/Y bits for fragmentation (AV1 RTP spec compliant)
  # Z=0 means this packet starts with the beginning of an OBU (not a continuation)
  # W indicates OBU element count: 0=length-prefixed, 1-3=that many OBUs
  defp check_keyframe_in_payload(obu_data) do
    has_keyframe?(obu_data)
  end

  # Scan through OBUs looking for sequence headers (for CVS resets) and keyframes
  defp has_keyframe?(<<>>), do: false

  defp has_keyframe?(obu_data) do
    case AV1.OBU.parse(obu_data) do
      {:ok, obu, rest} ->
        cond do
          obu.type == @obu_sequence_header ->
            has_keyframe?(rest)

          obu.type == @obu_frame ->
            is_keyframe_frame_obu?(obu) or has_keyframe?(rest)

          obu.type == @obu_temporal_delimiter ->
            has_keyframe?(rest)

          true ->
            has_keyframe?(rest)
        end

      {:error, _reason} ->
        # Try partial frame header check as last resort
        check_partial_frame_header(obu_data)
    end
  end

  defp is_keyframe_frame_obu?(%AV1.OBU{type: @obu_frame, payload: payload}) do
    keyframe_frame_payload?(payload)
  end

  defp is_keyframe_frame_obu?(_obu), do: false

  defp keyframe_frame_payload?(payload) do
    case payload do
      <<0::1, frame_type::2, 1::1, _rest::bitstring>> -> frame_type == 0
      _ -> false
    end
  end

  defp check_partial_frame_header(obu_data) do
    obu_data
    |> candidate_partial_obus()
    |> Enum.any?(&keyframe_from_partial_obu?/1)
  end

  defp candidate_partial_obus(obu_data) do
    [obu_data | maybe_strip_length_prefix(obu_data)]
  end

  defp maybe_strip_length_prefix(obu_data) do
    case AV1.LEB128.read(obu_data) do
      {:ok, leb_size, _value} when byte_size(obu_data) > leb_size ->
        rest_size = byte_size(obu_data) - leb_size
        [binary_part(obu_data, leb_size, rest_size)]

      _ ->
        []
    end
  rescue
    ArgumentError ->
      []
  end

  defp keyframe_from_partial_obu?(<<0::1, type::4, x::1, s::1, 0::1, rest::binary>>) do
    if type == @obu_frame do
      with {:ok, payload_with_metadata} <- drop_extension(rest, x),
           {:ok, payload} <- slice_payload(payload_with_metadata, s) do
        keyframe_frame_payload?(payload)
      else
        _ -> false
      end
    else
      false
    end
  end

  defp keyframe_from_partial_obu?(_), do: false

  defp drop_extension(rest, 0), do: {:ok, rest}

  defp drop_extension(rest, 1) do
    case rest do
      <<_tid::3, _sid::2, 0::3, tail::binary>> -> {:ok, tail}
      _ -> :error
    end
  end

  defp slice_payload(rest, 0), do: {:ok, rest}

  defp slice_payload(rest, 1) do
    case AV1.LEB128.read(rest) do
      {:ok, leb_size, payload_size} when byte_size(rest) >= leb_size ->
        payload_and_rest = binary_part(rest, leb_size, byte_size(rest) - leb_size)
        take_size = min(payload_size, byte_size(payload_and_rest))

        {:ok,
         if take_size == byte_size(payload_and_rest) do
           payload_and_rest
         else
           binary_part(payload_and_rest, 0, take_size)
         end}

      _ ->
        :error
    end
  rescue
    ArgumentError ->
      :error
  end
end
