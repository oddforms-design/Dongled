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

final class CaptureManager: NSObject {
    /// UI States
    enum State {
        case scanning, connecting, active
    }

    // MARK: - Properties

    weak var delegate: CaptureManagerDelegate?
    private(set) var state: State = .scanning
    private let sessionQueue = DispatchQueue(label: "com.Dongled.captureSession")
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private let audioManager = AudioManager()
    private weak var currentDevicePicker: UIAlertController?
    private var lastPresentedDeviceIdentifiers = Set<String>()

    var hasValidSession: Bool {
        sessionQueue.sync {
            guard let session = captureSession else { return false }
            return session.isRunning && !session.inputs.isEmpty
        }
    }

    // MARK: - Public Session Lifecycle
    // Start Here to always evaluate permissions before attempting anything
    func authorizeCapture(from viewController: UIViewController) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            /// Already have permission → discover or scan
            if isRunningOnMac() {
                DispatchQueue.main.async {
                    self.setupCaptureSessionMacOS(from: viewController)
                }
            } else {
                sessionQueue.async { [weak self] in
                    self?.startCapture()
                }
            }

        case .notDetermined:
            /// First‐time camera prompt
            AVCaptureDevice.requestAccess(for: .video) { grantedVideo in
                DispatchQueue.main.async {
                    guard grantedVideo else {
                        /// User denied video → stay in scanning
                        self.updateState(.scanning)
                        return
                    }
                    print("Got Video")
                    /// Video granted → now prompt mic
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async {
                            print("Got Audio")
                            self.updateState(.scanning)
                            if self.isRunningOnMac() {
                                self.setupCaptureSessionMacOS(from: viewController)
                            } else {
                                self.sessionQueue.async {
                                    self.startCapture()
                                }
                            }
                        }
                    }
                }
            }

        case .denied, .restricted:
            /// Permission denied → show scanning UI with disabled camera message
            updateState(.scanning)

        @unknown default:
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
        /// Discover external video devices
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )

        /// No device → remain scanning
        guard let device = discovery.devices.first else {
            print("No external video device found. Remaining idle.")
            DispatchQueue.main.async { self.updateState(.scanning) }
            return
        }

        /// Device found → update UI, wait for hardware to finish booting, then configure
        print("Device Found! Booting…")
        updateState(.connecting)
        self.sessionQueue.asyncAfter(deadline: .now() + 2.2) {
            let nowDevices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external],
                mediaType: .video,
                position: .unspecified
            ).devices
            guard nowDevices.contains(where: { $0.uniqueID == device.uniqueID }) else {
                /// Device was unplugged during boot-up
                print("Device Removed. Aborting...")
                DispatchQueue.main.async { self.updateState(.scanning) }
                return
            }
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

    // MARK: - macOS Picker Flow

    // Simple picker UI for changing input on MacOS
    func setupCaptureSessionMacOS(from viewController: UIViewController) {
        print("Running on macOS")

        let allDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        ).devices
        for device in allDevices {
            print("""
            Device:
                name: \(device.localizedName)
                uniqueID: \(device.uniqueID)
                modelID: \(device.modelID)
                formats: \(device.formats.count)
            """)
        }

        let uniqueDevices = Dictionary(grouping: allDevices, by: \.modelID).compactMap { $0.value.first }

        let currentIdentifiers = Set(uniqueDevices.map { $0.uniqueID })
        let deviceListChanged = currentIdentifiers != lastPresentedDeviceIdentifiers
        lastPresentedDeviceIdentifiers = currentIdentifiers

        print("Devices found: \(uniqueDevices.map { $0.localizedName })")

        guard !uniqueDevices.isEmpty else {
            print("No devices found.")
            if let picker = currentDevicePicker, picker.presentingViewController != nil {
                picker.dismiss(animated: true)
                currentDevicePicker = nil
            }
            updateState(.scanning)
            return
        }

        let presentPicker: () -> Void = { [weak self, weak viewController] in
            guard let self = self, let viewController = viewController else { return }
            let alert = UIAlertController(
                title: NSLocalizedString("picker.title", comment: "Title for the video input picker on macOS."),
                message: NSLocalizedString("picker.message", comment: "Message shown in the video input picker on macOS."),
                preferredStyle: .actionSheet
            )

            for uniqueDevice in uniqueDevices {
                let action = UIAlertAction(title: uniqueDevice.localizedName, style: .default) { [weak self] _ in
                    print("Device Selected! Booting…")
                    self?.currentDevicePicker = nil
                    self?.updateState(.connecting)
                    self?.sessionQueue.asyncAfter(deadline: .now() + 2.2) {
                        let nowDevices = AVCaptureDevice.DiscoverySession(
                            deviceTypes: [.external],
                            mediaType: .video,
                            position: .unspecified
                        ).devices
                        guard nowDevices.contains(where: { $0.uniqueID == uniqueDevice.uniqueID }) else {
                            print("Device Removed. Aborting...")
                            DispatchQueue.main.async { self?.updateState(.scanning) }
                            return
                        }
                        self?.configureSession(with: uniqueDevice)
                    }
                }
                alert.addAction(action)
            }

            let cancelAction = UIAlertAction(title: NSLocalizedString("picker.cancel", comment: "Cancel action for the video input picker."), style: .cancel) { [weak self] _ in
                self?.currentDevicePicker = nil
            }
            alert.addAction(cancelAction)

            if let popover = alert.popoverPresentationController {
                popover.sourceView = viewController.view
                popover.sourceRect = CGRect(
                    x: viewController.view.bounds.midX,
                    y: viewController.view.bounds.midY,
                    width: 0,
                    height: 0
                )
                popover.permittedArrowDirections = []
            }

            self.currentDevicePicker = alert
            viewController.present(alert, animated: true)
        }

        if let picker = currentDevicePicker, picker.presentingViewController != nil {
            guard deviceListChanged else { return }
            picker.dismiss(animated: false) {
                presentPicker()
            }
        } else {
            presentPicker()
        }
    }

    func isRunningOnMac() -> Bool {
        return NSClassFromString("NSApplication") != nil
    }

    // MARK: - Public Helpers

    func teardownSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession?.stopRunning()
            self.captureSession?.inputs.forEach { self.captureSession?.removeInput($0) }
            self.captureSession?.outputs.forEach { self.captureSession?.removeOutput($0) }
            self.captureSession = nil
        }
        audioManager.stopEnginePassThrough()
        updateState(.scanning)
    }

    // MARK: - Private Helpers

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self,
                  let session = self.captureSession,
                  !session.isRunning,
                  !session.inputs.isEmpty else { return }
            let connectedInputIDs = session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device.uniqueID }
            guard connectedInputIDs.allSatisfy({ self.isDeviceStillConnected(withID: $0) }) else {
                print("Graph Error. Returning to scanning.")
                session.stopRunning()
                session.inputs.forEach { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }
                self.captureSession = nil
                DispatchQueue.main.async { self.updateState(.scanning) }
                return
            }
            session.startRunning()
            DispatchQueue.main.async { self.updateState(.active) }
        }
    }

    private func isDeviceStillConnected(withID id: String) -> Bool {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.contains { $0.uniqueID == id }
    }

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

    private func updateState(_ state: State) {
        DispatchQueue.main.async {
            self.state = state
            self.delegate?.captureManager(self, didUpdate: state)
        }
    }
}
