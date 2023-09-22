Mix.install([{:gun, "~> 2.0.1"}, {:ex_webrtc, path: "./", force: true}, {:jason, "~> 1.4.0"}])

require Logger
Logger.configure(level: :info)

defmodule Peer do
  use GenServer

  require Logger

  alias ExWebRTC.{PeerConnection, SessionDescription}

  @ice_servers [
    %{urls: "stun:stun.stunprotocol.org:3478"},
    %{urls: "stun:stun.l.google.com:19302"}
  ]

  def start_link() do
    GenServer.start_link(__MODULE__, [])
  end

  @impl true
  def init(_) do
    {:ok, conn} = :gun.open({127, 0, 0, 1}, 4000)
    {:ok, _protocol} = :gun.await_up(conn)
    :gun.ws_upgrade(conn, "/websocket")

    receive do
      {:gun_upgrade, ^conn, stream, _, _} ->
        Logger.info("Connected to the signalling server")
        Process.send_after(self(), :ws_ping, 1000)

        {:ok, pc} = PeerConnection.start_link(
          bundle_policy: :max_bundle,
          ice_servers: @ice_servers
        )

        {:ok, %{conn: conn, stream: stream, peer_connection: pc}}

      other ->
        Logger.error("Couldn't connect to the signalling server: #{inspect(other)}")
        exit(:error)
    end
  end

  @impl true
  def handle_info({:gun_down, _, :ws, :closed, _}, state) do
    Logger.info("Server closed ws connection. Exiting")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:ws_ping, state) do
    Process.send_after(self(), :ws_ping, 1000)
    :gun.ws_send(state.conn, state.stream, :ping)
    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_ws, _, _, {:text, msg}}, state) do
    msg
    |> Jason.decode!()
    |> handle_ws_message(state.peer_connection)

    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_ws, _, _, {:close, code}}, _state) do
    Logger.info("Signalling connection closed with code: #{code}. Exiting")
    exit(:ws_down)
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Received unknown msg: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_ws_message(%{type: "offer", data: data}, pc) do
    Logger.info("Received SDP offer: #{data}")
    {:ok, desc} = SessionDescription.from_init(data)
    PeerConnection.addRemoteDescription(desc)
  end

  defp handle_ws_message(%{type: "ice", data: data}, pc) do
    Logger.info("Received remote ICE candidate: #{data}")
  end

  defp handle_ws_message(msg, _pc) do
    Logger.info("Received unexpected message: #{inspect(msg)}")
  end
end

{:ok, pid} = Peer.start_link()
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, _, _, _} ->
    Logger.info("Peer process closed. Exiting")

  other ->
    Logger.warning("Unexpected msg. Exiting. Msg: #{inspect(other)}")
end
