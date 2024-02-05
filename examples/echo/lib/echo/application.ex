defmodule Echo.Application do
  use Application

  require Logger

  @ip {127, 0, 0, 1}
  @port 8829

  @impl true
  def start(_type, _args) do
    Logger.configure(level: :info)

    children = [
      {Bandit, plug: Echo.Router, ip: @ip, port: @port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
