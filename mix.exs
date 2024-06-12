defmodule ExWebRTC.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/elixir-webrtc/ex_webrtc"

  def project do
    [
      app: :ex_webrtc,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Implementation of the W3C WebRTC API",
      package: package(),
      deps: deps(),

      # docs
      docs: docs(),
      source_url: @source_url,

      # dialyzer
      dialyzer: [
        plt_local_path: "_dialyzer",
        plt_core_path: "_dialyzer"
      ],

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
      mod: {ExWebRTC.App, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp deps do
    [
      {:ex_sdp, "~> 0.17.0"},
      {:ex_ice, "~> 0.7.0"},
      {:ex_dtls, "~> 0.15.0"},
      {:ex_libsrtp, "~> 0.7.1"},
      {:ex_rtp, "~> 0.4.0"},
      {:ex_rtcp, github: "elixir-webrtc/ex_rtcp"},
      {:crc, "~> 0.10"},

      # dev/test
      {:excoveralls, "~> 0.17.0", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs() do
    [
      main: "readme",
      logo: "logo.svg",
      extras: ["README.md", "guides/mastering_transceivers.md"],
      source_ref: "v#{@version}",
      formatters: ["html"],
      before_closing_body_tag: &before_closing_body_tag/1,
      nest_modules_by_prefix: [ExWebRTC],
      groups_for_modules: [
        MEDIA: ~r"ExWebRTC\.Media\..*",
        RTP: ~r"ExWebRTC\.RTP\..*"
      ]
    ]
  end

  defp before_closing_body_tag(:html) do
    # highlight JS code blocks
    """
    <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>

    <script>
      if (document.getElementsByTagName('body')[0].className.includes('dark') == true) {
        document.write('<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/atom-one-dark.css">')
      } else {
        document.write('<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/atom-one-light.css">')
      }

      document.addEventListener("DOMContentLoaded", function () {
        for (const codeEl of document.querySelectorAll("pre code.js")) {
          codeEl.innerHTML = hljs.highlight(codeEl.innerText, {language: 'js'}).value;
        }
      });
    </script>
    """
  end
end
