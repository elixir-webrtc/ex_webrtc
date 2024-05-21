defmodule WhipWhep do
  use Application

  alias __MODULE__.{Forwarder, PeerSupervisor, Router}

  @ip Application.compile_env!(:whip_whep, :ip)
  @port Application.compile_env!(:whip_whep, :port)

  @impl true
  def start(_type, _args) do
    children = [
      {Bandit, plug: Router, scheme: :http, ip: @ip, port: @port},
      PeerSupervisor,
      Forwarder,
      {Registry, name: __MODULE__.PeerRegistry, keys: :unique}
    ]

    Supervisor.start_link(children, strategy: :one_for_all, name: __MODULE__.Supervisor)
  end
end
