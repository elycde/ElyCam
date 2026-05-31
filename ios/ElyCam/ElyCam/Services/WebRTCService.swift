// WebRTCService.swift
// ElyCam - Camera Streaming App
//
// Manages the WebRTC peer connection lifecycle including:
// - RTCPeerConnectionFactory setup with H.264 priority
// - LAN-only ICE configuration (no STUN/TURN servers)
// - SDP offer/answer exchange
// - ICE candidate handling
// - Video and audio track management

import Foundation
import WebRTC
import os

// MARK: - WebRTC Delegate

/// Protocol for receiving WebRTC events.
protocol WebRTCServiceDelegate: AnyObject {
    /// Generated a local SDP offer to send via signaling.
    func webRTC(_ service: WebRTCService, didGenerateOffer sdp: RTCSessionDescription)
    /// Generated a local ICE candidate to send via signaling.
    func webRTC(_ service: WebRTCService, didGenerateCandidate candidate: RTCIceCandidate)
    /// ICE connection state changed (connected, disconnected, failed, etc.).
    func webRTC(_ service: WebRTCService, didChangeConnectionState state: RTCIceConnectionState)
}

// MARK: - WebRTC Service

final class WebRTCService: NSObject {
    
    // MARK: Properties
    
    weak var delegate: WebRTCServiceDelegate?
    
    /// The shared peer connection factory, initialized once.
    private let factory: RTCPeerConnectionFactory
    
    /// The active peer connection (nil when not negotiating/streaming).
    private(set) var peerConnection: RTCPeerConnection?
    
    /// The local video source fed by RTCCameraVideoCapturer.
    private(set) var videoSource: RTCVideoSource?
    
    /// The local video track added to the peer connection.
    private(set) var videoTrack: RTCVideoTrack?
    
    /// The local audio track (optional, for microphone streaming).
    private(set) var audioTrack: RTCAudioTrack?
    
    private let logger = Logger(subsystem: "com.elycde.elycam", category: "WebRTC")
    
    // MARK: - Initialization
    
    override init() {
        // Initialize WebRTC with H.264 as the preferred codec
        RTCInitializeSSL()
        
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        encoderFactory.preferredCodec = RTCVideoCodecInfo(name: kRTCVideoCodecH264Name)
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        
        factory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        
        super.init()
        logger.info("WebRTCService initialized with H.264 preferred codec")
    }
    
    deinit {
        close()
        RTCCleanupSSL()
    }
    
    // MARK: - Peer Connection Setup
    
    /// Create a new RTCPeerConnection with LAN-only configuration.
    /// Call this before creating an offer. Tears down any existing connection first.
    func setupPeerConnection() {
        // Clean up previous connection if any
        peerConnection?.close()
        peerConnection = nil
        
        // LAN-only configuration: no STUN/TURN servers needed
        let config = RTCConfiguration()
        config.iceServers = []                              // No external ICE servers
        config.sdpSemantics = .unifiedPlan                  // Modern SDP format
        config.continualGatheringPolicy = .gatherOnce       // Gather candidates once, faster for LAN
        config.candidateNetworkPolicy = .all                // Allow all network interfaces
        config.tcpCandidatePolicy = .disabled               // UDP only for lower latency
        
        // Mandatory constraints for the peer connection
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        
        guard let pc = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        ) else {
            logger.error("Failed to create RTCPeerConnection")
            return
        }
        
        peerConnection = pc
        logger.info("RTCPeerConnection created with LAN-only config")
    }
    
    // MARK: - Video Track
    
    /// Create a video source and track, adding it to the peer connection.
    /// Returns the video source for use with RTCCameraVideoCapturer.
    @discardableResult
    func addVideoTrack() -> RTCVideoSource {
        let source = factory.videoSource()
        videoSource = source
        
        let track = factory.videoTrack(with: source, trackId: "ElyCam-video0")
        track.isEnabled = true
        videoTrack = track
        
        // Add the video track to the peer connection with a stream ID
        peerConnection?.add(track, streamIds: ["ElyCam-stream0"])
        
        logger.info("Video track added to peer connection")
        return source
    }
    
    // MARK: - Audio Track
    
    /// Create an audio source and track, adding it to the peer connection.
    func addAudioTrack() {
        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: [
                "googEchoCancellation": "false",    // Not needed for one-way streaming
                "googAutoGainControl": "true",
                "googNoiseSuppression": "true",
                "googHighpassFilter": "true"
            ]
        )
        
        let source = factory.audioSource(with: audioConstraints)
        let track = factory.audioTrack(with: source, trackId: "ElyCam-audio0")
        track.isEnabled = true
        audioTrack = track
        
        peerConnection?.add(track, streamIds: ["ElyCam-stream0"])
        
        logger.info("Audio track added to peer connection")
    }
    
    // MARK: - SDP Negotiation
    
    /// Create an SDP offer and set it as the local description.
    /// The generated offer is delivered via the delegate.
    func createOffer() {
        guard let pc = peerConnection else {
            logger.error("Cannot create offer: no peer connection")
            return
        }
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse,
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueFalse
            ],
            optionalConstraints: nil
        )
        
        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self = self else { return }
            
            if let error = error {
                self.logger.error("Failed to create offer: \(error.localizedDescription)")
                return
            }
            
            guard let sdp = sdp else {
                self.logger.error("Created offer but SDP is nil")
                return
            }
            
            // Set the offer as local description
            pc.setLocalDescription(sdp) { [weak self] error in
                guard let self = self else { return }
                
                if let error = error {
                    self.logger.error("Failed to set local description: \(error.localizedDescription)")
                    return
                }
                
                self.logger.info("Local description set, SDP offer ready")
                
                // Notify delegate on main queue
                DispatchQueue.main.async {
                    self.delegate?.webRTC(self, didGenerateOffer: sdp)
                }
            }
        }
    }
    
    /// Handle an SDP answer received from the remote peer via signaling.
    func handleAnswer(sdp: String) {
        guard let pc = peerConnection else {
            logger.error("Cannot handle answer: no peer connection")
            return
        }
        
        let sessionDescription = RTCSessionDescription(type: .answer, sdp: sdp)
        
        pc.setRemoteDescription(sessionDescription) { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to set remote description: \(error.localizedDescription)")
                return
            }
            self?.logger.info("Remote description (answer) set successfully")
        }
    }
    
    // MARK: - ICE Candidates
    
    /// Add a remote ICE candidate received from signaling.
    func addIceCandidate(candidate: String, sdpMLineIndex: Int32, sdpMid: String?) {
        let iceCandidate = RTCIceCandidate(
            sdp: candidate,
            sdpMLineIndex: sdpMLineIndex,
            sdpMid: sdpMid
        )
        
        peerConnection?.add(iceCandidate) { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to add ICE candidate: \(error.localizedDescription)")
                return
            }
            self?.logger.debug("Added remote ICE candidate")
        }
    }
    
    // MARK: - Teardown
    
    /// Close the peer connection and release all tracks.
    /// Does not destroy the factory — a new peer connection can be created.
    func close() {
        videoTrack?.isEnabled = false
        audioTrack?.isEnabled = false
        
        peerConnection?.close()
        peerConnection = nil
        videoTrack = nil
        audioTrack = nil
        videoSource = nil
        
        logger.info("WebRTC peer connection closed and tracks released")
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCService: RTCPeerConnectionDelegate {
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        logger.info("Signaling state changed: \(stateChanged.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        logger.info("Remote stream added: \(stream.streamId)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        logger.info("Remote stream removed: \(stream.streamId)")
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        logger.info("Peer connection should negotiate")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        logger.info("ICE connection state: \(newState.rawValue)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.webRTC(self, didChangeConnectionState: newState)
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        logger.info("ICE gathering state: \(newState.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        logger.debug("Generated local ICE candidate: \(candidate.sdp.prefix(60))...")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.webRTC(self, didGenerateCandidate: candidate)
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        logger.debug("Removed \(candidates.count) ICE candidates")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        logger.info("Data channel opened: \(dataChannel.label)")
    }
}
