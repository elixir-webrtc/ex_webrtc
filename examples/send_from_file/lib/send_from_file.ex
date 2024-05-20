defmodule SendFromFile do
  use Application

  @ip Application.compile_env!(:send_from_file, :ip)
  @port Application.compile_env!(:send_from_file, :port)

  @impl true
  def start(_type, _args) do
    children = [
      {Bandit, plug: __MODULE__.Router, ip: @ip, port: @port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
