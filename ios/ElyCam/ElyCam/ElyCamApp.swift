// ElyCamApp.swift
// ElyCam - Camera Streaming App
//
// Main app entry point. Manages the top-level navigation between
// the ConnectView (initial setup) and CameraView (streaming).
// Uses @StateObject for the shared CameraSettings that persists
// user preferences across app launches.

import SwiftUI

@main
struct ElyCamApp: App {
    
    /// Shared settings persisted via UserDefaults.
    @StateObject private var settings = CameraSettings()
    
    /// Whether we've connected and should show the camera view.
    @State private var isConnected = false
    
    var body: some Scene {
        WindowGroup {
            Group {
                if isConnected {
                    CameraView(settings: settings) {
                        // On disconnect, return to connect screen
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isConnected = false
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    ConnectView(settings: settings) {
                        // On connect, navigate to camera view
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isConnected = true
                        }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isConnected)
            .preferredColorScheme(.dark)
        }
    }
}
