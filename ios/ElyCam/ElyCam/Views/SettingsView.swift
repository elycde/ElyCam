// SettingsView.swift
// ElyCam - Camera Streaming App
//
// Settings sheet with Liquid Glass sections for video, audio,
// stabilization, and camera configuration. Presented as a sheet
// from CameraView. Changes apply in real-time where possible.

import SwiftUI

struct SettingsView: View {
    
    @ObservedObject var settings: CameraSettings
    @Environment(\.dismiss) private var dismiss
    
    /// Whether the app is currently streaming (disables certain settings).
    var isStreaming: Bool
    
    /// Callback when settings change that require camera restart.
    var onCameraSettingsChanged: (() -> Void)?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    
                    // MARK: - Server Section
                    serverSection
                    
                    // MARK: - Video Section
                    videoSection
                    
                    // MARK: - Stabilization Section
                    stabilizationSection
                    
                    // MARK: - Audio Section
                    audioSection
                    
                    // MARK: - Camera Section
                    cameraSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color.black.opacity(0.9))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    
    // MARK: - Server Section
    
    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "server.rack", title: "Server")
            
            VStack(spacing: 8) {
                settingsRow(label: "IP Address") {
                    TextField("192.168.1.100", text: $settings.serverAddress)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(isStreaming)
                }
                
                Divider().opacity(0.3)
                
                settingsRow(label: "Port") {
                    TextField("8080", value: $settings.serverPort, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .disabled(isStreaming)
                }
                
                Divider().opacity(0.3)
                
                settingsRow(label: "Room Name") {
                    TextField("cam1", text: $settings.roomName)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(isStreaming)
                }
            }
            .padding(16)
            .glassEffect(in: .rect(cornerRadius: 16))
            
            if isStreaming {
                Text("Server settings are locked while streaming")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }
    
    // MARK: - Video Section
    
    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "video", title: "Video")
            
            VStack(spacing: 16) {
                // Resolution Picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Resolution")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Picker("Resolution", selection: $settings.resolution) {
                        ForEach(Resolution.allCases, id: \.self) { res in
                            Text(res.rawValue).tag(res)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Divider().opacity(0.3)
                
                // FPS Picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Frame Rate")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Picker("FPS", selection: $settings.fps) {
                        Text("60").tag(60)
                        Text("30").tag(30)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(16)
            .glassEffect(in: .rect(cornerRadius: 16))
        }
        .onChange(of: settings.resolution) { _, _ in
            onCameraSettingsChanged?()
        }
        .onChange(of: settings.fps) { _, _ in
            onCameraSettingsChanged?()
        }
    }
    
    // MARK: - Stabilization Section
    
    private var stabilizationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "gyroscope", title: "Stabilization")
            
            VStack(spacing: 8) {
                Picker("Stabilization", selection: $settings.stabilization) {
                    ForEach(Stabilization.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(16)
            .glassEffect(in: .rect(cornerRadius: 16))
        }
        .onChange(of: settings.stabilization) { _, _ in
            onCameraSettingsChanged?()
        }
    }
    
    // MARK: - Audio Section
    
    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "mic", title: "Audio")
            
            HStack {
                Label("Microphone", systemImage: "mic.fill")
                    .foregroundStyle(.primary)
                Spacer()
                Toggle("", isOn: $settings.audioEnabled)
                    .labelsHidden()
            }
            .padding(16)
            .glassEffect(in: .rect(cornerRadius: 16))
        }
    }
    
    // MARK: - Camera Section
    
    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "camera", title: "Camera")
            
            VStack(spacing: 8) {
                Picker("Camera", selection: $settings.cameraPosition) {
                    ForEach(CameraPosition.allCases, id: \.self) { pos in
                        Text(pos.rawValue).tag(pos)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(16)
            .glassEffect(in: .rect(cornerRadius: 16))
        }
        .onChange(of: settings.cameraPosition) { _, _ in
            onCameraSettingsChanged?()
        }
    }
    
    // MARK: - Helper Views
    
    /// Section header with icon and title.
    private func sectionHeader(icon: String, title: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.leading, 4)
    }
    
    /// Standard settings row with label and trailing content.
    private func settingsRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.primary)
            Spacer()
            content()
                .frame(maxWidth: 160)
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView(
        settings: CameraSettings(),
        isStreaming: false
    )
}
