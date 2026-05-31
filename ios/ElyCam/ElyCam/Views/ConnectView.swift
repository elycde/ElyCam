// ConnectView.swift
// ElyCam - Camera Streaming App
//
// Initial connection screen with Liquid Glass design.
// Users enter server IP, port, and camera name to connect.
// Animated gradient background with glass card input form.

import SwiftUI

struct ConnectView: View {
    
    @ObservedObject var settings: CameraSettings
    var onConnect: () -> Void
    
    // Local editing state (committed to settings on connect)
    @State private var serverIP: String = ""
    @State private var serverPort: String = ""
    @State private var cameraName: String = ""
    
    // Animation state
    @State private var appeared = false
    @State private var gradientPhase: Double = 0
    @State private var isConnecting = false
    @State private var errorMessage: String?
    
    // Focus management
    @FocusState private var focusedField: Field?
    
    private enum Field: Hashable {
        case serverIP, port, cameraName
    }
    
    var body: some View {
        ZStack {
            // MARK: - Animated Background
            animatedBackground
            
            // MARK: - Content
            VStack(spacing: 32) {
                Spacer()
                
                // Logo
                logoSection
                
                Spacer()
                
                // Connection form
                connectionCard
                
                // Error message
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                
                // Connect button
                connectButton
                
                Spacer()
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            // Load saved settings into local state
            serverIP = settings.serverAddress
            serverPort = String(settings.serverPort)
            cameraName = settings.roomName
            
            // Trigger appear animation
            withAnimation(.easeOut(duration: 0.8)) {
                appeared = true
            }
        }
        .onTapGesture {
            focusedField = nil
        }
    }
    
    // MARK: - Subviews
    
    /// Slowly shifting dark gradient background.
    private var animatedBackground: some View {
        LinearGradient(
            colors: [
                Color.black,
                Color(white: 0.08),
                Color(white: 0.05),
                Color.black
            ],
            startPoint: UnitPoint(x: 0.5 + sin(gradientPhase) * 0.3, y: 0),
            endPoint: UnitPoint(x: 0.5 + cos(gradientPhase) * 0.3, y: 1)
        )
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: true)) {
                gradientPhase = .pi * 2
            }
        }
    }
    
    /// App logo with SF Symbol and title.
    private var logoSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white)
                .padding(20)
                .glassEffect(in: .circle)
            
            Text("ElyCam")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            
            Text("Zero-Latency Camera Streaming")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
        .scaleEffect(appeared ? 1.0 : 0.8)
        .opacity(appeared ? 1.0 : 0)
    }
    
    /// Glass card containing the connection input fields.
    private var connectionCard: some View {
        VStack(spacing: 16) {
            // Server IP
            HStack {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                TextField("Server IP", text: $serverIP)
                    .keyboardType(.decimalPad)
                    .textContentType(.URL)
                    .focused($focusedField, equals: .serverIP)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(in: .rect(cornerRadius: 12))
            
            // Port
            HStack {
                Image(systemName: "number")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                TextField("Port", text: $serverPort)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .port)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(in: .rect(cornerRadius: 12))
            
            // Camera Name (Room)
            HStack {
                Image(systemName: "camera")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                TextField("Camera Name", text: $cameraName)
                    .focused($focusedField, equals: .cameraName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(in: .rect(cornerRadius: 12))
        }
        .padding(20)
        .scaleEffect(appeared ? 1.0 : 0.9)
        .opacity(appeared ? 1.0 : 0)
        .animation(.easeOut(duration: 0.8).delay(0.2), value: appeared)
    }
    
    /// Connect button with glass effect and loading state.
    private var connectButton: some View {
        Button(action: handleConnect) {
            HStack(spacing: 8) {
                if isConnecting {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                }
                Text(isConnecting ? "Connecting…" : "Connect")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .disabled(isConnecting || !isFormValid)
        .glassEffect(in: .capsule)
        .opacity(isFormValid ? 1.0 : 0.5)
        .scaleEffect(appeared ? 1.0 : 0.9)
        .opacity(appeared ? 1.0 : 0)
        .animation(.easeOut(duration: 0.8).delay(0.4), value: appeared)
    }
    
    // MARK: - Logic
    
    /// Basic form validation.
    private var isFormValid: Bool {
        !serverIP.trimmingCharacters(in: .whitespaces).isEmpty &&
        !serverPort.trimmingCharacters(in: .whitespaces).isEmpty &&
        !cameraName.trimmingCharacters(in: .whitespaces).isEmpty &&
        Int(serverPort) != nil
    }
    
    /// Commit settings and trigger connection.
    private func handleConnect() {
        focusedField = nil
        errorMessage = nil
        
        // Validate and save to settings
        guard let port = Int(serverPort) else {
            errorMessage = "Invalid port number"
            return
        }
        
        settings.serverAddress = serverIP.trimmingCharacters(in: .whitespaces)
        settings.serverPort = port
        settings.roomName = cameraName.trimmingCharacters(in: .whitespaces)
        
        guard settings.websocketURL != nil else {
            errorMessage = "Invalid server address"
            return
        }
        
        onConnect()
    }
}

// MARK: - Preview

#Preview {
    ConnectView(settings: CameraSettings()) {
        print("Connect tapped")
    }
}
