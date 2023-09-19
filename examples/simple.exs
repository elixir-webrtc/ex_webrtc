Mix.install([{:ex_webrtc, path: "./"}])

alias ExWebRTC.PeerConnection

{:ok, pc} = PeerConnection.start_link()

{:ok, offer} = PeerConnection.create_offer(pc)

IO.inspect(offer.sdp, label: :OFFER)
