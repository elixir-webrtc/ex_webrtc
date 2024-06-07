const pcConfig = { 'iceServers': [{ 'urls': 'stun:stun.l.google.com:19302' },] };
const mediaConstraints = {audio: true, video: {
  width: { ideal: 640 },
  height: { ideal: 480 },
  frameRate: { ideal: 15 }
}}

const button = document.getElementById("button")
button.onclick = () => {
  const proto = window.location.protocol === "https:" ? "wss:" : "ws:"
  const ws = new WebSocket(`${proto}//${window.location.host}/ws`);
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
        console.log("Received ICE candidate:", data);
        await pc.addIceCandidate(data);
    }
  };

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  console.log("Sent SDP offer:", offer)
  ws.send(JSON.stringify({type: "offer", data: offer}));
};
