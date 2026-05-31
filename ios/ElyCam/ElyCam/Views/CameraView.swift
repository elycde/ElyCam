// CameraView.swift
// ElyCam - Camera Streaming App
//
// Main camera streaming view that coordinates SignalingService,
// WebRTCService, and CameraManager. Full-screen camera preview
// with Liquid Glass overlay controls (StatusBar + GlassToolbar).
//
// Flow:
// 1. On appear → start camera preview
// 2. Connect signaling → on join → wait for create-offer
// 3. On create-offer → setup WebRTC, add tracks, create SDP offer
// 4. Send offer → receive answer → set remote description
// 5. Exchange ICE candidates → streaming live
// 6. On peer-left → clean up WebRTC, wait for next subscriber

import SwiftUI
@preconcurrency import WebRTC
import os

// MARK: - Camera View

struct CameraView: View {
    
    @ObservedObject var settings: CameraSettings
    var onDisconnect: () -> Void
    
    // MARK: State
    
    @State private var connectionState: ConnectionState = .connecting
    @State private var showSettings = false
    @State private var videoTrack: RTCVideoTrack?
    
    // Services (created once per view lifecycle)
    @State private var signalingService = SignalingService()
    @State private var webRTCService = WebRTCService()
    @State private var cameraManager = CameraManager()
    
    // Coordinator bridges delegate callbacks to SwiftUI state
    @State private var coordinator: StreamCoordinator?
    
    private let logger = Logger(subsystem: "com.elycde.elycam", category: "CameraView")
    
    var body: some View {
        ZStack {
            // MARK: - Camera Preview (Full Screen)
            VideoPreviewView(videoTrack: videoTrack)
                .ignoresSafeArea()
            
            // Dark overlay when not streaming
            if !connectionState.isStreaming {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            
            // MARK: - Controls Overlay
            VStack {
                // Top: Status Bar
                StatusBar(
                    connectionState: connectionState,
                    roomName: settings.roomName,
                    resolution: settings.resolution.rawValue,
                    fps: settings.fps
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                
                Spacer()
                
                // Center: Connection status text when not streaming
                if !connectionState.isStreaming {
                    VStack(spacing: 8) {
                        if connectionState == .connecting || connectionState == .negotiating {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.2)
                                .padding(.bottom, 4)
                        }
                        
                        Text(connectionState.displayText)
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .transition(.opacity)
                }
                
                Spacer()
                
                // Bottom: Toolbar
                GlassToolbar(
                    isStreaming: .init(
                        get: { connectionState.isStreaming },
                        set: { _ in }
                    ),
                    onFlipCamera: handleFlipCamera,
                    onToggleStream: handleToggleStream,
                    onOpenSettings: { showSettings = true }
                )
                .padding(.bottom, 16)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: connectionState)
        .sheet(isPresented: $showSettings) {
            SettingsView(
                settings: settings,
                isStreaming: connectionState.isStreaming,
                onCameraSettingsChanged: handleCameraSettingsChanged
            )
        }
        .onAppear(perform: startStreaming)
        .onDisappear(perform: cleanup)
        .persistentSystemOverlays(.hidden)
    }
    
    // MARK: - Streaming Lifecycle
    
    /// Initialize all services and start the streaming pipeline.
    private func startStreaming() {
        // Create the coordinator that bridges delegate callbacks to this view
        let coord = StreamCoordinator(
            signalingService: signalingService,
            webRTCService: webRTCService,
            cameraManager: cameraManager,
            settings: settings,
            onStateChanged: { state in
                withAnimation {
                    connectionState = state
                }
            },
            onVideoTrackReady: { track in
                videoTrack = track
            }
        )
        coordinator = coord
        
        // Wire up delegates
        signalingService.delegate = coord
        webRTCService.delegate = coord
        
        // Setup camera with WebRTC video source
        let videoSource = webRTCService.addVideoTrack()
        cameraManager.setup(with: videoSource)
        
        // Start camera preview immediately
        cameraManager.startCapture(
            position: settings.cameraPosition,
            resolution: settings.resolution,
            fps: settings.fps,
            stabilization: settings.stabilization
        )
        
        // Set the video track for local preview
        videoTrack = webRTCService.videoTrack
        
        // Connect to signaling server
        guard let url = settings.websocketURL else {
            connectionState = .error("Invalid server URL")
            return
        }
        
        connectionState = .connecting
        signalingService.connect(to: url)
    }
    
    /// Clean up all services on view disappear.
    private func cleanup() {
        signalingService.disconnect()
        webRTCService.close()
        cameraManager.teardown()
        coordinator = nil
        videoTrack = nil
    }
    
    // MARK: - User Actions
    
    /// Flip between front and back camera.
    private func handleFlipCamera() {
        let newPosition: CameraPosition = (settings.cameraPosition == .back) ? .front : .back
        settings.cameraPosition = newPosition
        
        cameraManager.switchCamera(
            to: newPosition,
            resolution: settings.resolution,
            fps: settings.fps,
            stabilization: settings.stabilization
        )
    }
    
    /// Toggle streaming on/off.
    private func handleToggleStream() {
        if connectionState.isConnected {
            // Disconnect and go back to connect screen
            cleanup()
            onDisconnect()
        } else {
            // Retry connection
            startStreaming()
        }
    }
    
    /// Called when camera-related settings change in SettingsView.
    private func handleCameraSettingsChanged() {
        cameraManager.switchCamera(
            to: settings.cameraPosition,
            resolution: settings.resolution,
            fps: settings.fps,
            stabilization: settings.stabilization
        )
    }
}

// MARK: - Stream Coordinator

/// Bridges delegate callbacks from SignalingService and WebRTCService
/// into SwiftUI-friendly state updates. This class is the "glue" that
/// orchestrates the signaling + WebRTC + camera pipeline.
final class StreamCoordinator: NSObject, SignalingServiceDelegate, WebRTCServiceDelegate, @unchecked Sendable {
    
    private let signalingService: SignalingService
    private let webRTCService: WebRTCService
    private let cameraManager: CameraManager
    private let settings: CameraSettings
    
    private let onStateChanged: (ConnectionState) -> Void
    private let onVideoTrackReady: (RTCVideoTrack?) -> Void
    
    private let logger = Logger(subsystem: "com.elycde.elycam", category: "Coordinator")
    
    init(
        signalingService: SignalingService,
        webRTCService: WebRTCService,
        cameraManager: CameraManager,
        settings: CameraSettings,
        onStateChanged: @escaping (ConnectionState) -> Void,
        onVideoTrackReady: @escaping (RTCVideoTrack?) -> Void
    ) {
        self.signalingService = signalingService
        self.webRTCService = webRTCService
        self.cameraManager = cameraManager
        self.settings = settings
        self.onStateChanged = onStateChanged
        self.onVideoTrackReady = onVideoTrackReady
        super.init()
    }
    
    // MARK: - SignalingServiceDelegate
    
    func signaling(_ service: SignalingService, didJoinRoom room: String) {
        logger.info("Joined room: \(room)")
        onStateChanged(.signalingConnected)
    }
    
    func signalingDidRequestOffer(_ service: SignalingService) {
        logger.info("Server requested offer — setting up WebRTC peer connection")
        onStateChanged(.negotiating)
        
        // Setup a fresh peer connection for this negotiation
        webRTCService.setupPeerConnection()
        
        // Re-add video track to the new peer connection
        let videoSource = webRTCService.addVideoTrack()
        // Camera is already capturing to the previous source, re-link
        cameraManager.setup(with: videoSource)
        cameraManager.startCapture(
            position: settings.cameraPosition,
            resolution: settings.resolution,
            fps: settings.fps,
            stabilization: settings.stabilization
        )
        
        // Update the video track reference for preview
        onVideoTrackReady(webRTCService.videoTrack)
        
        // Add audio track if enabled
        if settings.audioEnabled {
            webRTCService.addAudioTrack()
        }
        
        // Create and send the SDP offer
        webRTCService.createOffer()
    }
    
    func signaling(_ service: SignalingService, didReceiveAnswer sdp: String) {
        logger.info("Received SDP answer from viewer")
        webRTCService.handleAnswer(sdp: sdp)
    }
    
    func signaling(_ service: SignalingService, didReceiveCandidate candidate: String, sdpMLineIndex: Int32, sdpMid: String?) {
        logger.debug("Received remote ICE candidate")
        webRTCService.addIceCandidate(candidate: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
    }
    
    func signalingDidReceivePeerJoined(_ service: SignalingService) {
        logger.info("Peer (viewer) joined the room")
    }
    
    func signalingDidReceivePeerLeft(_ service: SignalingService) {
        logger.info("Peer (viewer) left — cleaning up WebRTC, waiting for next subscriber")
        
        // Tear down the current peer connection but keep camera running
        webRTCService.close()
        
        // Go back to waiting state
        onStateChanged(.signalingConnected)
    }
    
    func signaling(_ service: SignalingService, didReceiveError message: String) {
        logger.error("Signaling error: \(message)")
        onStateChanged(.error(message))
    }
    
    func signaling(_ service: SignalingService, connectionStateChanged isConnected: Bool) {
        if !isConnected {
            logger.warning("Signaling disconnected — attempting reconnect")
            onStateChanged(.connecting)
        }
    }
    
    // MARK: - WebRTCServiceDelegate
    
    func webRTC(_ service: WebRTCService, didGenerateOffer sdp: RTCSessionDescription) {
        logger.info("Sending SDP offer via signaling")
        signalingService.sendOffer(sdp: sdp.sdp)
    }
    
    func webRTC(_ service: WebRTCService, didGenerateCandidate candidate: RTCIceCandidate) {
        logger.debug("Sending ICE candidate via signaling")
        signalingService.sendIceCandidate(
            candidate: candidate.sdp,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )
    }
    
    func webRTC(_ service: WebRTCService, didChangeConnectionState state: RTCIceConnectionState) {
        switch state {
        case .connected, .completed:
            logger.info("WebRTC connected — stream is live!")
            onStateChanged(.streaming)
            
        case .disconnected:
            logger.warning("WebRTC disconnected")
            onStateChanged(.signalingConnected)
            
        case .failed:
            logger.error("WebRTC connection failed")
            onStateChanged(.error("WebRTC connection failed"))
            
        case .closed:
            logger.info("WebRTC connection closed")
            
        case .new, .checking, .count:
            break
            
        @unknown default:
            break
        }
    }
}

// MARK: - Preview

#Preview {
    CameraView(settings: CameraSettings()) {
        print("Disconnected")
    }
}
