const pcConfig = { 'iceServers': [{ 'urls': 'stun:stun.l.google.com:19302' },] };
const mediaConstraints = {audio: true, video: {
  width: { ideal: 640 },
  height: { ideal: 480 },
  frameRate: { ideal: 15 }
}}
const address = "ws://127.0.0.1:8829/ws"

const button = document.getElementById("button")
button.onclick = () => {
  const ws = new WebSocket(address);
  ws.onopen = _ => start_connection(ws);
  ws.onclose = event => console.log("WebSocket connection was terminated:", event);

  button.textContent = "Stop";
  button.onclick = () => ws.close();
}

const start_connection = async (ws) => {
  const pc = new RTCPeerConnection(pcConfig);
  pc.onicecandidate = event => {
    if (event.candidate === null) return;

    console.log("Sent ICE candidate:", event.candidate);
    ws.send(JSON.stringify({ type: "ice", data: event.candidate }));
  };

  const localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
  document.getElementById("videoPlayer").srcObject = localStream;

  for (const track of localStream.getTracks()) {
    pc.addTrack(track, localStream);
  }

  ws.onmessage = async event => {
    const {type, data} = JSON.parse(event.data);

    switch (type) {
      case "answer":
        console.log("Received SDP answer:", data);
        await pc.setRemoteDescription(data)
        break;
      case "ice":
        console.log("Recieved ICE candidate:", data);
        await pc.addIceCandidate(data);
    }
  };

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  console.log("Sent SDP offer:", offer)
  ws.send(JSON.stringify({type: "offer", data: offer}));
};
