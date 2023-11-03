defmodule ExWebRTC.PeerConnection.Configuration do
  @moduledoc """
  PeerConnection configuration
  """

  @type ice_server() :: %{
          optional(:credential) => String.t(),
          optional(:username) => String.t(),
          :urls => [String.t()] | String.t()
        }

  @typedoc """
  Options that can be passed to `ExWebRTC.PeerConnection.start_link/1`.

  Currently, ExWebRTC always uses the following config:
  * bundle_policy - max_bundle
  * ice_candidate_pool_size - 0
  * ice_transport_policy - all
  * rtcp_mux_policy - require

  This config cannot be changed.
  """
  @type options() :: [ice_servers: [ice_server()]]

  @typedoc false
  @type t() :: %__MODULE__{ice_servers: [ice_server()]}

  defstruct ice_servers: []

  @doc false
  @spec from_options!(options()) :: t()
  def from_options!(options) do
    config = struct!(__MODULE__, options)

    # ATM, ExICE does not support relay via TURN
    stun_servers =
      config.ice_servers
      |> Enum.flat_map(&List.wrap(&1.urls))
      |> Enum.filter(&String.starts_with?(&1, "stun:"))

    %__MODULE__{config | ice_servers: stun_servers}
  end
end
