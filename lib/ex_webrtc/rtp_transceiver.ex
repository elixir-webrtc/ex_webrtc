defmodule ExWebRTC.RTPTransceiver do
  @moduledoc """
  RTPTransceiver
  """

  use GenServer

  alias ExWebRTC.RTPCodecParameters

  @type rtp_transceiver() :: GenServer.server()

  @type direction() :: :sendonly | :recvonly | :sendrecv | :inactive | :stopped
  @type kind() :: :audio | :video

  @type properties() :: %{
          mid: String.t() | nil,
          direction: direction(),
          rtp_hdr_exts: [ExSDP.Attribute.Extmap.t()],
          codecs: [RTPCodecParameters.t()]
        }

  @doc false
  @spec start_link(kind(), properties()) :: GenServer.on_start()
  def start_link(kind, properties) do
    GenServer.start_link(__MODULE__, [kind, properties])
  end

  @doc false
  @spec get_properties(rtp_transceiver()) :: {kind(), properties()}
  def get_properties(transceiver) do
    GenServer.call(transceiver, :get_properties)
  end

  @doc false
  @spec update_properties(rtp_transceiver(), map()) :: :ok
  def update_properties(transceiver, properties) do
    # properties should be a subset of properties() type, but typespecs suck
    GenServer.call(transceiver, {:update_properties, properties})
  end

  @impl true
  def init([kind, props]) do
    state = %{props | kind: kind, receiver: nil, sender: nil}

    {:ok, state}
  end

  @impl true
  def handle_call(:get_properties, _from, state) do
    properties = Map.take(state, [:mid, :direction, :kind, :rtp_hrd_exts, :codecs])
    {:reply, properties, state}
  end

  @impl true
  def handle_call({:update_properties, properties}, _from, state) do
    # TODO: there's more to it that simply overriding the state's values
    state =
      properties
      |> Map.take([:mid, :direction, :rtp_hdr_exts, :codecs])
      |> then(&Map.merge(state, &1))

    {:reply, :ok, state}
  end
end
