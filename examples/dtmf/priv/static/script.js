const pcConfig = { iceServers: [{ urls: "stun:stun.l.google.com:19302" }] };
const mediaConstraints = { video: false, audio: true };

const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
const ws = new WebSocket(`${proto}//${window.location.host}/ws`);
ws.onopen = (_) => start_connection(ws);
ws.onclose = (event) =>
  console.log("WebSocket connection was terminated:", event);

const start_connection = async (ws) => {
  const pc = new RTCPeerConnection(pcConfig);
  // expose pc for easier debugging and experiments
  window.pc = pc;
  pc.onicecandidate = (event) => {
    if (event.candidate === null) return;

    console.log("Sent ICE candidate:", event.candidate);
    ws.send(JSON.stringify({ type: "ice", data: event.candidate }));
  };

  pc.onconnectionstatechange = () => {
    document.getElementById(
      "connection-state"
    ).innerText += `Connection state change: ${pc.connectionState}\n`;

    if (pc.connectionState === "connected") {
      pc.getSenders()[0].dtmf.ontonechange = (ev) => {
        if (ev.tone !== "") {
          document.getElementById("sent-tones").value += `${ev.tone}`;
        }
      };

      const dialPad = document.getElementById("dial-pad");
      const buttons = dialPad.getElementsByTagName("button");
      for (let i = 0; i !== buttons.length; i++) {
        buttons[i].onclick = (event) => {
          pc.getSenders()[0].dtmf.insertDTMF(event.target.textContent);
        };
      }
    }
  };

  const localStream = await navigator.mediaDevices.getUserMedia(
    mediaConstraints
  );
  pc.addTrack(localStream.getAudioTracks()[0]);

  ws.onmessage = async (event) => {
    const { type, data } = JSON.parse(event.data);

    switch (type) {
      case "answer":
        console.log("Received SDP answer:", data);
        await pc.setRemoteDescription(data);
        break;
      case "ice":
        console.log("Received ICE candidate:", data);
        await pc.addIceCandidate(data);
    }
  };

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  console.log("Sent SDP offer:", offer);
  ws.send(JSON.stringify({ type: "offer", data: offer }));
};
