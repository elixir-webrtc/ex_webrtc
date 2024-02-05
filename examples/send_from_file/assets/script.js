const pcConfig = { 'iceServers': [{ 'urls': 'stun:stun.l.google.com:19302' },] };
const address = "ws://127.0.0.1:8829/ws"

const ws = new WebSocket(address);
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

  ws.onmessage = async event => {
    const {type, data} = JSON.parse(event.data);

    switch (type) {
      case "offer":
        console.log("Received SDP offer:", data);
        await pc.setRemoteDescription(data)

        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);

        console.log("Sent SDP answer:", answer);
        ws.send(JSON.stringify({type: "answer", data: answer}))
        break;
      case "ice":
        console.log("Recieved ICE candidate:", data);
        await pc.addIceCandidate(data);
    }
  };
};
