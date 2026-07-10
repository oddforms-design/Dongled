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
        case scanning, connecting, active(_ connectedDeviceIDs: [String])
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

    // True while a session is running with at least one input
    var hasValidSession: Bool {
        sessionQueue.sync {
            guard let session = captureSession else { return false }
            return session.isRunning && !session.inputs.isEmpty
        }
    }

    // MARK: - Authorize Capture
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
    // MARK: - Begin Discovery
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
    // MARK: - Configure & Start Session
    // Initializes a new AVCaptureSession and set device inputs
    private func configureSession(with device: AVCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let session = AVCaptureSession()
            session.beginConfiguration()

            /// Hand format control to selectBestFormat on mac instead of the default `.high` preset
            if self.isRunningOnMac() {
                session.sessionPreset = .inputPriority
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                    print("Added device input")
                }
            } catch {
                print("Failed to add device input: \(error)")
            }

            /// Select the best format for Mac devices
            if self.isRunningOnMac() {
                self.selectBestFormat(for: device)
            }

            session.commitConfiguration()

            self.captureSession = session
            self.startSession()
            self.audioManager.startEngineInputPassThrough()
        }
    }

    // MARK: - Start Session
    // Validates the device graph, then starts the session running
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
            DispatchQueue.main.async { self.updateState(.active(connectedInputIDs)) }
        }
    }
    // MARK: - Attach Preview
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

    // Keeps the preview layer matched to its hosting view during window resize or rotation.
    func layoutPreview(in view: UIView) {
        guard let layer = previewLayer, layer.superlayer === view.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = view.bounds
        layer.position = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        CATransaction.commit()
    }

    // Applies mirroring and rotation to the preview connection
    private func transformPreviewLayer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let layer = self.previewLayer,
                  let connection = layer.connection else { return }

            if self.isRunningOnMac() {
                /// Mac: no layer transform.
                if connection.automaticallyAdjustsVideoMirroring {
                    connection.automaticallyAdjustsVideoMirroring = false
                }
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = false
                }

                /// The Mac window never physically rotates, so the upright angle is constant.
                let macAngle: CGFloat = 0
                if connection.isVideoRotationAngleSupported(macAngle) {
                    connection.videoRotationAngle = macAngle
                }
            } else {
                /// iPad: cancel default mirroring with a layer flip, rotate via the coordinator
                layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))

                if let coordinator = self.rotationCoordinator {
                    let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                    if connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                    }
                }
            }

            /// Force layer to re-layout and render immediately to avoid last minute flip
            layer.frame = layer.superlayer?.bounds ?? .zero
            layer.setNeedsDisplay()
        }
    }

    // MARK: - macOS Helpers
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

        /// If there there is only one device, there is only one choice.  Auto-select!
        if uniqueDevices.count == 1,
           let autoSelectedDevice = uniqueDevices.first {
            print("Auto-selecting device! Booting…")
            selectDevice(autoSelectedDevice)
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
                    self?.selectDevice(uniqueDevice)
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

    // Boots the chosen device after confirming it is still connected
    private func selectDevice(_ device: AVCaptureDevice) {
        currentDevicePicker = nil
        updateState(.connecting)
        sessionQueue.asyncAfter(deadline: .now() + 2.2) {
            let nowDevices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external],
                mediaType: .video,
                position: .unspecified
            ).devices
            guard nowDevices.contains(where: { $0.uniqueID == device.uniqueID }) else {
                print("Device Removed. Aborting...")
                DispatchQueue.main.async {
                    self.updateState(.scanning)
                }
                return
            }
            self.configureSession(with: device)
        }
    }

    // Attempt to select the best format, preferring 16:9 aspect ratios, then pixel throughput
    private func selectBestFormat(for device: AVCaptureDevice) {
        let formats = device.formats
        var formatGroups: [String: [String]] = [:]

        /// Track the winning format and its stats as we loop through candidates
        var bestFormat: AVCaptureDevice.Format?
        var bestWidth: Int32 = 0
        var bestHeight: Int32 = 0
        var bestFrameRate: Float64 = 0
        var bestScore: Float64 = 0
        var bestRank: Int = -1
        var bestFourCC: String = ""
        var bestIs16x9 = false

        for format in formats {
            let desc = format.formatDescription

            /// Pull the pixel dimensions from the format descriptor
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            let width = dimensions.width
            let height = dimensions.height

            /// Decode the pixel format as a human-readable FourCC string (e.g. "420v", "BGRA")
            /// The raw value is a 32-bit int where each byte is one ASCII character
            let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
            let fourCC = String(format: "%c%c%c%c",
                                (mediaSubType >> 24) & 0xFF,
                                (mediaSubType >> 16) & 0xFF,
                                (mediaSubType >> 8) & 0xFF,
                                mediaSubType & 0xFF)

            /// Get the framerate ceiling
            let maxRate = format.videoSupportedFrameRateRanges
                .map { $0.maxFrameRate }
                .max() ?? 0

            /// Score = total pixels per second. Higher is better.
            /// This single number lets us compare very different formats (4K30 vs 1080p120, etc.)
            let score = Float64(width) * Float64(height) * maxRate
            let rank = formatRank(fourCC)

            /// Most HDMI sources are 16:9; a dongle's taller modes (1920×1200 etc.) can
            /// out-score 1080p60 while its scaler squishes a 16:9 input to fit them
            let is16x9 = (width * 9 == height * 16)

            formatGroups["\(width)×\(height) @ \(maxRate) fps", default: []].append(fourCC)

            /// Prefer 16:9 over other aspect ratios, then the best score,
            /// then break score ties with the preferred pixel format
            let candidateWins: Bool
            if is16x9 != bestIs16x9 {
                candidateWins = is16x9
            } else if score != bestScore {
                candidateWins = score > bestScore
            } else {
                candidateWins = rank > bestRank
            }

            if candidateWins {
                bestFormat = format
                bestWidth = width
                bestHeight = height
                bestFrameRate = maxRate
                bestScore = score
                bestRank = rank
                bestFourCC = fourCC
                bestIs16x9 = is16x9
            }
        }
        
        /// Print all formats grouped by resolution and frame rate
        for (key, fourccs) in formatGroups {
            print("  Format: \(key) [\(fourccs.joined(separator: ", "))]")
        }

        /// If no format was found at all bail out
        guard let selectedFormat = bestFormat else {
            print("No suitable format found. Using device default.")
            return
        }

        do {
            /// AVCaptureDevice settings must be changed inside a lock/unlock pair
            try device.lockForConfiguration()
            device.activeFormat = selectedFormat

            /// Pin both the min and max frame duration to the same value to lock in a fixed frame rate.
            /// We use minFrameDuration from the rate range rather than computing ourselves to prevent NTSC rounding issues
            if let bestRange = selectedFormat.videoSupportedFrameRateRanges
                .max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                device.activeVideoMinFrameDuration = bestRange.minFrameDuration
                device.activeVideoMaxFrameDuration = bestRange.minFrameDuration
            }
            device.unlockForConfiguration()
            print("Selected format: \(bestWidth)×\(bestHeight) @ \(bestFrameRate) fps [\(bestFourCC)]")
        } catch {
            print("Failed to set device format: \(error)")
        }
    }
    /// Rank pixel formats. Higher is better. Score ties are broken by this rank. We prioritize metal-native over chroma.
    private func formatRank(_ fourCC: String) -> Int {
        switch fourCC {
        /// 4:2:0 — Metal-native
        case "x420": return 10  /// 10-bit 4:2:0, Metal-capable on Apple Silicon
        case "420v": return 9   /// Matches HDMI source output
        case "420f": return 8   /// full range version
        case "2vuy": return 7   /// 4:2:2's rank lower
        case "yuvs": return 6
        case "yuv2": return 6
        case "v210": return 5
        case "BGRA": return 4   /// Memory-heavy
        case "2BGR": return 3
        case "h264": return 2   /// Decode formats rank lowest
        case "HEVC", "hvc1": return 2
        case "dmb1", "MJPG": return 1

        default: return 0
        }
    }
    // Check if running on macOS either via Designed for iPad or Catalyst
    func isRunningOnMac() -> Bool {
        return ProcessInfo.processInfo.isiOSAppOnMac || NSClassFromString("NSApplication") != nil
    }

    // MARK: - Teardown

    // Stops the session, removes its inputs/outputs, and stops audio
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

    // True if a device with this ID is still connected
    private func isDeviceStillConnected(withID id: String) -> Bool {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.contains { $0.uniqueID == id }
    }

    // Publishes state changes to the delegate on the main thread
    private func updateState(_ state: State) {
        DispatchQueue.main.async {
            self.state = state
            self.delegate?.captureManager(self, didUpdate: state)
        }
    }
}
