const pcConfig = { 'iceServers': [{ 'urls': 'stun:stun.l.google.com:19302' },] };
const mediaConstraints = {video: true, audio: true}

const ws = new WebSocket(`ws://${window.location.host}/ws`);
ws.onopen = _ => start_connection(ws);
ws.onclose = event => console.log("WebSocket connection was terminated:", event);

const start_connection = async (ws) => {
  const videoPlayer = document.getElementById("videoPlayer");
  videoPlayer.srcObject = new MediaStream();

  const pc = new RTCPeerConnection(pcConfig);
  pc.ontrack = event => videoPlayer.srcObject.addTrack(event.track);
  pc.onicecandidate = event => {
    if (event.candidate === null) return;

    console.log("Sent ICE candidate:", event.candidate);
    ws.send(JSON.stringify({ type: "ice", data: event.candidate }));
  };

  const localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
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
