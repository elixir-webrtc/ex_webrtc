defmodule ExWebRTC.SCTPTransport do
  @moduledoc false

  require Logger

  alias __MODULE__.DCEP
  alias ExWebRTC.DataChannel

  @dcep_ppi 50

  @opaque t() :: map()

  @type event() ::
          {:transmit, binary()}
          | {:data, DataChannel.id(), binary()}
          | {:channel_opened, DataChannel.t()}

  @spec new() :: t()
  def new do
    %{
      ref: ExSCTP.new(),
      connected: false,
      id_type: nil,
      timer: nil,
      pending_channels: [],
      channels: %{}
    }
  end

  @spec connect(t()) :: {[event()], t()}
  def connect(%{connected: true} = sctp_transport), do: {[], sctp_transport}

  def connect(sctp_transport) do
    :ok = ExSCTP.connect(sctp_transport.ref)
    handle_events(sctp_transport)
  end

  @spec set_role(t(), :active | :passive) :: t()
  def set_role(sctp_transport, :active), do: %{sctp_transport | id_type: :even}
  def set_role(sctp_transport, :passive), do: %{sctp_transport | id_type: :odd}

  @spec data_channels?(t()) :: boolean()
  def data_channels?(sctp_transport) do
    not (Enum.empty?(sctp_transport.channels) and Enum.empty?(sctp_transport.pending_channels))
  end

  @spec add_channel(
          t(),
          String.t(),
          boolean(),
          String.t(),
          non_neg_integer() | nil,
          non_neg_integer() | nil
        ) ::
          {[event()], DataChannel.t(), t()}
  def add_channel(sctp_transport, label, ordered, protocol, lifetime, max_rtx) do
    channel = %DataChannel{
      id: nil,
      label: label,
      ordered: ordered,
      protocol: protocol,
      ready_state: :connecting,
      max_packet_life_time: lifetime,
      max_retransmits: max_rtx
    }

    channels = [channel | sctp_transport.pending_channels]
    sctp_transport = %{sctp_transport | pending_channels: channels}

    {events, sctp_transport} =
      if sctp_transport.connected do
        sctp_transport = handle_pending_channels(sctp_transport)
        handle_events(sctp_transport)
      else
        {[], sctp_transport}
      end

    {events, channel, sctp_transport}
  end

  # TODO: close channel

  @spec send(t(), DataChannel.id(), :string | :binary, binary()) :: {[event()], t()}
  def send(sctp_transport, id, type, data) do
    {ppi, data} = to_raw_data(data, type)

    case Map.fetch(sctp_transport.channels, id) do
      {:ok, %DataChannel{ready_state: :open}} ->
        :ok = ExSCTP.send(sctp_transport.ref, id, ppi, data)
        handle_events(sctp_transport)

      {:ok, _other} ->
        Logger.warning(
          "Trying to send data over DataChannel with id #{id} that is not opened yet"
        )

        {[], sctp_transport}

      :error ->
        Logger.warning("Trying to send data over non-existing DataChannel with id #{id}")
        {[], sctp_transport}
    end
  end

  @spec handle_timeout(t()) :: {[event()], t()}
  def handle_timeout(sctp_transport) do
    :ok = ExSCTP.handle_timeout(sctp_transport.ref)
    handle_events(sctp_transport)
  end

  @spec handle_data(t(), binary()) :: {[event()], t()}
  def handle_data(sctp_transport, data) do
    :ok = ExSCTP.handle_data(sctp_transport.ref, data)
    handle_events(sctp_transport)
  end

  defp handle_pending_channels(%{pending_channels: []} = sctp_transport) do
    sctp_transport
  end

  defp handle_pending_channels(%{pending_channels: [channel | rest]} = sctp_transport) do
    id = new_id(sctp_transport)
    :ok = ExSCTP.open_stream(sctp_transport.ref, id)

    {reliability, param} =
      cond do
        channel.max_packet_life_time != nil -> {:timed, channel.max_packet_life_time}
        channel.max_retransmits != nil -> {:rexmit, channel.max_retransmits}
        true -> {:reliable, 0}
      end

    dco = %DCEP.DataChannelOpen{
      reliability: reliability,
      order: if(channel.ordered, do: :ordered, else: :unordered),
      label: channel.label,
      protocol: channel.protocol,
      param: param,
      priority: 0
    }

    :ok = ExSCTP.send(sctp_transport.ref, id, @dcep_ppi, DCEP.encode(dco))

    channels = Map.put(sctp_transport.channels, id, channel)
    handle_pending_channels(%{sctp_transport | pending_channels: rest, channels: channels})
  end

  defp handle_events(sctp_transport, events \\ []) do
    event = ExSCTP.poll(sctp_transport.ref)

    case handle_event(sctp_transport, event) do
      {:none, sctp_transport} -> {Enum.reverse(events), sctp_transport}
      {nil, sctp_transport} -> handle_events(sctp_transport, events)
      {other, sctp_transport} -> handle_events(sctp_transport, [other | events])
    end
  end

  # if SCTP disconnected, most likely DTLS disconnected, so we won't handle this here explcitly
  defp handle_event(sctp_transport, :disconnected), do: {nil, sctp_transport}
  defp handle_event(sctp_transport, :none), do: {:none, sctp_transport}
  defp handle_event(sctp_transport, {:transmit, _data} = event), do: {event, sctp_transport}

  defp handle_event(sctp_transport, {:stream_closed, _id}) do
    # TODO
    {nil, sctp_transport}
  end

  defp handle_event(sctp_transport, :connected) do
    Logger.debug("SCTP connection has been established")

    sctp_transport =
      %{sctp_transport | connected: true}
      |> handle_pending_channels()

    {nil, sctp_transport}
  end

  defp handle_event(sctp_transport, {:stream_opened, id}) do
    Logger.debug("SCTP stream #{id} has been opened")

    channels = Map.put(sctp_transport.channels, id, nil)
    {nil, %{sctp_transport | channels: channels}}
  end

  defp handle_event(sctp_transport, {:timeout, val}) do
    if sctp_transport.timer != nil do
      Process.cancel_timer(sctp_transport.timer)
    end

    timer =
      case val do
        nil -> nil
        ms -> Process.send_after(self(), :sctp_timeout, ms)
      end

    {nil, %{sctp_transport | timer: timer}}
  end

  defp handle_event(sctp_transport, {:data, id, @dcep_ppi, data}) do
    with {:ok, dcep} <- DCEP.decode(data),
         {:ok, sctp_transport, event} <- handle_dcep(sctp_transport, id, dcep) do
      {event, sctp_transport}
    else
      :error ->
        # TODO: close the channel
        Logger.warning("Received invalid DECP message. Closing the stream with id #{id}")
        {nil, sctp_transport}
    end
  end

  defp handle_event(sctp_transport, {:data, id, ppi, data}) do
    with {:ok, data} <- from_raw_data(data, ppi),
         {:ok, %DataChannel{ready_state: :open}} <- Map.fetch(sctp_transport.channels, id) do
      {{:data, id, data}, sctp_transport}
    else
      {:ok, %DataChannel{}} ->
        Logger.warning("Received data on DataChannel with id #{id} that is not open. Discarding")
        {nil, sctp_transport}

      _other ->
        Logger.warning(
          "Received data over non-existing DataChannel on stream with id #{id}. Discarding"
        )

        {nil, sctp_transport}
    end
  end

  defp handle_dcep(sctp_transport, id, %DCEP.DataChannelOpen{} = dco) do
    with {:ok, nil} <- Map.fetch(sctp_transport.channels, id),
         true <- valid_id?(sctp_transport, id) do
      :ok = ExSCTP.send(sctp_transport.ref, id, @dcep_ppi, DCEP.encode(%DCEP.DataChannelAck{}))

      Logger.info("Remote opened DataChannel #{id} succesfull")

      channel = %DataChannel{
        id: id,
        label: dco.label,
        ordered: dco.order == :ordered,
        protocol: dco.protocol,
        ready_state: :open,
        max_packet_life_time: if(dco.reliability == :timed, do: dco.param, else: nil),
        max_retransmits: if(dco.reliability == :rexmit, do: dco.param, else: nil)
      }

      # In theory, we should also send the :open event here (W3C 6.2.3)
      channels = Map.put(sctp_transport.channels, id, channel)

      {:ok, %{sctp_transport | channels: channels}, {:channel_opened, channel}}
    else
      _other -> :error
    end
  end

  defp handle_dcep(sctp_transport, id, %DCEP.DataChannelAck{}) do
    case Map.fetch(sctp_transport.channels, id) do
      {:ok, %DataChannel{} = channel} ->
        Logger.info("Locally opened DataChannel #{id} has been negotiated succesfully")
        # TODO: set the parameters
        # TODO: fire event that channel is open
        channels =
          Map.put(sctp_transport.channels, id, %DataChannel{channel | ready_state: :open})

        {:ok, %{sctp_transport | channels: channels}, nil}

      _other ->
        # TODO: should we close there?
        Logger.warning("Received DCEP Ack without sending the DCEP Open message on stream #{id}")
        {:ok, sctp_transport, nil}
    end
  end

  defp from_raw_data(data, ppi) when ppi in [51, 53], do: {:ok, data}
  defp from_raw_data(_data, ppi) when ppi in [56, 57], do: {:ok, <<>>}
  defp from_raw_data(_data, _ppi), do: :error

  defp to_raw_data(<<>>, :string), do: {56, <<0>>}
  defp to_raw_data(data, :string), do: {51, data}
  defp to_raw_data(<<>>, :binary), do: {57, <<0>>}
  defp to_raw_data(data, :binary), do: {53, data}

  # for remote ids (so must be opposite than ours)
  defp valid_id?(%{id_type: :even}, id), do: rem(id, 2) == 1
  defp valid_id?(%{id_type: :odd}, id), do: rem(id, 2) == 0

  defp new_id(%{channels: %{}, id_type: :even}), do: 0
  defp new_id(%{channels: %{}, id_type: :odd}), do: 1

  defp new_id(sctp_transport) do
    max_id =
      sctp_transport.channels
      |> Enum.map(fn {_k, v} -> v.id end)
      |> Enum.max()

    case {sctp_transport.id_type, rem(max_id, 2)} do
      {:even, 0} -> max_id + 2
      {:even, 1} -> max_id + 1
      {:odd, 0} -> max_id + 1
      {:odd, 1} -> max_id + 2
    end
  end
end
