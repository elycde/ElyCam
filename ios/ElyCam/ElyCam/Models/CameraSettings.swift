// CameraSettings.swift
// ElyCam - Camera Streaming App
//
// Persistent camera and connection configuration model.
// Uses @Published properties with manual Codable conformance
// for automatic UserDefaults persistence.

import Foundation
import Combine

// MARK: - Resolution

/// Supported video capture resolutions.
enum Resolution: String, CaseIterable, Codable, Sendable {
    case uhd4K = "4K"
    case fullHD = "1080p"
    case hd720 = "720p"
    
    var width: Int {
        switch self {
        case .uhd4K: return 3840
        case .fullHD: return 1920
        case .hd720: return 1280
        }
    }
    
    var height: Int {
        switch self {
        case .uhd4K: return 2160
        case .fullHD: return 1080
        case .hd720: return 720
        }
    }
}

// MARK: - Stabilization

/// Video stabilization modes mapping to AVCaptureVideoStabilizationMode.
enum Stabilization: String, CaseIterable, Codable, Sendable {
    case off = "Off"
    case standard = "Standard"
    case cinematic = "Cinematic"
}

// MARK: - Camera Position

/// Physical camera selection.
enum CameraPosition: String, CaseIterable, Codable, Sendable {
    case back = "Back"
    case front = "Front"
}

// MARK: - Camera Settings

/// Observable settings model with automatic UserDefaults persistence.
/// All connection and capture parameters are stored here and survive app restarts.
final class CameraSettings: ObservableObject {
    
    // MARK: Connection Settings
    
    /// Signaling server IP address (LAN).
    @Published var serverAddress: String = "192.168.1.100" {
        didSet { save() }
    }
    
    /// Signaling server WebSocket port.
    @Published var serverPort: Int = 8080 {
        didSet { save() }
    }
    
    /// Room name used as camera identifier on the signaling server.
    @Published var roomName: String = "cam1" {
        didSet { save() }
    }
    
    // MARK: Video Settings
    
    /// Target capture resolution.
    @Published var resolution: Resolution = .uhd4K {
        didSet { save() }
    }
    
    /// Target capture frame rate.
    @Published var fps: Int = 60 {
        didSet { save() }
    }
    
    /// Video stabilization mode.
    @Published var stabilization: Stabilization = .off {
        didSet { save() }
    }
    
    // MARK: Audio Settings
    
    /// Whether to include an audio track in the WebRTC stream.
    @Published var audioEnabled: Bool = false {
        didSet { save() }
    }
    
    // MARK: Camera Settings
    
    /// Which physical camera to use.
    @Published var cameraPosition: CameraPosition = .back {
        didSet { save() }
    }
    
    // MARK: - UserDefaults Persistence
    
    private static let storageKey = "com.elycde.elycam.settings"
    
    /// Codable wrapper to persist @Published properties.
    private struct StorageData: Codable {
        var serverAddress: String
        var serverPort: Int
        var roomName: String
        var resolution: Resolution
        var fps: Int
        var stabilization: Stabilization
        var audioEnabled: Bool
        var cameraPosition: CameraPosition
    }
    
    init() {
        load()
    }
    
    /// Load saved settings from UserDefaults, keeping defaults if nothing saved.
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(StorageData.self, from: data) else {
            return
        }
        // Assign without triggering didSet saves (we're loading)
        serverAddress = stored.serverAddress
        serverPort = stored.serverPort
        roomName = stored.roomName
        resolution = stored.resolution
        fps = stored.fps
        stabilization = stored.stabilization
        audioEnabled = stored.audioEnabled
        cameraPosition = stored.cameraPosition
    }
    
    /// Persist current settings to UserDefaults.
    private func save() {
        let stored = StorageData(
            serverAddress: serverAddress,
            serverPort: serverPort,
            roomName: roomName,
            resolution: resolution,
            fps: fps,
            stabilization: stabilization,
            audioEnabled: audioEnabled,
            cameraPosition: cameraPosition
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
    
    /// Computed WebSocket URL for the signaling server.
    var websocketURL: URL? {
        URL(string: "ws://\(serverAddress):\(serverPort)/ws/\(roomName)")
    }
    
    /// Human-readable resolution + FPS label for the status bar.
    var qualityLabel: String {
        "\(resolution.rawValue) \(fps)fps"
    }
}
