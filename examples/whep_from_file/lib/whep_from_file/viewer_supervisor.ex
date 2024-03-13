defmodule WHEPFromFile.ViewerSupervisor do
  use DynamicSupervisor

  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def start_child(viewer_id) do
    DynamicSupervisor.start_child(__MODULE__, {WHEPFromFile.Viewer, viewer_id})
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
