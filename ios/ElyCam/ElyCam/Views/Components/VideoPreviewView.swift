// VideoPreviewView.swift
// ElyCam - Camera Streaming App
//
// UIViewRepresentable wrapper for RTCMTLVideoView (Metal-backed WebRTC renderer).
// Displays the local camera preview by subscribing to the RTCVideoTrack.

import SwiftUI
@preconcurrency import WebRTC

struct VideoPreviewView: UIViewRepresentable {
    
    /// The video track to render. When this changes, the view re-subscribes.
    let videoTrack: RTCVideoTrack?
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = .black
        return view
    }
    
    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        // Remove from the previous track to avoid double-rendering
        if let previousTrack = context.coordinator.currentTrack {
            previousTrack.remove(uiView)
        }
        
        // Subscribe to the new track
        if let track = videoTrack {
            track.add(uiView)
            context.coordinator.currentTrack = track
        } else {
            context.coordinator.currentTrack = nil
        }
    }
    
    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        // Clean up: remove the view from any track it's subscribed to
        coordinator.currentTrack?.remove(uiView)
        coordinator.currentTrack = nil
    }
    
    // MARK: - Coordinator
    
    /// Tracks the currently subscribed video track for proper cleanup.
    class Coordinator {
        var currentTrack: RTCVideoTrack?
    }
}
