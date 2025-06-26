defmodule ExWebRTC.RTP.Depayloader.H264 do
  @moduledoc """
  Depayloads H264 RTP payloads into H264 NAL Units.

  Based on [RFC 6184](https://tools.ietf.org/html/rfc6184).

  Supported types: Single NALU, FU-A, STAP-A.
  """
  @behaviour ExWebRTC.RTP.Depayloader.Behaviour

  require Logger

  alias ExWebRTC.RTP.H264.{FU, NAL, StapA}

  @frame_prefix <<1::32>>
  @annexb_prefix <<1::4>>

  defmodule State do
    @moduledoc false
    defstruct parser_acc: nil
  end

  @type t() :: %__MODULE__{
          current_nal: nil,
          current_timestamp: nil
        }

  defstruct [:current_nal, :current_timestamp]

  @impl true
  def new() do
    %__MODULE__{}
  end

  # TODO: handle timestamps
  @impl true
  def depayload(depayloader, packet)

  def depayload(depayloader, %ExRTP.Packet{payload: <<>>, padding: true}), do: {nil, depayloader}

  def depayload(depayloader, packet) do
    with {:ok, {header, _payload} = nal} <- NAL.Header.parse_unit_header(packet.payload),
         unit_type = NAL.Header.decode_type(header),
         {:ok, {nalu, depayloader}} <- handle_unit_type(unit_type, depayloader, packet, nal) do
      {nalu, depayloader}
    else
      {:error, reason} ->
        Logger.warning("""
        Couldn't parse payload, reason: #{reason}. \
        Resetting depayloader state. Payload: #{inspect(packet.payload)}.\
        """)

        {:ok, %{depayloader | current_nal: nil, current_timestamp: nil}}
    end
  end

  defp handle_unit_type(:single_nalu, _depayloader, _packet, nal) do
    {header, payload} = nal
    {:ok, {prefix_annexb(payload), depayloader}}
  end

  defp handle_unit_type(
         :fu_a,
         {current_nal, current_timestamp} = depayloader,
         packet,
         {header, payload} = nal
       ) do
    if current_nal != nil and current_timestamp != packet.timestamp do
      {:error, "fu-a colliding rtp timestamps"}

      Logger.debug("""
      Received packet with timestamp from a new frame that is not a beginning of this frame \
      and without finishing the previous frame. Dropping both.\
      """)
    end

    case FU.parse(payload, current_nal) do
      {:ok, {payload, type}} ->
        {:ok, result}

      {:incomplete, tmp} ->
        {:ok, {nil, %{depayloader | current_nal: curent_nal <> tmp}}}

      {:error, _reason} = error ->
        error
    end
  end

  defp handle_unit_type(:stap_a, depayloader, {_header, data}, buffer, state) do
    with {:ok, result} <- StapA.parse(data) do
      nals = Enum.reduce(result, <<>>, fn nal, acc -> acc <> prefix_annexb(nal) end)
      {:ok, {nals, depayloader}}
    end
  end

  defp prefix_annexb(nal) do
    @annexb_prefix <> nal
  end
end
