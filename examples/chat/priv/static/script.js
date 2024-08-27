const pcConfig = { 'iceServers': [{ 'urls': 'stun:stun.l.google.com:19302' },] };
const chatInput = document.getElementById("chatInput");
const chatMessages = document.getElementById("chatMessages");

const proto = window.location.protocol === "https:" ? "wss:" : "ws:"
const ws = new WebSocket(`${proto}//${window.location.host}/ws`);
ws.onopen = _ => start_connection(ws);
ws.onclose = event => console.log("WebSocket connection was terminated:", event);

const start_connection = async (ws) => {
  const pc = new RTCPeerConnection(pcConfig);
  pc.onicecandidate = event => {
    if (event.candidate === null) return;

    console.log("Sent ICE candidate:", event.candidate);
    ws.send(JSON.stringify({ type: "ice", data: event.candidate }));
  };

  const dataChannel = pc.createDataChannel("chat");

  dataChannel.onmessage = event => {
    const msg = document.createElement("p");
    msg.innerText = event.data;
    chatMessages.appendChild(msg);
  };

  chatInput.onkeydown = event => {
    if (event.code !== "Enter") return;
    if (dataChannel.readyState !== "open") return;

    dataChannel.send(chatInput.value);
    chatInput.value = "";
  };

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
