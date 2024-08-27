defmodule ExWebRTC.SCTPTransport do
  @moduledoc false

  require Logger

  alias __MODULE__.DCEP
  alias ExWebRTC.DataChannel

  @dcep_ppi 50

  @opaque t() :: map()

  @type event() ::
          {:transmit, binary()}
          | {:data, DataChannel.ref(), binary()}
          | {:channel, DataChannel.t()}
          | {:state_change, DataChannel.ref(), DataChannel.ready_state()}

  @spec new() :: t()
  def new do
    %{
      ref: ExSCTP.new(),
      connected: false,
      id_type: nil,
      timer: nil,
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
  def set_role(%{id_type: t} = sctp_transport, _type) when t != nil, do: sctp_transport
  def set_role(sctp_transport, :active), do: %{sctp_transport | id_type: :even}
  def set_role(sctp_transport, :passive), do: %{sctp_transport | id_type: :odd}

  @spec data_channels?(t()) :: boolean()
  def data_channels?(sctp_transport) do
    sctp_transport.channels != %{}
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
      ref: make_ref(),
      id: nil,
      label: label,
      ordered: ordered,
      protocol: protocol,
      ready_state: :connecting,
      max_packet_life_time: lifetime,
      max_retransmits: max_rtx
    }

    channels = Map.put(sctp_transport.channels, channel.ref, channel)
    sctp_transport = %{sctp_transport | channels: channels}

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

  @spec send(t(), DataChannel.ref(), :string | :binary, binary()) :: {[event()], t()}
  def send(sctp_transport, ref, type, data) do
    {ppi, data} = to_raw_data(data, type)

    case Map.fetch(sctp_transport.channels, ref) do
      {:ok, %DataChannel{ready_state: :open, id: id}} when id != nil ->
        :ok = ExSCTP.send(sctp_transport.ref, id, ppi, data)
        handle_events(sctp_transport)

      {:ok, %DataChannel{id: id}} ->
        Logger.warning(
          "Trying to send data over DataChannel with id #{id} that is not opened yet"
        )

        {[], sctp_transport}

      :error ->
        Logger.warning("Trying to send data over non-existing DataChannel with ref #{ref}")
        {[], sctp_transport}
    end
  end

  @spec handle_timeout(t()) :: {[event()], t()}
  def handle_timeout(sctp_transport) do
    ExSCTP.handle_timeout(sctp_transport.ref)
    handle_events(sctp_transport)
  end

  @spec handle_data(t(), binary()) :: {[event()], t()}
  def handle_data(sctp_transport, data) do
    :ok = ExSCTP.handle_data(sctp_transport.ref, data)
    handle_events(sctp_transport)
  end

  defp handle_pending_channels(sctp_transport) do
    sctp_transport.channels
    |> Map.values()
    |> Enum.filter(fn channel -> channel.id == nil end)
    |> Enum.reduce(sctp_transport, fn channel, transport ->
      handle_pending_channel(transport, channel)
    end)
  end

  defp handle_pending_channel(sctp_transport, channel) do
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

    channel = %DataChannel{channel | id: id}
    %{sctp_transport | channels: Map.replace!(sctp_transport.channels, channel.ref, channel)}
  end

  defp handle_events(sctp_transport, events \\ []) do
    event = ExSCTP.poll(sctp_transport.ref)

    case handle_event(sctp_transport, event) do
      {:none, transport} -> {Enum.reverse(events), transport}
      {nil, transport} -> handle_events(transport, events)
      {other, transport} -> handle_events(transport, [other | events])
    end
  end

  # if SCTP disconnected, most likely DTLS disconnected, so we won't handle this here explcitly
  defp handle_event(sctp_transport, :disconnected), do: {nil, sctp_transport}
  defp handle_event(sctp_transport, :none), do: {:none, sctp_transport}
  defp handle_event(sctp_transport, {:transmit, _data} = event), do: {event, sctp_transport}

  defp handle_event(sctp_transport, {:stream_opened, id}) do
    Logger.debug("SCTP stream #{id} has been opened")
    {nil, sctp_transport}
  end

  defp handle_event(sctp_transport, {:stream_closed, _id}) do
    # TODO: handle closing channels
    {nil, sctp_transport}
  end

  defp handle_event(sctp_transport, :connected) do
    Logger.debug("SCTP connection has been established")

    sctp_transport =
      %{sctp_transport | connected: true}
      |> handle_pending_channels()

    {nil, sctp_transport}
  end

  defp handle_event(sctp_transport, {:timeout, val}) do
    # TODO: this seems to work
    # but sometimes the data is send after quite a substensial timeout
    # calling `handle_timeout` periodically (i.e. every 50s) seems to work better
    # which is wierd, to investigate
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
        Logger.warning("Received invalid DCEP message. Closing the stream with id #{id}")
        {nil, sctp_transport}
    end
  end

  defp handle_event(sctp_transport, {:data, id, ppi, data}) do
    with {:ok, data} <- from_raw_data(data, ppi),
         {ref, %DataChannel{ready_state: :open}} <-
           Enum.find(sctp_transport.channels, fn {_k, v} -> v.id == id end) do
      {{:data, ref, data}, sctp_transport}
    else
      {_ref, %DataChannel{}} ->
        Logger.warning("Received data on DataChannel with id #{id} that is not open. Discarding")
        {nil, sctp_transport}

      nil ->
        Logger.warning(
          "Received data over non-existing DataChannel on stream with id #{id}. Discarding"
        )

        {nil, sctp_transport}

      _other ->
        Logger.warning("Received data in invalid format on stream with id #{id}. Discarding")
        {nil, sctp_transport}
    end
  end

  defp handle_dcep(sctp_transport, id, %DCEP.DataChannelOpen{} = dco) do
    with false <- Enum.any?(sctp_transport.channels, fn {_k, v} -> v.id == id end),
         true <- valid_id?(sctp_transport, id) do
      :ok = ExSCTP.send(sctp_transport.ref, id, @dcep_ppi, DCEP.encode(%DCEP.DataChannelAck{}))

      Logger.debug("Remote opened DataChannel #{id} succesfully")

      channel = %DataChannel{
        ref: make_ref(),
        id: id,
        label: dco.label,
        ordered: dco.order == :ordered,
        protocol: dco.protocol,
        ready_state: :open,
        max_packet_life_time: if(dco.reliability == :timed, do: dco.param, else: nil),
        max_retransmits: if(dco.reliability == :rexmit, do: dco.param, else: nil)
      }

      # In theory, we should also send the :open event here (W3C 6.2.3)
      channels = Map.put(sctp_transport.channels, channel.ref, channel)
      {:ok, %{sctp_transport | channels: channels}, {:channel, channel}}
    else
      _other -> :error
    end
  end

  defp handle_dcep(sctp_transport, id, %DCEP.DataChannelAck{}) do
    case Enum.find(sctp_transport.channels, fn {_k, v} -> v.id == id end) do
      {ref, %DataChannel{ready_state: :connecting} = channel} ->
        Logger.debug("Locally opened DataChannel #{id} has been negotiated succesfully")
        # TODO: set the parameters
        channel = %DataChannel{channel | ready_state: :open}
        channels = Map.put(sctp_transport.channels, ref, channel)
        event = {:state_change, ref, :open}

        {:ok, %{sctp_transport | channels: channels}, event}

      _other ->
        # TODO: close the channel
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

  defp new_id(sctp_transport) do
    max_id =
      sctp_transport.channels
      |> Enum.filter(fn {_k, v} -> v.id != nil end)
      |> Enum.map(fn {_k, v} -> v.id end)
      |> Enum.max(&>=/2, fn -> -1 end)

    case {sctp_transport.id_type, rem(max_id, 2)} do
      {:even, -1} -> 0
      {:odd, -1} -> 1
      {:even, 0} -> max_id + 2
      {:even, 1} -> max_id + 1
      {:odd, 0} -> max_id + 1
      {:odd, 1} -> max_id + 2
    end
  end
end
