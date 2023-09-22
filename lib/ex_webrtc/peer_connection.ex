defmodule ExWebRTC.PeerConnection do
  @moduledoc false

  use GenServer

  alias __MODULE__.Configuration
  alias ExWebRTC.SessionDescription

  @type peer_connection() :: GenServer.server()

  @type offer_options() :: [ice_restart: boolean()]
  @type answer_options() :: []

  @enforce_keys [:config]
  defstruct @enforce_keys ++
              [
                :current_local_desc,
                :pending_local_desc,
                :current_remote_desc,
                :pending_remote_desc,
                :ice_agent,
                transceivers: [],
                signaling_state: :stable
              ]

  #### API ####

  def start_link(configuration \\ []) do
    GenServer.start_link(__MODULE__, configuration)
  end

  def start(configuration \\ []) do
    GenServer.start(__MODULE__, configuration)
  end

  @spec create_offer(peer_connection(), offer_options()) ::
          {:ok, SessionDescription.t()} | {:error, :TODO}
  def create_offer(peer_connection, options \\ []) do
    GenServer.call(peer_connection, {:create_offer, options})
  end

  @spec create_answer(peer_connection(), answer_options()) ::
          {:ok, SessionDescription.t()} | {:error, :TODO}
  def create_answer(peer_connection, options \\ []) do
    GenServer.call(peer_connection, {:create_answer, options})
  end

  @spec set_local_description(peer_connection(), SessionDescription.t()) ::
          :ok | {:error, :TODO}
  def set_local_description(peer_connection, description) do
    GenServer.call(peer_connection, {:set_local_description, description})
  end

  @spec set_remote_description(peer_connection(), SessionDescription.t()) ::
          :ok | {:error, :TODO}
  def set_remote_description(peer_connection, description) do
    GenServer.call(peer_connection, {:set_remote_description, description})
  end

  #### CALLBACKS ####

  @impl true
  def init(config) do
    config = struct(Configuration, config)
    :ok = Configuration.check_support(config)

    state = %__MODULE__{config: config}

    {:ok, state}
  end

  @impl true
  def handle_call({:create_offer, options}, _from, state) do
    _ice_restart = Keyword.get(options, :ice_restart, false)

    # TODO probably will need to move SDP stuff to its module
    sdp =
      %{ExSDP.new() | timing: %ExSDP.Timing{start_time: 0, stop_time: 0}}
      |> ExSDP.add_attribute({:ice_options, "trickle"})

    sdp = Enum.reduce(state.transceivers, sdp, &add_media_description/2)

    desc = %SessionDescription{type: :offer, sdp: to_string(sdp)}
    {:reply, {:ok, desc}, state}
  end

  @impl true
  def handle_call({:create_answer, _options}, _from, state) do
    # TODO
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_local_description, _desc}, _from, state) do
    # TODO
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_remote_description, _desc}, _from, state) do
    # TODO
    {:reply, :ok, state}
  end

  defp add_media_description(_transceiver, sdp) do
    # TODO
    sdp
  end
end
