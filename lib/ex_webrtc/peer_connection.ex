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
  def handle_call({:create_offer, _options}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:create_answer, _options}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_local_description, desc}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_remote_description, desc}, _from, state) do
    %SessionDescription{type: type, sdp: sdp} = desc

    cond do
      # TODO handle rollback
      type == :rollback ->
        {:reply, :ok, state}

      valid_transition?(:remote, state.signaling_state, type) ->
        with {:ok, sdp} <- ExSDP.parse(sdp),
             {:ok, state} <- apply_remote_description(type, sdp, state) do
          {:reply, :ok, state}
        end

      true ->
        {:reply, :error, state}
    end
  end

  defp apply_remote_description(_type, _sdp, state) do
    {:ok, state}
  end

  defp valid_transition?(_, _, :rollback), do: false

  defp valid_transition?(:remote, state, :offer)
       when state in [:stable, :have_remote_offer],
       do: true

  defp valid_transition?(:remote, state, type)
       when state in [:have_local_offer, :have_remote_pranswer] and type in [:answer, :pranswer],
       do: true

  defp valid_transition?(:remote, _, _), do: false
end
