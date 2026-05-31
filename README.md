<div align="center">

# 📸 ElyCam

### Zero-Latency Multi-Camera WebRTC Streaming

*Stream from multiple iPhones to OBS Studio over local Wi-Fi with sub-100ms latency*

[![Build iOS](https://github.com/elycde/ElyCam/actions/workflows/build-ios.yml/badge.svg)](https://github.com/elycde/ElyCam/actions/workflows/build-ios.yml)

</div>

---

## 🎯 What is ElyCam?

ElyCam turns your iPhones into **wireless cameras for OBS Studio** using WebRTC over your local Wi-Fi network. Unlike RTMP-based solutions, ElyCam uses **UDP transport** for the lowest possible latency — typically **20-80ms** on a good Wi-Fi network.

### Key Features
- 🚀 **Sub-100ms latency** — WebRTC P2P over UDP, no cloud servers
- 📱 **Up to 8 cameras** — Each iPhone is a separate camera source
- 🎬 **4K@60fps** — Hardware-accelerated H.264 encoding via Apple VideoToolbox
- 🖥️ **OBS Integration** — Direct Browser Source, no plugins needed
- 📱 **iOS 26+ Liquid Glass UI** — Beautiful, modern camera interface
- 🔇 **Optional audio** — Enable/disable microphone per camera
- 📐 **Video stabilization** — Off / Standard / Cinematic modes

## 🏗️ Architecture

```
┌─────────────┐         ┌──────────────────────────┐
│   iPhone 1  │◄──WiFi──►                          │
│   (cam1)    │         │    Windows PC             │
├─────────────┤         │  ┌────────────────────┐   │
│   iPhone 2  │◄──WiFi──►  │  Python Server     │   │
│   (cam2)    │         │  │  (FastAPI :8080)    │   │
├─────────────┤         │  │  WebSocket Signal.  │   │
│   iPhone N  │◄──WiFi──►  └────────┬───────────┘   │
│   (camN)    │         │           │ serves HTML    │
└──────┬──────┘         │  ┌────────▼───────────┐   │
       │                │  │  OBS Studio         │   │
       │  WebRTC P2P    │  │  Browser Source 1   │   │
       └────(UDP)───────►  │  Browser Source 2   │   │
                        │  │  Browser Source N   │   │
                        │  └────────────────────┘   │
                        └──────────────────────────┘
```

> **Important**: The Python server only handles **signaling** (SDP/ICE exchange via WebSocket). The actual video stream goes **directly** from iPhone to OBS Browser Source via WebRTC P2P (UDP). The server never touches the video data.

## 📋 Requirements

### PC (Server + OBS)
- Windows 10/11
- Python 3.10+
- OBS Studio 30+
- Both PC and iPhones on the **same Wi-Fi network**

### iPhone (Camera)
- iOS 26.0 or later
- iPhone 12 or later recommended (for 4K@60fps)

## 🚀 Quick Start

### Step 1: Start the Python Server

```bash
# Clone the repository
git clone https://github.com/elycde/ElyCam.git
cd ElyCam/server

# Install dependencies
pip install -r requirements.txt

# Start the server (replace with your PC's local IP)
python -m uvicorn main:app --host 0.0.0.0 --port 8080
```

The server will start at `http://<your-pc-ip>:8080`

> **Find your PC's IP**: Run `ipconfig` in Command Prompt, look for `IPv4 Address` under your Wi-Fi adapter (e.g., `192.168.1.100`)

### Step 2: Install the iOS App

**Option A: Build from source (Xcode)**
1. Open Xcode → Create New Project → iOS App → SwiftUI
2. File → Add Package Dependencies → `https://github.com/nicklama/nicklama-webrtc-build`
3. Copy all files from `ios/ElyCam/ElyCam/` into your project
4. Build & run on your iPhone

**Option B: Download pre-built IPA**
1. Go to [GitHub Actions](https://github.com/elycde/ElyCam/actions) → latest build
2. Download `ElyCam-Release-unsigned` artifact
3. Install via [AltStore](https://altstore.io) or [Sideloadly](https://sideloadly.io)
4. Trust the certificate: Settings → General → VPN & Device Management

### Step 3: Connect iPhone to Server

1. Open ElyCam on your iPhone
2. Enter your PC's local IP (e.g., `192.168.1.100`)
3. Set port to `8080`
4. Set camera name (e.g., `cam1`)
5. Tap **Connect** → then tap **Stream**

### Step 4: Add to OBS

1. In OBS, add a new **Browser Source**
2. Set URL to: `http://<your-pc-ip>:8080/view?cam=cam1`
3. Set resolution to match your camera (e.g., 1920x1080 or 3840x2160)
4. Check "Shutdown source when not visible" = **OFF**
5. Check "Refresh browser when scene becomes active" = **OFF**

Repeat for each camera (`cam2`, `cam3`, etc.)

## 📁 Project Structure

```
ElyCam/
├── server/                     # Python Signaling Server
│   ├── main.py                 # FastAPI + WebSocket signaling
│   ├── requirements.txt        # Python dependencies
│   └── static/                 # OBS Viewer (served by FastAPI)
│       ├── index.html          # Browser Source page
│       ├── app.js              # WebRTC subscriber logic
│       └── style.css           # Fullscreen video styles
│
├── ios/ElyCam/                 # iOS App
│   ├── project.yml             # XcodeGen project spec
│   └── ElyCam/
│       ├── ElyCamApp.swift     # App entry point
│       ├── Info.plist          # Permissions
│       ├── Models/             # Data models
│       ├── Services/           # WebRTC, Signaling, Camera
│       └── Views/              # SwiftUI views (Liquid Glass)
│
├── .github/workflows/          # CI/CD
│   └── build-ios.yml           # GitHub Actions iOS build
│
└── README.md
```

## ⚡ Low-Latency Configuration

ElyCam is configured for the lowest possible latency over LAN:

| Setting | Value | Why |
|---------|-------|-----|
| ICE Servers | Empty (no STUN/TURN) | Direct host candidates on LAN |
| ICE Gathering | `gatherOnce` | No relay candidate search |
| Video Codec | H.264 Baseline | No B-frames, hardware accelerated |
| Playout Delay | `0` | Minimal jitter buffer |
| Transport | UDP (SRTP) | No TCP retransmission delays |
| Keyframe Interval | 1-2 sec | Fast error recovery |

## 🔧 Troubleshooting

### "Camera not showing in OBS"
1. Check that the Python server is running (`http://<ip>:8080/api/health`)
2. Check that the iPhone shows "Streaming" status
3. Open `http://<ip>:8080/view?cam=cam1` in Chrome to test directly
4. Make sure both devices are on the **same Wi-Fi network**
5. Check Windows Firewall — allow port 8080 (TCP) and WebRTC ports (UDP)

### "High latency (>100ms)"
1. Use 5GHz Wi-Fi band (not 2.4GHz)
2. Reduce resolution: try 1080p instead of 4K
3. Reduce FPS: try 30fps instead of 60fps
4. Disable video stabilization (adds processing latency)
5. Move closer to the Wi-Fi router

### "Connection drops frequently"
1. Check Wi-Fi signal strength on iPhone
2. Ensure no VPN is active on either device
3. Check that the signaling server is not behind a firewall

## 🛠️ API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/ws/{room_id}` | WebSocket | Signaling connection |
| `/view?cam={room_id}` | GET | OBS viewer page |
| `/api/cameras` | GET | List active cameras |
| `/api/health` | GET | Server health check |

## 📜 License

MIT License — use freely for personal and commercial projects.

---

<div align="center">
Made with ❤️ by <a href="https://github.com/elycde">elycde</a>
</div>
