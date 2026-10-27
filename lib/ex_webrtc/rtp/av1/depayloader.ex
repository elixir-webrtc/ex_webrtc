defmodule ExWebRTC.RTP.Depayloader.AV1 do
  @moduledoc false
  # Reassembles AV1 video temporal units from RTP packets.
  #
  # Resources:
  # * [RTP Payload Format for AV1 (av1-rtp-spec)](https://aomediacodec.github.io/av1-rtp-spec/v1.0.0.html)
  # * [AV1 spec](https://aomediacodec.github.io/av1-spec/av1-spec.pdf).
  # * https://norkin.org/research/av1_decoder_model/index.html
  # * https://chromium.googlesource.com/external/webrtc/+/HEAD/modules/rtp_rtcp/source/video_rtp_depacketizer_av1.cc

  @behaviour ExWebRTC.RTP.Depayloader.Behaviour

  require Logger

  alias ExWebRTC.RTP.AV1.{OBU, Payload}

  @type t :: %__MODULE__{
          current_temporal_unit: [OBU.t()],
          current_obu: binary() | nil,
          current_timestamp: ExRTP.Packet.uint32() | nil
        }

  defstruct current_temporal_unit: [], current_obu: nil, current_timestamp: nil

  @impl true
  def new do
    %__MODULE__{}
  end

  @impl true
  def depayload(depayloader, packet)

  def depayload(depayloader, %ExRTP.Packet{payload: <<>>, padding: true}), do: {nil, depayloader}

  def depayload(depayloader, packet) do
    case Payload.parse(packet.payload) do
      {:ok, av1_payload} ->
        do_depayload(depayloader, packet, av1_payload)

      {:error, reason} ->
        Logger.warning("""
        Couldn't parse payload, reason: #{reason}. \
        Resetting depayloader state. Payload: #{inspect(packet.payload)}.\
        """)

        {:ok, %__MODULE__{}}
    end
  end

  defp do_depayload(depayloader, packet, %Payload{z: z, y: y} = av1_payload) do
    {obus, current_obu_fragment, next_obu_fragment} =
      av1_payload
      |> Payload.depayload_obu_elements()
      |> parse_obu_elements(z, y)

    # TODO: handle marker, or not (?)
    #         av1-rtp-spec sec. 4.2.: It is possible for a receiver to receive the last packet of a temporal unit
    #         without the marker bit being set equal to 1, and a receiver should be able to handle this case.
    #       at the moment, we're looking at the timestamps only, and it seems to work
    #
    # TODO: handle the case where depayloader.current_timestamp > packet.timestamp
    new_temporal_unit? = depayloader.current_timestamp != packet.timestamp

    {depayloader, obus, next_obu_fragment} =
      depayloader
      |> update_current_obu(current_obu_fragment, new_temporal_unit?)
      |> maybe_flush_current_obu(obus, next_obu_fragment, y)

    if new_temporal_unit? do
      {temporal_unit, depayloader} = flush_temporal_unit(depayloader)

      {temporal_unit,
       update_temporal_unit(depayloader, obus, next_obu_fragment, packet.timestamp)}
    else
      {nil, update_temporal_unit(depayloader, obus, next_obu_fragment, packet.timestamp)}
    end
  end

  defp parse_obu_elements(obu_elements, z, y)

  defp parse_obu_elements([], _, _) do
    # TODO: decide where to use debug logs and where warnings
    Logger.debug("AV1 payload contains no valid OBU elements. Dropping packet.")
    {[], nil, nil}
  end

  defp parse_obu_elements(obus, 0, 0) do
    {obus, nil, nil}
  end

  # Last OBU element is an OBU fragment that will be continued
  defp parse_obu_elements(obu_elements, 0, 1) do
    {next_obu_fragment, obus} = List.pop_at(obu_elements, -1)
    {obus, nil, next_obu_fragment}
  end

  # First OBU element is an OBU fragment, a continuation of the current OBU
  defp parse_obu_elements([current_obu_fragment | obus], 1, 0) do
    {obus, current_obu_fragment, nil}
  end

  # Both. If packet contained exactly 1 OBU fragment, we store it as current_obu_fragment only
  defp parse_obu_elements([current_obu_fragment | obu_elements], 1, 1) do
    {next_obu_fragment, obus} = List.pop_at(obu_elements, -1)
    {obus, current_obu_fragment, next_obu_fragment}
  end

  defp update_current_obu(depayloader, current_obu_fragment, new_temporal_unit?)

  defp update_current_obu(depayloader, current_obu_fragment, true) do
    if depayloader.current_obu != nil do
      Logger.debug(
        "Received packet with timestamp from a new temporal unit without finishing the previous OBU. Dropping previous OBU."
      )
    end

    if current_obu_fragment != nil do
      Logger.debug(
        "Received middle OBU fragment from a new temporal unit without beginning the OBU. Dropping this OBU fragment."
      )
    end

    %{depayloader | current_obu: nil}
  end

  defp update_current_obu(%__MODULE__{current_obu: nil} = depayloader, nil, false) do
    depayloader
  end

  defp update_current_obu(depayloader, nil, false) do
    Logger.debug(
      "Received start of new OBU without finishing the previous OBU. Dropping previous OBU."
    )

    %{depayloader | current_obu: nil}
  end

  defp update_current_obu(%__MODULE__{current_obu: nil} = depayloader, _obu_fragment, false) do
    Logger.debug(
      "Received middle OBU fragment without beginning the OBU. Dropping this OBU fragment."
    )

    depayloader
  end

  defp update_current_obu(%__MODULE__{current_obu: obu} = depayloader, obu_fragment, false) do
    %{depayloader | current_obu: obu <> obu_fragment}
  end

  # current_obu is nil, nothing to flush
  defp maybe_flush_current_obu(
         %__MODULE__{current_obu: nil} = depayloader,
         obus,
         next_obu_fragment,
         _y
       ) do
    {depayloader, obus, next_obu_fragment}
  end

  # Packet contained exactly 1 OBU fragment, current_obu will be continued. Do not flush
  # TODO: make sure `nil` is correct here
  defp maybe_flush_current_obu(%__MODULE__{current_obu: incomplete_obu} = depayloader, [], nil, 1) do
    {depayloader, [], incomplete_obu}
  end

  # Otherwise, flush
  defp maybe_flush_current_obu(
         %__MODULE__{current_obu: obu} = depayloader,
         obus,
         next_obu_fragment,
         _y
       ) do
    {depayloader, [obu | obus], next_obu_fragment}
  end

  defp update_temporal_unit(
         %__MODULE__{current_temporal_unit: tu} = depayloader,
         obus,
         next_obu_fragment,
         timestamp
       ) do
    %{
      depayloader
      | current_obu: next_obu_fragment,
        current_temporal_unit: append_obus(obus, tu),
        current_timestamp: timestamp
    }
  end

  defp flush_temporal_unit(%__MODULE__{current_temporal_unit: tu}) when tu != [] do
    # Force s=1 for the low overhead bitstream format
    tu_binary =
      tu
      |> Stream.map(&%OBU{&1 | s: 1})
      |> Stream.map(&OBU.serialize/1)
      |> Enum.reverse()
      |> :erlang.iolist_to_binary()

    # TODO: is it possible that `current_obu != nil` here?
    {OBU.temporal_delimiter() <> tu_binary, %__MODULE__{}}
  end

  defp flush_temporal_unit(depayloader) do
    Logger.debug("Previous temporal unit is empty, nothing to flush")
    {nil, depayloader}
  end

  defp append_obus([], tu), do: tu

  defp append_obus([obu_binary | rest], tu) do
    with {:ok, obu, rest_of_binary} <- OBU.parse(obu_binary),
         true <- OBU.should_be_transmitted?(obu) do
      if rest_of_binary != <<>>,
        do:
          Logger.debug(
            "OBU binary contains additional data after the decoded OBU, dropping the additional data"
          )

      append_obus(rest, [obu | tu])
    else
      {:error, :invalid_av1_bitstream} ->
        Logger.debug("Unable to parse OBU from binary data, dropping")
        append_obus(rest, tu)

      false ->
        Logger.debug("Dropping temporal delimiter/tile list OBU")
        append_obus(rest, tu)
    end
  end
end
