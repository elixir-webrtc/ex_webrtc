defmodule ExWebRTC.PeerConnection.Configuration do
  @moduledoc false

  @type bundle_policy() ::
          :balanced
          | :max_compat
          | :max_bundle

  @type ice_server() :: %{
          optional(:credential) => String.t(),
          optional(:username) => String.t(),
          :urls => [String.t()] | String.t()
        }

  # TODO implement
  @type certificate() :: :TODO

  @type ice_transport_policy() ::
          :all
          | :relay

  @type rtcp_mux_policy() ::
          :negotiate
          | :require

  @type t() :: %__MODULE__{
          bundle_policy: bundle_policy(),
          certificates: [certificate()],
          ice_candidate_pool_size: non_neg_integer(),
          ice_servers: [ice_server()],
          ice_transport_policy: ice_transport_policy(),
          peer_identity: String.t(),
          rtcp_mux_policy: rtcp_mux_policy()
        }

  defstruct bundle_policy: :max_bundle,
            certificates: nil,
            ice_candidate_pool_size: 0,
            ice_servers: [],
            ice_transport_policy: :all,
            peer_identity: nil,
            rtcp_mux_policy: :require

  @spec check_support(t()) :: :ok
  def check_support(config) do
    if config.ice_transport_policy != :all do
      raise "#{inspect(config.ice_transport_policy)} ice transport policy is currently not supported"
    end

    if config.ice_candidate_pool_size != 0 do
      raise "Ice candidate pool size different than 0 (pre-gathering) is currently not supported"
    end

    if config.bundle_policy != :max_bundle do
      raise "Bundle policy options different than :max_bundle are currently not supported"
    end

    if config.certificates != nil do
      raise "Certificates configuration option is currently not supported"
    end

    if config.peer_identity != nil do
      raise "Identify option is currently not supported"
    end

    if config.rtcp_mux_policy != :require do
      raise "RTCP mux policy option :negotiate is currently not supported"
    end

    :ok
  end
end
