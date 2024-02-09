defmodule ExWebRTC.App do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [{Registry, keys: :unique, name: ExWebRTC.Registry}]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
