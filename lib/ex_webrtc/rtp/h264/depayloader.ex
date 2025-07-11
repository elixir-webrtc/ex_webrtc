defmodule ExWebRTC.RTP.Depayloader.H264 do
  @moduledoc false
  # Extracts H264 NAL Units from RTP packets.
  #
  # Based on [RFC 6184](https://tools.ietf.org/html/rfc6184).
  #
  # Supported types: Single NALU, FU-A, STAP-A.

  @behaviour ExWebRTC.RTP.Depayloader.Behaviour

  require Logger

  alias ExWebRTC.RTP.H264.{FU, NAL, StapA}

  @annexb_prefix <<1::32>>

  @type t() :: %__MODULE__{
          current_timestamp: non_neg_integer() | nil,
          fu_parser_acc: [binary()]
        }

  defstruct current_timestamp: nil, fu_parser_acc: []

  @impl true
  def new() do
    %__MODULE__{}
  end

  @impl true
  def depayload(depayloader, %ExRTP.Packet{payload: <<>>, padding: true}), do: {nil, depayloader}

  def depayload(depayloader, packet) do
    with {:ok, {header, _payload} = nal} <- NAL.Header.parse_unit_header(packet.payload),
         unit_type = NAL.Header.decode_type(header),
         {:ok, {nal, depayloader}} <-
           do_depayload(unit_type, depayloader, packet, nal) do
      {nal, depayloader}
    else
      {:error, reason} ->
        Logger.warning("""
        Couldn't parse payload, reason: #{reason}. \
        Resetting depayloader state. Payload: #{inspect(packet.payload)}.\
        """)

        {nil, %{depayloader | current_timestamp: nil, fu_parser_acc: []}}
    end
  end

  defp do_depayload(:single_nalu, depayloader, packet, {_header, payload}) do
    {:ok,
     {prefix_annexb(payload), %__MODULE__{depayloader | current_timestamp: packet.timestamp}}}
  end

  defp do_depayload(
         :fu_a,
         %{current_timestamp: current_timestamp, fu_parser_acc: fu_parser_acc},
         packet,
         {_header, _payload}
       )
       when fu_parser_acc != [] and current_timestamp != packet.timestamp do
    Logger.warning("""
    received packet with fu-a type payload that is not a start of fragmentation unit with timestamp \
    different than last start and without finishing the previous fu. dropping fu.\
    """)

    {:error, "invalid timestamp inside fu-a"}
  end

  defp do_depayload(
         :fu_a,
         %{fu_parser_acc: fu_parser_acc},
         packet,
         {header, payload}
       ) do
    case FU.parse(payload, fu_parser_acc || []) do
      {:ok, {data, type}} ->
        data = NAL.Header.add_header(data, 0, header.nal_ref_idc, type)

        {:ok,
         {prefix_annexb(data),
          %__MODULE__{current_timestamp: packet.timestamp, fu_parser_acc: []}}}

      {:incomplete, fu} ->
        {:ok, {nil, %__MODULE__{fu_parser_acc: fu, current_timestamp: packet.timestamp}}}

      {:error, _reason} = error ->
        error
    end
  end

  defp do_depayload(:stap_a, depayloader, packet, {_header, payload}) do
    with {:ok, result} <- StapA.parse(payload) do
      nals = result |> Stream.map(&prefix_annexb/1) |> Enum.join()
      {:ok, {nals, %__MODULE__{depayloader | current_timestamp: packet.timestamp}}}
    end
  end

  defp do_depayload(unsupported_type, _depayloader, _packet, _nal) do
    Logger.warning("""
      Received packet with unsupported NAL type: #{unsupported_type}. Supported types are: Single NALU, STAP-A, FU-A. Dropping packet.
    """)

    {:error, "Unsupported nal type #{unsupported_type}"}
  end

  defp prefix_annexb(nal) do
    @annexb_prefix <> nal
  end
end
