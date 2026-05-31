/**
 * ElyCam Viewer – WebRTC Subscriber Client
 * ==========================================
 * Connects to the signaling server, receives a WebRTC stream from
 * the publisher (iPhone camera), and renders it to a <video> element
 * with ultra-low latency settings optimised for LAN streaming.
 *
 * Designed to run inside an OBS Browser Source.
 */

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/** Delay (ms) before attempting reconnection after a disconnect. */
const RECONNECT_DELAY_MS = 5000;

/** Interval (ms) between stats polling for the overlay. */
const STATS_INTERVAL_MS = 2000;

// ---------------------------------------------------------------------------
// DOM elements
// ---------------------------------------------------------------------------

const videoEl        = document.getElementById('video');
const statusOverlay  = document.getElementById('status-overlay');
const statusText     = document.getElementById('status-text');
const pulseDot       = document.querySelector('.pulse-dot');
const statsOverlay   = document.getElementById('stats-overlay');

// ---------------------------------------------------------------------------
// Determine room name from ?cam= query parameter
// ---------------------------------------------------------------------------

const params  = new URLSearchParams(window.location.search);
const roomName = params.get('cam') || 'cam1';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/** @type {WebSocket|null} */
let ws = null;

/** @type {RTCPeerConnection|null} */
let pc = null;

/** Interval ID for stats polling. */
let statsIntervalId = null;

/** Previous bytes-received snapshot for bitrate calculation. */
let prevBytesReceived = 0;
let prevStatsTimestamp = 0;

// ---------------------------------------------------------------------------
// UI helpers
// ---------------------------------------------------------------------------

/**
 * Update the connection status overlay.
 * @param {'connecting'|'connected'|'error'|'streaming'} state
 * @param {string} [text]
 */
function setStatus(state, text) {
  statusOverlay.classList.remove('hidden');
  pulseDot.classList.remove('connected', 'error');

  switch (state) {
    case 'connecting':
      statusText.textContent = text || 'Connecting…';
      break;
    case 'connected':
      pulseDot.classList.add('connected');
      statusText.textContent = text || 'Connected – waiting for stream';
      break;
    case 'streaming':
      pulseDot.classList.add('connected');
      statusText.textContent = text || 'Streaming';
      // Fade out the overlay after a short moment
      setTimeout(() => statusOverlay.classList.add('hidden'), 1500);
      break;
    case 'error':
      pulseDot.classList.add('error');
      statusText.textContent = text || 'Error';
      break;
  }
}

// ---------------------------------------------------------------------------
// WebSocket connection
// ---------------------------------------------------------------------------

function connect() {
  // Determine WebSocket URL based on current page origin
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const wsUrl = `${protocol}//${location.host}/ws/${roomName}`;

  setStatus('connecting', `Connecting to ${roomName}…`);
  console.log(`[ElyCam] Connecting to ${wsUrl}`);

  ws = new WebSocket(wsUrl);

  ws.onopen = () => {
    console.log('[ElyCam] WebSocket connected');
    // Join the room as a subscriber
    ws.send(JSON.stringify({ type: 'join', role: 'subscriber' }));
  };

  ws.onmessage = (event) => {
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch (e) {
      console.warn('[ElyCam] Non-JSON message received:', event.data);
      return;
    }
    handleSignalingMessage(msg);
  };

  ws.onclose = (event) => {
    console.log(`[ElyCam] WebSocket closed (code=${event.code})`);
    cleanup();
    setStatus('error', `Disconnected – reconnecting in ${RECONNECT_DELAY_MS / 1000}s…`);
    setTimeout(connect, RECONNECT_DELAY_MS);
  };

  ws.onerror = (event) => {
    console.error('[ElyCam] WebSocket error:', event);
    // onclose will fire next and handle reconnection
  };
}

// ---------------------------------------------------------------------------
// Signaling message handler
// ---------------------------------------------------------------------------

/**
 * Process a signaling message from the server.
 * @param {object} msg
 */
async function handleSignalingMessage(msg) {
  switch (msg.type) {
    // --- Room joined confirmation ---
    case 'joined':
      console.log(`[ElyCam] Joined room: ${msg.room}`);
      setStatus('connected', `Joined ${msg.room} – waiting for publisher`);
      break;

    // --- SDP offer from publisher ---
    case 'offer':
      console.log('[ElyCam] Received offer from publisher');
      await handleOffer(msg.sdp);
      break;

    // --- ICE candidate from publisher ---
    case 'ice-candidate':
      if (pc && msg.candidate) {
        try {
          await pc.addIceCandidate({
            candidate:     msg.candidate,
            sdpMLineIndex: msg.sdpMLineIndex,
            sdpMid:        msg.sdpMid,
          });
        } catch (err) {
          console.warn('[ElyCam] Failed to add ICE candidate:', err);
        }
      }
      break;

    // --- Peer (publisher) left ---
    case 'peer-left':
      console.log('[ElyCam] Publisher left – cleaning up');
      cleanupPeerConnection();
      setStatus('connected', 'Publisher disconnected – waiting…');
      break;

    // --- Peer (publisher) joined ---
    case 'peer-joined':
      console.log('[ElyCam] Peer joined');
      break;

    // --- Heartbeat ping ---
    case 'ping':
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'pong' }));
      }
      break;

    // --- Error from server ---
    case 'error':
      console.error('[ElyCam] Server error:', msg.message);
      setStatus('error', msg.message);
      break;

    default:
      console.warn('[ElyCam] Unknown message type:', msg.type);
  }
}

// ---------------------------------------------------------------------------
// WebRTC peer connection
// ---------------------------------------------------------------------------

/**
 * Handle an incoming SDP offer: create (or recreate) the RTCPeerConnection,
 * set codec preferences, set remote description, create an answer, and
 * send it back to the publisher via the signaling server.
 *
 * @param {string} sdp – The SDP offer string from the publisher.
 */
async function handleOffer(sdp) {
  // Tear down any existing peer connection first
  cleanupPeerConnection();

  // Create a new peer connection — LAN only, no STUN/TURN servers
  pc = new RTCPeerConnection({ iceServers: [] });

  // --- ICE candidate handler ---
  pc.onicecandidate = (event) => {
    if (event.candidate && ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({
        type:          'ice-candidate',
        candidate:     event.candidate.candidate,
        sdpMLineIndex: event.candidate.sdpMLineIndex,
        sdpMid:        event.candidate.sdpMid,
      }));
    }
  };

  // --- Track handler: attach media stream to <video> ---
  pc.ontrack = (event) => {
    console.log('[ElyCam] Track received:', event.track.kind);

    if (event.streams && event.streams[0]) {
      videoEl.srcObject = event.streams[0];
    } else {
      // Fallback: build a MediaStream from the track
      let stream = videoEl.srcObject;
      if (!stream || !(stream instanceof MediaStream)) {
        stream = new MediaStream();
        videoEl.srcObject = stream;
      }
      stream.addTrack(event.track);
    }

    // Ultra-low latency: set playout delay hint to zero
    if (event.receiver && 'playoutDelayHint' in event.receiver) {
      event.receiver.playoutDelayHint = 0;
      console.log('[ElyCam] Set playoutDelayHint = 0');
    }
    // Also try the jitterBufferTarget property (newer spec)
    if (event.receiver && 'jitterBufferTarget' in event.receiver) {
      event.receiver.jitterBufferTarget = 0;
      console.log('[ElyCam] Set jitterBufferTarget = 0');
    }

    setStatus('streaming');
    startStatsPolling();
  };

  // --- Connection state logging ---
  pc.onconnectionstatechange = () => {
    console.log('[ElyCam] Connection state:', pc.connectionState);
    if (pc.connectionState === 'failed' || pc.connectionState === 'disconnected') {
      setStatus('error', 'WebRTC connection lost');
    }
  };

  pc.oniceconnectionstatechange = () => {
    console.log('[ElyCam] ICE state:', pc.iceConnectionState);
  };

  // --- Add a recvonly transceiver for video & set H.264 preference ---
  const videoTransceiver = pc.addTransceiver('video', { direction: 'recvonly' });
  setCodecPreference(videoTransceiver, 'video');

  // --- Also add a recvonly transceiver for audio (if publisher sends it) ---
  pc.addTransceiver('audio', { direction: 'recvonly' });

  // --- Set remote description (the offer) ---
  await pc.setRemoteDescription({ type: 'offer', sdp: sdp });

  // --- Create and send back the answer ---
  const answer = await pc.createAnswer();
  await pc.setLocalDescription(answer);

  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({
      type: 'answer',
      sdp:  answer.sdp,
    }));
    console.log('[ElyCam] Answer sent');
  }
}

/**
 * Set codec preferences on a transceiver, prioritising H.264 for minimal
 * transcoding latency when the publisher is an iPhone (hardware H.264).
 *
 * @param {RTCRtpTransceiver} transceiver
 * @param {'video'|'audio'} kind
 */
function setCodecPreference(transceiver, kind) {
  if (!transceiver.setCodecPreferences) {
    console.log('[ElyCam] setCodecPreferences not supported');
    return;
  }

  try {
    const capabilities = RTCRtpReceiver.getCapabilities(kind);
    if (!capabilities) return;

    const codecs = capabilities.codecs;

    if (kind === 'video') {
      // Sort: H.264 codecs first, then everything else
      const h264   = codecs.filter(c => c.mimeType === 'video/H264');
      const others = codecs.filter(c => c.mimeType !== 'video/H264');
      transceiver.setCodecPreferences([...h264, ...others]);
      console.log(`[ElyCam] Codec preferences set: H.264 first (${h264.length} variants)`);
    }
  } catch (err) {
    console.warn('[ElyCam] Failed to set codec preferences:', err);
  }
}

// ---------------------------------------------------------------------------
// Stats polling
// ---------------------------------------------------------------------------

function startStatsPolling() {
  stopStatsPolling(); // prevent duplicates

  prevBytesReceived = 0;
  prevStatsTimestamp = performance.now();

  statsIntervalId = setInterval(async () => {
    if (!pc) return;

    try {
      const stats = await pc.getStats();
      let resolution = '';
      let fps = '';
      let bytesReceived = 0;

      stats.forEach((report) => {
        // Inbound video RTP stream
        if (report.type === 'inbound-rtp' && report.kind === 'video') {
          if (report.frameWidth && report.frameHeight) {
            resolution = `${report.frameWidth}×${report.frameHeight}`;
          }
          if (report.framesPerSecond !== undefined) {
            fps = `${report.framesPerSecond} fps`;
          }
          bytesReceived = report.bytesReceived || 0;
        }
      });

      // Calculate bitrate
      const now = performance.now();
      const elapsed = (now - prevStatsTimestamp) / 1000; // seconds
      let bitrate = '';
      if (elapsed > 0 && prevBytesReceived > 0) {
        const bits = (bytesReceived - prevBytesReceived) * 8;
        const mbps = bits / elapsed / 1_000_000;
        bitrate = `${mbps.toFixed(2)} Mbps`;
      }
      prevBytesReceived = bytesReceived;
      prevStatsTimestamp = now;

      // Update overlay
      const parts = [resolution, fps, bitrate].filter(Boolean);
      if (parts.length > 0) {
        statsOverlay.textContent = parts.join('  |  ');
        statsOverlay.classList.add('visible');
      }
    } catch (err) {
      // pc may have been closed between the check and getStats
      console.debug('[ElyCam] Stats error:', err);
    }
  }, STATS_INTERVAL_MS);
}

function stopStatsPolling() {
  if (statsIntervalId) {
    clearInterval(statsIntervalId);
    statsIntervalId = null;
  }
  statsOverlay.classList.remove('visible');
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------

function cleanupPeerConnection() {
  stopStatsPolling();

  if (pc) {
    pc.ontrack = null;
    pc.onicecandidate = null;
    pc.onconnectionstatechange = null;
    pc.oniceconnectionstatechange = null;
    pc.close();
    pc = null;
  }

  videoEl.srcObject = null;
}

function cleanup() {
  cleanupPeerConnection();
  ws = null;
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

console.log(`[ElyCam] Viewer starting for room: ${roomName}`);
connect();
