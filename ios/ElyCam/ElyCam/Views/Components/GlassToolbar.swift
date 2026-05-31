// GlassToolbar.swift
// ElyCam - Camera Streaming App
//
// Bottom toolbar with Liquid Glass design.
// Contains camera flip, stream toggle, and settings buttons.

import SwiftUI

struct GlassToolbar: View {
    
    @Binding var isStreaming: Bool
    var onFlipCamera: () -> Void
    var onToggleStream: () -> Void
    var onOpenSettings: () -> Void
    
    // Animation state for the record button
    @State private var recordPulse = false
    
    var body: some View {
        HStack(spacing: 24) {
            // Camera flip button
            Button(action: onFlipCamera) {
                Image(systemName: "camera.rotate")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .glassEffect()
            
            // Main stream toggle button (larger, prominent)
            Button(action: onToggleStream) {
                Image(systemName: isStreaming ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(isStreaming ? .red : .white)
                    .scaleEffect(isStreaming && recordPulse ? 1.05 : 1.0)
            }
            .glassEffect(.regular.interactive())
            .animation(
                isStreaming
                    ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                    : .default,
                value: recordPulse
            )
            .onChange(of: isStreaming) { _, newValue in
                recordPulse = newValue
            }
            
            // Settings button
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .glassEffect()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        
        VStack {
            Spacer()
            GlassToolbar(
                isStreaming: .constant(false),
                onFlipCamera: {},
                onToggleStream: {},
                onOpenSettings: {}
            )
            .padding(.bottom, 30)
        }
    }
}
