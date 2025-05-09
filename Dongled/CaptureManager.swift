//
//  CaptureManager.swift
//  Dongled
//
//  Created by Charles Sheppa on 5/5/24.
//

import AVFoundation
import UIKit

// Delegate to report UI state changes. ViewController only handles the UI swaps.
protocol CaptureManagerDelegate: AnyObject {
    func captureManager(_ manager: CaptureManager, didUpdate state: CaptureManager.State)
}

final class CaptureManager {
    /// UI States
    enum State {
        case scanning, connecting, active
    }

    // MARK: - Properties

    weak var delegate: CaptureManagerDelegate?
    private let sessionQueue = DispatchQueue(label: "com.Dongled.captureSession")
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private let audioManager = AudioManager()

    // MARK: - Public Session Lifecycle
    // Start Here to always evaluate permissions before attempting anything
    func authorizeCapture() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            /// Already have permission → discover or scan
            sessionQueue.async { [weak self] in
                self?.startCapture()
            }

        case .notDetermined:
                // First‐time camera prompt
                AVCaptureDevice.requestAccess(for: .video) { grantedVideo in
                    DispatchQueue.main.async {
                        guard grantedVideo else {
                            // User denied video → stay in scanning
                            self.updateState(.scanning)
                            return
                        }
                        print("Got Video")
                        // Video granted → now prompt mic
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            DispatchQueue.main.async {
                                print("Got Audio")
                                self.updateState(.scanning)
                            }
                        }
                    }
                }

        case .denied, .restricted:
            // Permission denied → show scanning UI with disabled camera message
            updateState(.scanning)

        @unknown default:
            // Future-proof fallback → show scanning UI
            updateState(.scanning)
        }
    }
    
    // We are authorized here so begin discovery or wait for devices
    private func startCapture() {
        /// Return if we are already running in a race for some weird connection issues
        if let session = captureSession, session.isRunning {
            print("Warn: Killed a duplicate session")
            return
        }
        // Discover external video devices
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )

        // No device → remain scanning
        guard let device = discovery.devices.first else {
            print("No external video device found. Remaining idle.")
            DispatchQueue.main.async { self.updateState(.scanning) }
            return
        }

        // Device found → update UI, wait for hardware to finish booting, then configure
        print("Device Found! Booting…")
        updateState(.connecting)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.configureSession(with: device)
        }
    }
    
    // Initializes a new AVCaptureSession and set device inputs
    private func configureSession(with device: AVCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let session = AVCaptureSession()
            session.beginConfiguration()
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                    print("Added device input")
                }
            } catch {
                print("Failed to add device input: \(error)")
            }
            session.commitConfiguration()

            self.captureSession = session
            self.startSession()
            self.updateState(.active)
            self.audioManager.startEngineInputPassThrough()
        }
    }

    // Binds an AVCaptureVideoPreviewLayer to view and applies transforms
    func attachPreview(to view: UIView) {
        guard let session = captureSession else { return }
        previewLayer?.removeFromSuperlayer()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer = layer
        layer.frame = view.bounds
        layer.videoGravity = .resizeAspect
        view.layer.insertSublayer(layer, at: 0)
        print("Starting Video Preview Layer.")
        
        if let deviceInput = session.inputs.first as? AVCaptureDeviceInput {
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                device: deviceInput.device,
                previewLayer: layer
            )
        }
        
        /// We need to turn off mirroring becuase we aren't using the front-facing camera
        transformPreviewLayer()

        
    }
    
    // MARK: - Public Helpers
    // Stops and deallocates the current capture session
    func teardownSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession?.stopRunning()
            self.captureSession?.inputs.forEach { self.captureSession?.removeInput($0) }
            self.captureSession = nil
        }
        audioManager.stopEnginePassThrough()
        updateState(.scanning)
    }
    // MARK: - Private Helpers
    // Starts the capture session if not already running
    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self,
                  let session = self.captureSession,
                  !session.isRunning,
                  !session.inputs.isEmpty else { return }
            session.startRunning()
        }
    }
    // Discretely request microphone access
    private func requestMicrophonePermission() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        // If we've never asked, ask now. Otherwise just refresh UI.
        if micStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateState(.scanning)
                }
            }
        } else {
            // Already determined (granted or denied) → refresh scanning UI immediately
            DispatchQueue.main.async { self.updateState(.scanning) }
        }
    }
    // Applies mirroring and rotation to the preview layer
    private func transformPreviewLayer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let layer = self.previewLayer,
                  let connection = layer.connection else { return }

            /// Default mirroring off
            layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))

            /// Rotation
            if let coordinator = self.rotationCoordinator {
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
            /// Force layer to re-layout and render immediately to avoid last minute flip
                    layer.frame = layer.superlayer?.bounds ?? .zero
                    layer.setNeedsDisplay()
        }
    }

    // Dispatches a UI state change to the delegate
    private func updateState(_ state: State) {
        DispatchQueue.main.async {
            self.delegate?.captureManager(self, didUpdate: state)
        }
    }
}
