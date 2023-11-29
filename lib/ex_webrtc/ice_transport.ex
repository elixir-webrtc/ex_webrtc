defmodule ExWebRTC.ICETransport do
  @moduledoc false

  # module implementing this behaviour
  @type t() :: module()
  @type state() :: :checking | :connected | :completed | :failed

  @callback start_link(ExICE.ICEAgent.role(), Keyword.t()) :: {:ok, pid()}
  @callback on_data(pid(), pid()) :: :ok
  @callback add_remote_candidate(pid(), candidate :: String.t()) :: :ok
  @callback end_of_candidates(pid()) :: :ok
  @callback gather_candidates(pid()) :: :ok
  @callback get_local_credentials(pid()) :: {:ok, ufrag :: binary(), pwd :: binary()}
  @callback restart(pid()) :: :ok
  @callback send_data(pid(), binary()) :: :ok
  @callback set_remote_credentials(pid(), ufrag :: binary(), pwd :: binary()) :: :ok
end

defmodule ExWebRTC.DefaultICETransport do
  @moduledoc false

  @behaviour ExWebRTC.ICETransport

  alias ExICE.ICEAgent

  @impl true
  defdelegate start_link(role, opts), to: ICEAgent
  @impl true
  defdelegate on_data(pid, dst_pid), to: ICEAgent
  @impl true
  defdelegate add_remote_candidate(pid, candidate), to: ICEAgent
  @impl true
  defdelegate end_of_candidates(pid), to: ICEAgent
  @impl true
  defdelegate gather_candidates(pid), to: ICEAgent
  @impl true
  defdelegate get_local_credentials(pid), to: ICEAgent
  @impl true
  defdelegate restart(pid), to: ICEAgent
  @impl true
  defdelegate send_data(pid, data), to: ICEAgent
  @impl true
  defdelegate set_remote_credentials(pid, ufrag, pwd), to: ICEAgent
end
