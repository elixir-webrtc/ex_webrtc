defmodule Chat do
  use Application

  @ip Application.compile_env!(:chat, :ip)
  @port Application.compile_env!(:chat, :port)

  @impl true
  def start(_type, _args) do
    children = [
      {Bandit, plug: __MODULE__.Router, ip: @ip, port: @port},
      {Registry, name: __MODULE__.PubSub, keys: :duplicate}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
