import Config

config :logger, level: :info

# normally you take these from env variables in `config/runtime.exs`
config :whip_whep,
  ip: {127, 0, 0, 1},
  port: 8829,
  token: "example"
