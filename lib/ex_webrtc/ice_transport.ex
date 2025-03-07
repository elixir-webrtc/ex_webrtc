defmodule ExWebRTC.ICETransport do
  @moduledoc false

  # module implementing this behaviour
  @type t() :: module()
  @type state() :: :checking | :connected | :completed | :failed

  @callback start_link(Keyword.t()) :: {:ok, pid()}
  @callback on_data(pid(), pid()) :: :ok
  @callback add_remote_candidate(pid(), candidate :: String.t()) :: :ok
  @callback end_of_candidates(pid()) :: :ok
  @callback gather_candidates(pid()) :: :ok
  @callback get_local_credentials(pid()) :: {:ok, ufrag :: binary(), pwd :: binary()}
  @callback get_local_candidates(pid()) :: [binary()]
  @callback get_remote_candidates(pid()) :: [binary()]
  @callback get_role(pid()) :: ExICE.ICEAgent.role() | nil
  @callback restart(pid()) :: :ok
  @callback send_data(pid(), binary()) :: :ok
  @callback set_role(pid(), ExICE.ICEAgent.role()) :: :ok
  @callback set_remote_credentials(pid(), ufrag :: binary(), pwd :: binary()) :: :ok
  @callback get_stats(pid()) :: map()
  @callback stop(pid()) :: :ok
end

defmodule ExWebRTC.DefaultICETransport do
  @moduledoc false

  @behaviour ExWebRTC.ICETransport

  alias ExICE.ICEAgent

  @impl true
  defdelegate start_link(opts), to: ICEAgent
  @impl true
  defdelegate on_data(pid, dst_pid), to: ICEAgent
  @impl true
  defdelegate add_remote_candidate(pid, candidate), to: ICEAgent
  @impl true
  defdelegate end_of_candidates(pid), to: ICEAgent
  @impl true
  defdelegate gather_candidates(pid), to: ICEAgent
  @impl true
  defdelegate get_role(pid), to: ICEAgent
  @impl true
  defdelegate get_local_credentials(pid), to: ICEAgent
  @impl true
  defdelegate get_local_candidates(pid), to: ICEAgent
  @impl true
  defdelegate get_remote_candidates(pid), to: ICEAgent
  @impl true
  defdelegate restart(pid), to: ICEAgent
  @impl true
  defdelegate send_data(pid, data), to: ICEAgent
  @impl true
  defdelegate set_role(pid, role), to: ICEAgent
  @impl true
  defdelegate set_remote_credentials(pid, ufrag, pwd), to: ICEAgent
  @impl true
  defdelegate get_stats(pid), to: ICEAgent
  @impl true
  defdelegate stop(pid), to: ICEAgent
end
