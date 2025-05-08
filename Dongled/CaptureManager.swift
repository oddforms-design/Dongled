//
//  CaptureManager.swift
//  Dongled
//
//  Created by Charles Sheppa on 5/5/24.
//

import AVFoundation
import UIKit
/// Delegate to report UI state changes. ViewController only handles the UI swaps.
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

    // Begins session setup after checking permissions and discovering device
    func setupCaptureSession() {
        checkVideoPermission { [weak self] granted in
            guard let self = self else { return }
            self.updateState(.scanning)
            guard granted else { return }

            self.discoverDevice { device in
                guard let device = device else {
                    print("No external video device found. Remaining idle.")
                    self.updateState(.scanning)
                    return
                }
                /// Wait for hardware to finish booting
                self.updateState(.connecting)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                    self.configureSession(with: device)
                }
            }
        }
    }

    // Stops and deallocates the current capture session
    func teardownSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession?.stopRunning()
            self.captureSession?.inputs.forEach { self.captureSession?.removeInput($0) }
            self.captureSession = nil
        }
    }

    // Handles teardown and cleanup when device is disconnected
    func deviceDisconnected(for device: AVCaptureDevice) {
        print("Device disconnected: \(device.localizedName) [modelID: \(device.modelID)]")
        updateState(.scanning)
        teardownSession()
        audioManager.stopEnginePassThrough()
    }

    // Stops video and audio when app enters background
    func handleDidEnterBackground() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
        }
        audioManager.stopEnginePassThrough()
    }

    // Re-evaluates device state and reinitializes session when app returns to foreground
    func handleWillEnterForeground() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }

            /// Always re-discover
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external], mediaType: .video, position: .unspecified
            )
            /// No device, don't start
            if discovery.devices.isEmpty {
                print("No external device found. Staying in .scanning.")
                DispatchQueue.main.async {
                    self.updateState(.scanning)
                }
            /// Main startup begins here
            } else {
                print("Device Found!")
                self.teardownSession()
                DispatchQueue.main.async {
                    self.setupCaptureSession()
                }
            }
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

        transformPreviewLayer()
    }

    // MARK: - Private Utilities

    // Requests video capture permission if needed
    private func checkVideoPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // Finds and returns the first available external video device
    private func discoverDevice(completion: @escaping (AVCaptureDevice?) -> Void) {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        )
        for device in discovery.devices {
            print("Available device: \(device.localizedName) [modelID: \(device.modelID)]")
            //self.updateState(.connecting)
        }
        completion(discovery.devices.first)
    }

    // Initializes a new AVCaptureSession with the specified device input
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
            self.audioManager.startEngineInputPassThrough()
            self.updateState(.active)
        }
    }

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

    // Applies mirroring and rotation to the preview layer
    private func transformPreviewLayer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let layer = self.previewLayer,
                  let connection = layer.connection else { return }
            
            /// Defualt Mirroring Off
            layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))

            /// Rotation
            if let coordinator = self.rotationCoordinator {
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
        }
    }

    // Dispatches a UI state change to the delegate
    private func updateState(_ state: State) {
        DispatchQueue.main.async {
            self.delegate?.captureManager(self, didUpdate: state)
        }
    }
}
