defmodule WhipWhep.MixProject do
  use Mix.Project

  def project do
    [
      app: :whip_whep,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {WhipWhep, []}
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.15.0"},
      {:bandit, "~> 1.4.0"},
      {:corsica, "~> 2.0.0"},
      {:jason, "~> 1.4.0"},
      {:ex_webrtc, path: "../../."}
    ]
  end
end
