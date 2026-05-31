// SignalingService.swift
// ElyCam - Camera Streaming App
//
// WebSocket signaling client that communicates with the ElyCam signaling server.
// Handles the complete signaling protocol: join, offer/answer exchange,
// ICE candidate relay, and ping/pong heartbeat.
//
// Uses URLSessionWebSocketTask with automatic reconnection and exponential backoff.

import Foundation
import os

// MARK: - Signaling Delegate

/// Protocol for receiving signaling events from the WebSocket connection.
protocol SignalingServiceDelegate: AnyObject {
    /// Successfully joined a room.
    func signaling(_ service: SignalingService, didJoinRoom room: String)
    /// Server requests us to create an SDP offer (a viewer connected).
    func signalingDidRequestOffer(_ service: SignalingService)
    /// Received an SDP answer from the remote peer.
    func signaling(_ service: SignalingService, didReceiveAnswer sdp: String)
    /// Received an ICE candidate from the remote peer.
    func signaling(_ service: SignalingService, didReceiveCandidate candidate: String, sdpMLineIndex: Int32, sdpMid: String?)
    /// A peer (viewer) joined the room.
    func signalingDidReceivePeerJoined(_ service: SignalingService)
    /// A peer (viewer) left the room.
    func signalingDidReceivePeerLeft(_ service: SignalingService)
    /// Received an error message from the server.
    func signaling(_ service: SignalingService, didReceiveError message: String)
    /// WebSocket connection state changed.
    func signaling(_ service: SignalingService, connectionStateChanged isConnected: Bool)
}

// MARK: - Signaling Service

final class SignalingService: NSObject {
    
    // MARK: Properties
    
    weak var delegate: SignalingServiceDelegate?
    
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var serverURL: URL?
    
    /// Whether the WebSocket is currently connected and receiving messages.
    private(set) var isConnected: Bool = false {
        didSet {
            if oldValue != isConnected {
                delegate?.signaling(self, connectionStateChanged: isConnected)
            }
        }
    }
    
    // Reconnection state
    private var shouldReconnect = false
    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval = 30.0
    private var reconnectWorkItem: DispatchWorkItem?
    
    private let logger = Logger(subsystem: "com.elycde.elycam", category: "Signaling")
    private let queue = DispatchQueue(label: "com.elycde.elycam.signaling", qos: .userInitiated)
    
    // MARK: - Connection
    
    /// Connect to the signaling server at the given URL.
    /// - Parameter url: WebSocket URL, e.g. ws://192.168.1.100:8080/ws/cam1
    func connect(to url: URL) {
        queue.async { [weak self] in
            self?.internalConnect(to: url)
        }
    }
    
    private func internalConnect(to url: URL) {
        // Clean up any existing connection
        internalDisconnect(permanent: false)
        
        serverURL = url
        shouldReconnect = true
        reconnectAttempt = 0
        
        logger.info("Connecting to signaling server: \(url.absoluteString)")
        
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        
        let task = session.webSocketTask(with: url)
        webSocket = task
        task.resume()
        
        // Start receiving messages
        receiveMessage()
    }
    
    /// Disconnect from the signaling server permanently (no auto-reconnect).
    func disconnect() {
        queue.async { [weak self] in
            self?.internalDisconnect(permanent: true)
        }
    }
    
    private func internalDisconnect(permanent: Bool) {
        if permanent {
            shouldReconnect = false
        }
        
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        
        if isConnected {
            isConnected = false
        }
        
        if permanent {
            logger.info("Disconnected from signaling server (permanent)")
        }
    }
    
    // MARK: - Sending Messages
    
    /// Send the initial join message as a publisher.
    func sendJoin() {
        let message: [String: Any] = [
            "type": "join",
            "role": "publisher"
        ]
        sendJSON(message)
        logger.info("Sent join message as publisher")
    }
    
    /// Send an SDP offer to the signaling server.
    func sendOffer(sdp: String) {
        let message: [String: Any] = [
            "type": "offer",
            "sdp": sdp
        ]
        sendJSON(message)
        logger.info("Sent SDP offer (\(sdp.count) chars)")
    }
    
    /// Send an ICE candidate to the signaling server.
    func sendIceCandidate(candidate: String, sdpMLineIndex: Int32, sdpMid: String?) {
        var message: [String: Any] = [
            "type": "ice-candidate",
            "candidate": candidate,
            "sdpMLineIndex": sdpMLineIndex
        ]
        if let sdpMid = sdpMid {
            message["sdpMid"] = sdpMid
        } else {
            message["sdpMid"] = "0"
        }
        sendJSON(message)
        logger.debug("Sent ICE candidate")
    }
    
    /// Send a pong response to a server ping.
    private func sendPong() {
        let message: [String: Any] = [
            "type": "pong"
        ]
        sendJSON(message)
        logger.debug("Sent pong")
    }
    
    /// Serialize and send a JSON dictionary over the WebSocket.
    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            logger.error("Failed to serialize JSON message")
            return
        }
        
        webSocket?.send(.string(text)) { [weak self] error in
            if let error = error {
                self?.logger.error("WebSocket send error: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Receiving Messages
    
    /// Recursively listen for incoming WebSocket messages.
    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                // Continue listening
                self.receiveMessage()
                
            case .failure(let error):
                self.logger.error("WebSocket receive error: \(error.localizedDescription)")
                self.handleDisconnection()
            }
        }
    }
    
    /// Parse and dispatch a received JSON message.
    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            logger.warning("Received invalid message: \(text.prefix(100))")
            return
        }
        
        logger.info("Received message: \(type)")
        
        // Dispatch on main queue for delegate callbacks that update UI
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            switch type {
            case "joined":
                let room = json["room"] as? String ?? ""
                self.delegate?.signaling(self, didJoinRoom: room)
                
            case "create-offer":
                self.delegate?.signalingDidRequestOffer(self)
                
            case "answer":
                if let sdp = json["sdp"] as? String {
                    self.delegate?.signaling(self, didReceiveAnswer: sdp)
                }
                
            case "ice-candidate":
                if let candidate = json["candidate"] as? String {
                    let sdpMLineIndex = json["sdpMLineIndex"] as? Int32 ?? 0
                    let sdpMid = json["sdpMid"] as? String
                    self.delegate?.signaling(self, didReceiveCandidate: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
                }
                
            case "peer-joined":
                self.delegate?.signalingDidReceivePeerJoined(self)
                
            case "peer-left":
                self.delegate?.signalingDidReceivePeerLeft(self)
                
            case "ping":
                self.sendPong()
                
            case "error":
                let message = json["message"] as? String ?? "Unknown error"
                self.delegate?.signaling(self, didReceiveError: message)
                
            default:
                self.logger.warning("Unknown message type: \(type)")
            }
        }
    }
    
    // MARK: - Reconnection
    
    /// Handle unexpected disconnection with exponential backoff reconnect.
    private func handleDisconnection() {
        queue.async { [weak self] in
            guard let self = self, self.shouldReconnect, let url = self.serverURL else { return }
            
            DispatchQueue.main.async {
                self.isConnected = false
            }
            
            self.webSocket?.cancel(with: .abnormalClosure, reason: nil)
            self.webSocket = nil
            
            // Exponential backoff: 1s, 2s, 4s, 8s, ... capped at 30s
            let delay = min(pow(2.0, Double(self.reconnectAttempt)), self.maxReconnectDelay)
            self.reconnectAttempt += 1
            
            self.logger.info("Reconnecting in \(delay)s (attempt \(self.reconnectAttempt))")
            
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.shouldReconnect else { return }
                self.internalConnect(to: url)
            }
            self.reconnectWorkItem = workItem
            self.queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension SignalingService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        logger.info("WebSocket connection opened")
        reconnectAttempt = 0
        
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = true
        }
        
        // Automatically send join upon connection
        sendJoin()
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        logger.info("WebSocket closed: code=\(closeCode.rawValue), reason=\(reasonString)")
        handleDisconnection()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            logger.error("URLSession task error: \(error.localizedDescription)")
            handleDisconnection()
        }
    }
}
