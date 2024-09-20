defmodule ExWebRTC.ICE.FlyIpFilter do
  @moduledoc """
  ICE IP filter for Fly.io deployments.

  This module defines a single function, which filters out IP addresses,
  which ICE Agent will use as its host candidates.
  """

  @spec ip_filter(:inet.ip_address()) :: boolean()
  def ip_filter(ip_address) do
    case :inet.gethostbyname(~c"fly-global-services") do
      # Assume that fly-global-services has to resolve
      # to a single ipv4 address.
      # In other case, don't even try to connect.
      {:ok, {:hostent, _, _, :inet, 4, [addr]}} ->
        addr == ip_address

      _ ->
        false
    end
  end
end
