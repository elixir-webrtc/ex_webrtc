defmodule ExWebRTC.PeerConnection do
  @moduledoc false

  use GenServer

  alias ExWebRTC.SessionDescription

  @type peer_connection() :: GenServer.server()

  @type bundle_policy() ::
    :balanced
    | :max_compat
    | :max_bundle

  @type configuration() :: [
    bundle_policy: bundle_policy(),
    certificates: term(),
    ice_candidate_pool_size: term(),
    ice_servers: term(),
    ice_transport_policy: term(),
    peer_identity: term(),
    rtcp_mux_policy: term()
  ]

  @type offer_options() :: [ice_restart: boolean()]
  @type answer_options() :: []

  #### API ####

  def start_link(configuration \\ []) do
    GenServer.start_link(__MODULE__, configuration)
  end

  def start(configuration \\ []) do
    GenServer.start(__MODULE__, configuration)
  end

  @spec create_offer(peer_connection(), offer_options()) :: {:ok, SessionDescription.t()} | {:error, :TODO}  # TODO reason
  def create_offer(peer_connection, options \\ []) do
    GenServer.call(peer_connection, {:create_offer, options})
  end

  @spec create_answer(peer_connection(), answer_options()) :: {:ok, SessionDescription.t()} | {:error, :TODO}  # TODO reasons
  def create_answer(peer_connection, options \\ []) do
    GenServer.call(peer_connection, {:create_answer, options})
  end

  @spec set_local_description(peer_connection(), SessionDescription.t()) :: :ok | {:error, :TODO}  # TODO resons
  def set_local_description(peer_connection, description) do
    GenServer.call(peer_connection, {:set_local_description, description})
  end

  @spec set_remote_description(peer_connection(), SessionDescription.t()) :: :ok | {:error, :TODO}  # TODO resons
  def set_remote_description(peer_connection, description) do
    GenServer.call(peer_connection, {:set_remote_description, description})
  end

  #### CALLBACKS ####

  @impl true
  def init(config) do
    _bundle_policy = Keyword.get(config, :bundle_policy, :balanced)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create_offer, options}, _from, state) do
    _ice_restart = Keyword.get(options, :ice_restart, false)

    sdp = 
      %{ExSDP.new() | timing: %ExSDP.Timing{start_time: 0, stop_time: 0}}
      |> ExSDP.add_attribute({:ice_options, "trickle"})

    # identity?

    # for each RTPTransceiver add "m=" section

    desc = %SessionDescription{type: :offer, sdp: to_string(sdp)}
    {:reply, {:ok, desc}, state}
  end

  @impl true
  def handle_call({:create_answer, _options}, _from, state) do
    sdp = ExSDP.new()

    desc = %SessionDescription{type: :answer, sdp: to_string(sdp)}
    {:reply, {:ok, desc}, state}
  end

  @impl true
  def handle_call({:set_local_description, _desc}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_remote_description, _desc}, _from, state) do
    {:reply, :ok, state}
  end
end
