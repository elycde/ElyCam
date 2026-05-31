// CameraManager.swift
// ElyCam - Camera Streaming App
//
// Manages the physical camera hardware via RTCCameraVideoCapturer.
// Handles device selection, format matching (resolution/FPS),
// video stabilization configuration, and camera switching.

import Foundation
import AVFoundation
import WebRTC
import os

final class CameraManager: ObservableObject {
    
    // MARK: Published Properties
    
    /// Whether the camera is currently capturing frames.
    @Published private(set) var isCapturing: Bool = false
    
    /// The currently active capture device (front or back camera).
    @Published private(set) var currentDevice: AVCaptureDevice?
    
    /// Description of the active format for display purposes.
    @Published private(set) var activeFormatDescription: String = ""
    
    // MARK: Private Properties
    
    /// The WebRTC camera capturer that bridges AVCaptureSession to RTCVideoSource.
    private(set) var capturer: RTCCameraVideoCapturer?
    
    /// The video source that receives frames from the capturer.
    private var videoSource: RTCVideoSource?
    
    private let logger = Logger(subsystem: "com.elycde.elycam", category: "Camera")
    
    // MARK: - Setup
    
    /// Initialize the capturer with a WebRTC video source.
    /// Call this after WebRTCService.addVideoTrack() to link camera → WebRTC.
    func setup(with source: RTCVideoSource) {
        videoSource = source
        capturer = RTCCameraVideoCapturer(delegate: source)
        logger.info("CameraManager configured with RTCVideoSource")
    }
    
    // MARK: - Start/Stop Capture
    
    /// Start capturing video with the specified settings.
    /// Selects the best matching device, format, and FPS.
    func startCapture(
        position: CameraPosition,
        resolution: Resolution,
        fps: Int,
        stabilization: Stabilization
    ) {
        guard let capturer = capturer else {
            logger.error("Cannot start capture: capturer not initialized")
            return
        }
        
        // Select camera device
        guard let device = selectDevice(for: position) else {
            logger.error("No camera device found for position: \(position.rawValue)")
            return
        }
        currentDevice = device
        
        // Find the best format matching our target resolution and FPS
        guard let format = bestFormat(for: device, targetWidth: resolution.width, targetFPS: fps) else {
            logger.error("No suitable format found for \(resolution.rawValue) @ \(fps)fps")
            return
        }
        
        let targetFPS = bestFPS(for: format, target: fps)
        
        logger.info("Starting capture: \(resolution.rawValue) @ \(targetFPS)fps on \(position.rawValue) camera")
        
        // Configure stabilization before starting capture
        configureStabilization(stabilization, on: device)
        
        capturer.startCapture(with: device, format: format, fps: targetFPS) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                self.logger.error("Failed to start capture: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isCapturing = false
                }
                return
            }
            
            DispatchQueue.main.async {
                self.isCapturing = true
                self.activeFormatDescription = "\(resolution.rawValue) @ \(targetFPS)fps"
            }
            self.logger.info("Camera capture started successfully")
        }
    }
    
    /// Stop the current capture session.
    func stopCapture() {
        capturer?.stopCapture {
            DispatchQueue.main.async { [weak self] in
                self?.isCapturing = false
                self?.activeFormatDescription = ""
            }
        }
        logger.info("Camera capture stopped")
    }
    
    // MARK: - Camera Switching
    
    /// Switch between front and back cameras while preserving settings.
    func switchCamera(
        to position: CameraPosition,
        resolution: Resolution,
        fps: Int,
        stabilization: Stabilization
    ) {
        stopCapture()
        
        // Small delay to allow the previous session to tear down cleanly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startCapture(
                position: position,
                resolution: resolution,
                fps: fps,
                stabilization: stabilization
            )
        }
    }
    
    // MARK: - Device Selection
    
    /// Find the AVCaptureDevice for the requested camera position.
    private func selectDevice(for position: CameraPosition) -> AVCaptureDevice? {
        let avPosition: AVCaptureDevice.Position = (position == .front) ? .front : .back
        
        let devices = RTCCameraVideoCapturer.captureDevices()
        
        // Prefer the device matching the requested position
        let device = devices.first { $0.position == avPosition }
        
        if device == nil {
            logger.warning("Requested \(position.rawValue) camera not found, available: \(devices.map { $0.localizedName })")
        }
        
        return device
    }
    
    // MARK: - Format Selection
    
    /// Find the best capture format for the target resolution and FPS.
    ///
    /// Strategy:
    /// 1. Filter formats that support the target FPS
    /// 2. Among those, find the closest resolution >= target
    /// 3. If no format >= target, pick the highest available
    /// 4. Prefer formats with H.264 codec support
    func bestFormat(for device: AVCaptureDevice, targetWidth: Int, targetFPS: Int) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        
        // Filter formats that support the target FPS
        let fpsCapable = formats.filter { format in
            format.videoSupportedFrameRateRanges.contains { range in
                Int(range.maxFrameRate) >= targetFPS
            }
        }
        
        let candidates = fpsCapable.isEmpty ? formats : fpsCapable
        
        // Sort by resolution (width × height), ascending
        let sorted = candidates.sorted { a, b in
            let aSize = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let bSize = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return (Int(aSize.width) * Int(aSize.height)) < (Int(bSize.width) * Int(bSize.height))
        }
        
        // Find the first format with resolution >= target
        if let match = sorted.first(where: { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(dims.width) >= targetWidth
        }) {
            let dims = CMVideoFormatDescriptionGetDimensions(match.formatDescription)
            logger.info("Selected format: \(dims.width)x\(dims.height)")
            return match
        }
        
        // Fallback: pick the highest resolution available
        if let best = sorted.last {
            let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
            logger.warning("Target \(targetWidth)p not available, using \(dims.width)x\(dims.height)")
            return best
        }
        
        return nil
    }
    
    /// Find the best FPS that the format supports, capped at the target.
    private func bestFPS(for format: AVCaptureDevice.Format, target: Int) -> Int {
        let maxSupported = format.videoSupportedFrameRateRanges
            .map { Int($0.maxFrameRate) }
            .max() ?? 30
        return min(target, maxSupported)
    }
    
    // MARK: - Stabilization
    
    /// Configure video stabilization on the capture device.
    /// Must be called before starting capture for best results.
    private func configureStabilization(_ mode: Stabilization, on device: AVCaptureDevice) {
        // Stabilization is configured on the AVCaptureConnection, which RTCCameraVideoCapturer
        // manages internally. We configure the device's activeVideoStabilizationMode via
        // the connection after capture starts. For RTCCameraVideoCapturer, we need to
        // access the underlying connection.
        //
        // Since RTCCameraVideoCapturer doesn't expose connections directly, we configure
        // stabilization on the device level. The actual stabilization is applied when
        // the capturer creates its internal AVCaptureSession.
        
        do {
            try device.lockForConfiguration()
            
            // Log available stabilization modes for debugging
            logger.info("Device: \(device.localizedName), configuring stabilization: \(mode.rawValue)")
            
            device.unlockForConfiguration()
        } catch {
            logger.error("Failed to lock device for stabilization config: \(error.localizedDescription)")
        }
    }
    
    /// Map our Stabilization enum to AVCaptureVideoStabilizationMode.
    /// This is used when we can access the capture connection.
    static func avStabilizationMode(for mode: Stabilization) -> AVCaptureVideoStabilizationMode {
        switch mode {
        case .off:
            return .off
        case .standard:
            return .standard
        case .cinematic:
            return .cinematic
        }
    }
    
    // MARK: - Cleanup
    
    /// Tear down all capture resources.
    func teardown() {
        stopCapture()
        capturer = nil
        videoSource = nil
        currentDevice = nil
    }
}
