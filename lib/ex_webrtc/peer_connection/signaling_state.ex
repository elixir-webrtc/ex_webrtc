defmodule ExWebRTC.PeerConnection.SignalingState do
  @moduledoc false

  @type t() ::
          :stable
          | :have_local_offer
          | :have_remote_offer
          | :have_local_pranswer
          | :have_remote_pranswer
end
