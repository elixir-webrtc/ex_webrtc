defmodule WHEPFromFile.Application do
  use Application

  require Logger

  @ip {127, 0, 0, 1}
  @port 8829

  @impl true
  def start(_type, _args) do
    Logger.configure(level: :info)

    children = [
      {Bandit, plug: WHEPFromFile.Router, ip: @ip, port: @port},
      # Unlike the other examples, we start the media stream in the application
      # to pretend to be an existing "live stream"
      WHEPFromFile.FileStreamer,
      WHEPFromFile.ViewerSupervisor,
      {Registry, [keys: :unique, name: :viewer_registry]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
