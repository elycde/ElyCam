// ConnectionState.swift
// ElyCam - Camera Streaming App
//
// Unified connection state enum representing the full lifecycle
// from disconnected → connecting → signaling → negotiating → streaming.

import SwiftUI

/// Represents the current state of the signaling + WebRTC pipeline.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case signalingConnected
    case negotiating
    case streaming
    case error(String)
    
    // MARK: - Display Properties
    
    /// User-facing status text.
    var displayText: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting…"
        case .signalingConnected:
            return "Waiting for viewer"
        case .negotiating:
            return "Negotiating…"
        case .streaming:
            return "Live"
        case .error(let message):
            return "Error: \(message)"
        }
    }
    
    /// Status indicator color for the UI dot.
    var color: Color {
        switch self {
        case .disconnected:
            return .gray
        case .connecting:
            return .yellow
        case .signalingConnected:
            return .orange
        case .negotiating:
            return .yellow
        case .streaming:
            return .green
        case .error:
            return .red
        }
    }
    
    /// Whether signaling is at least connected (for UI gating).
    var isConnected: Bool {
        switch self {
        case .signalingConnected, .negotiating, .streaming:
            return true
        default:
            return false
        }
    }
    
    /// Whether the full pipeline is actively streaming.
    var isStreaming: Bool {
        self == .streaming
    }
    
    // MARK: - Equatable
    
    static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.signalingConnected, .signalingConnected),
             (.negotiating, .negotiating),
             (.streaming, .streaming):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}
