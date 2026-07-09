//
//  ViewController.swift
//  Dongled
//
//  Created by Charles Sheppa on 9/6/23.
//

import UIKit
import AVFoundation

final class ViewController: UIViewController, CaptureManagerDelegate {
    
    private enum StatusText {
        static let cameraDisabled = NSLocalizedString("status.camera.disabled", comment: "Message shown when camera permission is denied.")
        static let scanningHardware = NSLocalizedString("status.scanning.hardware", comment: "Status while searching for capture hardware.")
        static let scanningSilent = NSLocalizedString("status.scanning.silent", comment: "Status while searching when microphone permission is denied.")
        static let connecting = NSLocalizedString("status.connecting", comment: "Status text while connecting to the selected device.")
    }
    
    // MARK: - IBOutlets
    
    @IBOutlet weak var noDeviceLabel: UILabel!
    @IBOutlet weak var coverView: UIView!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    
    // MARK: - Properties
    
    private let captureManager = CaptureManager()
    private var trackedDeviceIDs = Set<String>()
    private var needsSessionRestart = false
    
    // MARK: - Properties (Chrome Auto-Hide - Mac only)
    private var chromeHideTimer: Timer?
    private var isCursorHidden = false
    private let chromeHideDelay: TimeInterval = 3.0

    /// Activity assertion that keeps the display awake while capture is active.
    /// - Remark: `UIApplication.isIdleTimerDisabled` does not prevent display sleep on Mac.
    private var displayAwakeToken: (any NSObjectProtocol)?
    
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { isStatusBarHidden }
    
    private var isStatusBarHidden = false {
        didSet {
            DispatchQueue.main.async {
                self.setNeedsStatusBarAppearanceUpdate()
            }
        }
    }
    
    // MARK: - Lifecycle
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setupChromeAutoHide()  // Mac only; requires a key window in order to perform appearance modifications.
    }

    // Keep the preview layer sized to the view through window resize (Mac) and rotation (iPad)
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        captureManager.layoutPreview(in: view)
    }

    // Initial setup for UI handling
    override func viewDidLoad() {
        super.viewDidLoad()
        captureManager.delegate = self
        view.backgroundColor = .black
        registerNotifications()
    }
    
    // MARK: - Notification Registration
    // Subscribes to device and app state notifications
    private func registerNotifications() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleDeviceConnected), name: .AVCaptureDeviceWasConnected, object: nil)
        center.addObserver(self, selector: #selector(handleDeviceDisconnected), name: .AVCaptureDeviceWasDisconnected, object: nil)
        center.addObserver(self, selector: #selector(handleDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(handleAppDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    // MARK: - Notification Handlers
    // We want to start a new capture queue anytime the app reloads, so we launch it here not in viewDidLoad
    @objc private func handleAppDidBecomeActive() {
        let state = UIApplication.shared.applicationState
        print("Lifecycle: didBecomeActive (appState: \(state))")
        let hasValidSession = captureManager.hasValidSession
        if needsSessionRestart {
            print("Forcing capture restart after background suspension.")
            showChrome(forceTitlebarVisible: true)
            resetCursorHideTimer()
            needsSessionRestart = false
            captureManager.authorizeCapture(from: self)
        } else if case .scanning = captureManager.state {
            captureManager.authorizeCapture(from: self)
        } else if !hasValidSession {
            captureManager.authorizeCapture(from: self)
        } else {
            print("Capture session already active. Skipping re-boot.")
        }
    }
    
    // Passes background event to stop capture manager queue
    @objc private func handleDidEnterBackground() {
        print("Lifecycle: didEnterBackground")
        needsSessionRestart = true
        captureManager.teardownSession()
    }
    
    // Starts capture session if app active when device connects
    @objc private func handleDeviceConnected(notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let appState = UIApplication.shared.applicationState
            guard appState == .active else {
                print("Device connected while app state \(appState). Deferring until foreground.")
                self.needsSessionRestart = true
                return
            }
            guard let device = notification.object as? AVCaptureDevice,
                  device.deviceType == .external else { return }
            
            if self.captureManager.isRunningOnMac() {
                let id = device.uniqueID
                guard !self.trackedDeviceIDs.contains(id) else {
                    print("Duplicate connect notification ignored for device \(id)")
                    return
                }
                print("Found New Device: \(device.localizedName) | id: \(id)")
                self.trackedDeviceIDs.insert(id)
            } else {
                print("Found New Device (iPad mode): \(device.localizedName)")
            }
            
            self.captureManager.authorizeCapture(from: self)
        }
    }
    
    // Passes teardown event to capture manager
    @objc private func handleDeviceDisconnected(notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let state = UIApplication.shared.applicationState
            guard state != .background else {
                print("Skipping device disconnect handling while app in background.")
                return
            }
            guard let device = notification.object as? AVCaptureDevice,
                  device.deviceType == .external else { return }
            
            if self.captureManager.isRunningOnMac() {
                let id = device.uniqueID
                guard self.trackedDeviceIDs.contains(id) else {
                    print("Ignoring untracked device disconnect: \(id)")
                    return
                }
                
                print("Device disconnected: \(device.localizedName) [modelID: \(device.modelID)]")
                self.trackedDeviceIDs.remove(id)
                
                if self.trackedDeviceIDs.isEmpty {
                    self.captureManager.teardownSession()
                } else {
                    print("Other devices remain. Prompting user to reselect.")
                }
                self.captureManager.setupCaptureSessionMacOS(from: self)
            } else {
                print("Device disconnected (iPad mode): \(device.localizedName)")
                self.captureManager.teardownSession()
            }
        }
    }
    
    // MARK: - UI State Management
    
    enum UIState {
        case scanning, connecting, active
    }

    /// Keeps the display awake while capture is active.
    /// On Mac `UIApplication.isIdleTimerDisabled` does not block display sleep,
    /// so hold a `ProcessInfo` activity assertion with `.idleDisplaySleepDisabled` instead.
    private func setKeepDisplayAwake(_ awake: Bool) {
        if captureManager.isRunningOnMac() {
            if awake {
                guard displayAwakeToken == nil else { return }
                displayAwakeToken = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated],
                    reason: "Capturing video from external device"
                )
            } else if let token = displayAwakeToken {
                ProcessInfo.processInfo.endActivity(token)
                displayAwakeToken = nil
            }
        } else {
            UIApplication.shared.isIdleTimerDisabled = awake
        }
    }

    // Updates the UI for the given state
    func updateUI(for state: UIState) {
        DispatchQueue.main.async {
            switch state {
            case .scanning:
                self.isStatusBarHidden = false
                self.setKeepDisplayAwake(false)
                self.coverView.isHidden = false
                self.noDeviceLabel.isHidden = false

                self.cancelCursorHideTimer()

                let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
                let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                
                if camStatus != .authorized {
                    self.noDeviceLabel.text = StatusText.cameraDisabled
                    self.activityIndicator.isHidden = true
                } else if micStatus == .authorized {
                    self.noDeviceLabel.text = StatusText.scanningHardware
                    self.activityIndicator.isHidden = false
                } else {
                    self.noDeviceLabel.text = StatusText.scanningSilent
                    self.activityIndicator.isHidden = false
                }
                
            case .connecting:
                self.isStatusBarHidden = false
                self.setKeepDisplayAwake(false)
                self.coverView.isHidden = false
                self.noDeviceLabel.isHidden = false
                self.noDeviceLabel.text = StatusText.connecting
                self.activityIndicator.isHidden = false

                self.cancelCursorHideTimer()

            case .active:
                self.isStatusBarHidden = true
                self.setKeepDisplayAwake(true)
                self.coverView.isHidden = true
                self.noDeviceLabel.isHidden = true
                self.activityIndicator.isHidden = true

                self.resetCursorHideTimer()
            }
        }
    }
    
    // MARK: - CaptureManagerDelegate
    // Receives capture state updates and attaches preview if active
    func captureManager(_ manager: CaptureManager, didUpdate state: CaptureManager.State) {
        switch state {
        case .scanning:
            updateUI(for: .scanning)
        case .connecting:
            updateUI(for: .connecting)
        case .active(let connectedDeviceIDs):
            if captureManager.isRunningOnMac() {
                connectedDeviceIDs.forEach { trackedDeviceIDs.update(with: $0) }
            }

            captureManager.attachPreview(to: self.view)
            /// Tiny delay to give the layer time to finish flipping over
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.updateUI(for: .active)
            }
        }
    }
    
    // MARK: - Cleanup
    
    deinit {
        print("ViewController deinitialized")
        NotificationCenter.default.removeObserver(self)
    }
}


// MARK: - (Chrome Auto-Hide - Mac only)
extension ViewController: UIPointerInteractionDelegate {

    fileprivate func setupChromeAutoHide() {
        guard captureManager.isRunningOnMac() else { return }

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        view.addGestureRecognizer(hover)

        let pointerInteraction = UIPointerInteraction(delegate: self)
        view.addInteraction(pointerInteraction)

        /// Style the titlebar to overlay the video rather than sit above it
        guard let nsWindow = sharedKeyWindow else { return }

        kvcSetIfSupported(nsWindow, "titlebarAppearsTransparent", true)

        /// OR in NSWindow.StyleMask.fullSizeContentView (1 << 15)
        if nsWindow.responds(to: NSSelectorFromString("styleMask")),
           let styleMask = nsWindow.value(forKey: "styleMask") as? UInt {
            kvcSetIfSupported(nsWindow, "styleMask", styleMask | (1 << 15))
        }

        /// NSTitlebarSeparatorStyle.none = 1
        kvcSetIfSupported(nsWindow, "titlebarSeparatorStyle", 1)

        /// Never show the app name; only the window buttons take part in chrome show/hide
        /// (NSWindow.TitleVisibility: 0 = visible, 1 = hidden)
        kvcSetIfSupported(nsWindow, "titleVisibility", 1)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .changed:
            showChrome()
            resetCursorHideTimer()
        default:
            break
        }
    }

    fileprivate func resetCursorHideTimer() {
        guard captureManager.isRunningOnMac() else { return }
        chromeHideTimer?.invalidate()
        chromeHideTimer = Timer.scheduledTimer(withTimeInterval: chromeHideDelay, repeats: false) { [weak self] _ in
            self?.hideChrome()
        }
    }

    fileprivate func cancelCursorHideTimer() {
        guard captureManager.isRunningOnMac() else { return }
        chromeHideTimer?.invalidate()
        chromeHideTimer = nil
        showChrome()
    }

    private func hideChrome() {
        guard !isCursorHidden else { return }
        isCursorHidden = true
        view.interactions
            .compactMap { $0 as? UIPointerInteraction }
            .forEach { $0.invalidate() }
        setTitlebarHidden(true)
    }

    private func showChrome(forceTitlebarVisible: Bool = false) {
        guard captureManager.isRunningOnMac() else { return }
        if forceTitlebarVisible, !isCursorHidden {
            setTitlebarHidden(false)
            return
        }

        guard isCursorHidden else { return }
        isCursorHidden = false
        view.interactions
            .compactMap { $0 as? UIPointerInteraction }
            .forEach { $0.invalidate() }
        setTitlebarHidden(false)
    }

    // UIPointerInteractionDelegate

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        return isCursorHidden ? .hidden() : nil
    }

    // Titlebar Visibility

    private func setTitlebarHidden(_ hidden: Bool) {
        /// Only show the window buttons, on a timer
        guard let nsWindow = sharedKeyWindow else { return }
        kvcSetIfSupported(nsWindow, "titleVisibility", 1)

        let buttonSel = NSSelectorFromString("standardWindowButton:")
        guard nsWindow.responds(to: buttonSel) else { return }

        typealias ButtonIMP = @convention(c) (NSObject, Selector, Int) -> NSObject?
        let imp = nsWindow.method(for: buttonSel)
        let buttonFunc = unsafeBitCast(imp, to: ButtonIMP.self)

        /// The value space (0...2) is a set representing the NSWindowButton enumeration:
        /// (NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton)
        for buttonType in 0...2 {
            if let button = buttonFunc(nsWindow, buttonSel, buttonType) {
                kvcSetIfSupported(button, "hidden", hidden)
            }
        }
    }

    // MARK: - AppKit Helpers

    /// Find the AppKit key window and double check if it is a genuine NSWindow before we try to edit the chrome via KVC
    private var sharedKeyWindow: NSObject? {
        guard let nsApp = NSClassFromString("NSApplication") as? NSObject.Type,
              nsApp.responds(to: NSSelectorFromString("sharedApplication")),
              let sharedApp = nsApp.value(forKeyPath: "sharedApplication") as? NSObject,
              sharedApp.responds(to: NSSelectorFromString("keyWindow")),
              let nsWindow = sharedApp.value(forKey: "keyWindow") as? NSObject,
              let windowClass = NSClassFromString("NSWindow"),
              nsWindow.isKind(of: windowClass) else { return nil }
        return nsWindow
    }

    /// Sets a value via KVC only if the target implements the matching setter
    private func kvcSetIfSupported(_ target: NSObject, _ key: String, _ value: Any) {
        let setter = NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):")
        guard target.responds(to: setter) else {
            print("Chrome: target does not respond to \(key); skipping.")
            return
        }
        target.setValue(value, forKey: key)
    }
}
