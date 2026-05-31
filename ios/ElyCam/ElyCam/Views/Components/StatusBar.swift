// StatusBar.swift
// ElyCam - Camera Streaming App
//
// Top overlay status bar with Liquid Glass design.
// Shows connection state (pulsing dot), room name, and quality info.

import SwiftUI

// MARK: - Pulse Animation Modifier

/// Applies a pulsing scale animation to indicate active streaming.
struct PulseModifier: ViewModifier {
    var isActive: Bool
    @State private var isPulsing = false
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(isActive && isPulsing ? 1.4 : 1.0)
            .opacity(isActive && isPulsing ? 0.7 : 1.0)
            .animation(
                isActive
                    ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onChange(of: isActive) { _, newValue in
                isPulsing = newValue
            }
            .onAppear {
                isPulsing = isActive
            }
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    var connectionState: ConnectionState
    var roomName: String
    var resolution: String
    var fps: Int
    
    var body: some View {
        HStack(spacing: 12) {
            // Connection indicator dot
            Circle()
                .fill(connectionState.color)
                .frame(width: 8, height: 8)
                .modifier(PulseModifier(isActive: connectionState == .streaming))
            
            // Room name
            Text(roomName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            
            Spacer()
            
            // Quality info
            Text("\(resolution) \(fps)fps")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(in: .capsule)
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        
        VStack(spacing: 20) {
            StatusBar(
                connectionState: .streaming,
                roomName: "cam1",
                resolution: "4K",
                fps: 60
            )
            
            StatusBar(
                connectionState: .connecting,
                roomName: "cam2",
                resolution: "1080p",
                fps: 30
            )
            
            StatusBar(
                connectionState: .error("Connection lost"),
                roomName: "cam1",
                resolution: "720p",
                fps: 30
            )
        }
        .padding()
    }
}
