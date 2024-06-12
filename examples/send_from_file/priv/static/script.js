const pcConfig = { 'iceServers': [{ 'urls': 'stun:stun.l.google.com:19302' },] };
const videoPlayer = document.getElementById("videoPlayer");


const proto = window.location.protocol === "https:" ? "wss:" : "ws:"
const ws = new WebSocket(`${proto}//${window.location.host}/ws`);
ws.onopen = _ => start_connection(ws);
ws.onclose = event => console.log("WebSocket connection was terminated:", event);

const start_connection = async (ws) => {
  const pc = new RTCPeerConnection(pcConfig);
  pc.ontrack = event => videoPlayer.srcObject = event.streams[0];
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
        console.log("Received ICE candidate:", data);
        await pc.addIceCandidate(data);
    }
  };
};
