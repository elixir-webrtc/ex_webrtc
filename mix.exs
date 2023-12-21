defmodule ExWebRTC.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/elixir-webrtc/ex_webrtc"

  def project do
    [
      app: :ex_webrtc,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      description: "Implementation of WebRTC",
      package: package(),
      deps: deps(),

      # docs
      docs: docs(),
      source_url: @source_url,

      # code coverage
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp deps do
    [
      {:ex_sdp, "~> 0.14.0"},
      {:ex_ice, "~> 0.4.0"},
      {:ex_dtls, "~> 0.15.0"},
      {:ex_libsrtp, "~> 0.7.1"},
      {:ex_rtp, "~> 0.2.0"},
      {:ex_rtcp, "~> 0.1.0"},
      {:crc, "~> 0.10"},

      # dev/test
      {:excoveralls, "~> 0.17.0", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.30.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs() do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      formatters: ["html"],
      nest_modules_by_prefix: [ExWebRTC]
    ]
  end
end
