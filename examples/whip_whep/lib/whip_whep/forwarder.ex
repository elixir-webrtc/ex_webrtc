defmodule WhipWhep.Forwarder do
  use GenServer

  require Logger

  alias WhipWhep.PeerSupervisor
  alias ExWebRTC.PeerConnection

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_arg) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec connect_input(pid()) :: :ok
  def connect_input(pc) do
    GenServer.call(__MODULE__, {:connect_input, pc})
  end

  @spec connect_output(pid()) :: :ok
  def connect_output(pc) do
    GenServer.call(__MODULE__, {:connect_output, pc})
  end

  @impl true
  def init(_arg) do
    state = %{
      input_pc: nil,
      audio_input: nil,
      video_input: nil,
      pending_outputs: [],
      outputs: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:connect_input, pc}, _from, state) do
    if state.input_pc != nil do
      PeerSupervisor.terminate_pc(state.input_pc)
    end

    PeerConnection.controlling_process(pc, self())
    {audio_track_id, video_track_id} = get_tracks(pc, :receiver)

    Logger.info("Successfully added input #{inspect(pc)}")

    state = %{state | input_pc: pc, audio_input: audio_track_id, video_input: video_track_id}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:connect_output, pc}, _from, state) do
    PeerConnection.controlling_process(pc, self())
    pending_outputs = [pc | state.pending_outputs]

    Logger.info("Added new output #{inspect(pc)}")

    {:reply, :ok, %{state | pending_outputs: pending_outputs}}
  end

  @impl true
  def handle_info(
        {:ex_webrtc, pc, {:connection_state_change, :connected}},
        %{input_pc: pc} = state
      ) do
    Logger.info("Input #{inspect(pc)} has successfully connected")
    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_webrtc, pc, {:connection_state_change, :connected}}, state) do
    state =
      if Enum.member?(state.pending_outputs, pc) do
        pending_outputs = List.delete(state.pending_outputs, pc)
        {audio_track_id, video_track_id} = get_tracks(pc, :sender)

        outputs = Map.put(state.outputs, pc, %{audio: audio_track_id, video: video_track_id})

        if state.input_pc != nil do
          :ok = PeerConnection.send_pli(state.input_pc, state.video_input)
        end

        Logger.info("Output #{inspect(pc)} has successfully connected")

        %{state | pending_outputs: pending_outputs, outputs: outputs}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:ex_webrtc, input_pc, {:rtp, id, packet}},
        %{input_pc: input_pc, audio_input: id} = state
      ) do
    for {pc, %{audio: track_id}} <- state.outputs do
      PeerConnection.send_rtp(pc, track_id, packet)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:ex_webrtc, input_pc, {:rtp, id, packet}},
        %{input_pc: input_pc, video_input: id} = state
      ) do
    for {pc, %{video: track_id}} <- state.outputs do
      PeerConnection.send_rtp(pc, track_id, packet)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_webrtc, _pc, {:rtcp, packets}}, state) do
    for packet <- packets do
      case packet do
        %ExRTCP.Packet.PayloadFeedback.PLI{} when state.input_pc != nil ->
          :ok = PeerConnection.send_pli(state.input_pc, state.video_input)

        _other ->
          :ok
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp get_tracks(pc, type) do
    transceivers = PeerConnection.get_transceivers(pc)
    audio_transceiver = Enum.find(transceivers, fn tr -> tr.kind == :audio end)
    video_transceiver = Enum.find(transceivers, fn tr -> tr.kind == :video end)

    audio_track_id = Map.fetch!(audio_transceiver, type).track.id
    video_track_id = Map.fetch!(video_transceiver, type).track.id

    {audio_track_id, video_track_id}
  end
end
