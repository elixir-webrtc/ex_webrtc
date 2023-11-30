const pcConfig = {
  'iceServers': [
    {'urls': 'stun:stun.stunprotocol.org:3478'},
    {'urls': 'stun:stun.l.google.com:19302'},
  ]
};

const start_connection = async (ws) => {
  const pc = new RTCPeerConnection(pcConfig);

  pc.onconnectionstatechange = _ => console.log("Connection state changed:", pc.connectionState);
  pc.onicecandidateerror = event => console.log("ICE candidate error:", event);
  pc.oniceconnectionstatechange = _ => console.log("ICE connection state changed:", pc.iceConnectionState);
  pc.onicegatheringstatechange = _ => console.log("ICE gathering state changed:", pc.iceGatheringState);
  pc.onsignalingstatechange = _ => console.log("Signaling state changed:", pc.signalingState);
  pc.ontrack = event => {
    const videoPlayer = document.createElement("video");
    videoPlayer.srcObject = event.streams[0];
    videoPlayer.onloadedmetadata = () => {
      videoPlayer.play();
    };
    document.body.appendChild(videoPlayer);
  };
  pc.onicecandidate = event => {
    console.log("New local ICE candidate:", event.candidate);

    if (event.candidate !== null) {
      ws.send(JSON.stringify({type: "ice", data: event.candidate}));
    }
  };
  
  const localStream = await navigator.mediaDevices.getUserMedia({video: true});
  const localVideoPlayer = document.createElement("video");
  localVideoPlayer.srcObject = localStream;
  localVideoPlayer.onloadedmetadata = () => {
    localVideoPlayer.play();
  };
  document.body.appendChild(localVideoPlayer);

  for (const track of localStream.getTracks()) {
    pc.addTrack(track, localStream);
  }

  ws.onmessage = async event => {
    const msg = JSON.parse(event.data);

    if (msg.type === "answer") {
      console.log("Recieved SDP answer:", msg);
      pc.setRemoteDescription(msg);
    } else if (msg.type === "offer") {
      console.log("Received SDP offer:", msg);
      await pc.setRemoteDescription(msg)

      const desc = await pc.createAnswer();
      await pc.setLocalDescription(desc);
      ws.send(JSON.stringify(desc));
    } else if (msg.type === "ice") {
      console.log("Recieved remote ICE candidate:", msg.data);
      pc.addIceCandidate(msg.data);
    } else {
      console.log("Received unexpected message:", msg);
    }
  };

  const desc = await pc.createOffer();
  console.log("Generated SDP offer:", desc);
  await pc.setLocalDescription(desc);
  ws.send(JSON.stringify(desc))
};

const ws = new WebSocket("ws://127.0.0.1:4000/websocket");
ws.onclose = event => console.log("WebSocket was closed", event);
ws.onopen = _ => start_connection(ws);
