const pcConfig = {
  'iceServers': [
    {'urls': 'stun:stun.stunprotocol.org:3478'},
    {'urls': 'stun:stun.l.google.com:19302'},
  ]
};

const mediaConstraints = {
  audio: true
};

const start_connection = async (ws) => {
  const pc = new RTCPeerConnection(pcConfig);

  pc.onicecandidate = event => {
    console.log("New local ICE candidate:", event.candidate);

    if (event.candidate !== null) {
      ws.send(JSON.stringify({type: "ice", data: event.candidate.candidate}));
    }
  };

  pc.ontrack = null;  // TODO

  ws.onmessage = event => {
    const msg = JSON.parse(event.data);
    console.log("Received message:", msg);

    if (msg.type === "answer") {
      console.log("Received SDP answer:", msg.data);
      pc.setRemoteDescription(msg.data);
    } else if (msg.type === "ice") {
      console.log("Received ICE candidate:", msg.data);
      pc.addIceCandidate(msg.data);
    }
  };

  const localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
  for (const track of localStream.getTracks()) {
    pc.addTrack(track, localStream);
  }

  const desc = await pc.createOffer();
  console.log("Generated SDP offer:", desc);
  await pc.setLocalDescription(desc);

  ws.send(JSON.stringify({type: "offer", data: desc.sdp}))
};

const ws = new WebSocket("ws://127.0.0.1:4000/websocket");
ws.onopen = _ => start_connection(ws);
