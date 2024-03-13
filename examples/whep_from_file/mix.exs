defmodule WHEPFromFile.MixProject do
  use Mix.Project

  def project do
    [
      app: :whep_from_file,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {WHEPFromFile.Application, []}
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.15.0"},
      {:bandit, "~> 1.2.0"},
      {:ex_webrtc, path: "../../."}
    ]
  end
end
