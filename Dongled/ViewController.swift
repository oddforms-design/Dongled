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
    
    #if targetEnvironment(macCatalyst)
    // MARK: - Properties (Chrome Auto-Hide - Mac Catalyst)
    private var chromeHideTimer: Timer?
    private var isCursorHidden = false
    private let chromeHideDelay: TimeInterval = 3.0
    #endif
    
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
#if targetEnvironment(macCatalyst)
        setupChromeAutoHide()  // Requires a key window in order to perform appearance modifications.
#endif
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
#if targetEnvironment(macCatalyst)
            showChrome(forceTitlebarVisible: true)
            resetCursorHideTimer()
#endif
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
    
    // Updates the UI for the given state
    func updateUI(for state: UIState) {
        DispatchQueue.main.async {
            switch state {
            case .scanning:
                self.isStatusBarHidden = false
                UIApplication.shared.isIdleTimerDisabled = false
                self.coverView.isHidden = false
                self.noDeviceLabel.isHidden = false
                
                #if targetEnvironment(macCatalyst)
                self.cancelCursorHideTimer()
                #endif
                
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
                UIApplication.shared.isIdleTimerDisabled = false
                self.coverView.isHidden = false
                self.noDeviceLabel.isHidden = false
                self.noDeviceLabel.text = StatusText.connecting
                self.activityIndicator.isHidden = false
                
                #if targetEnvironment(macCatalyst)
                self.cancelCursorHideTimer()
                #endif
                
            case .active:
                self.isStatusBarHidden = true
                UIApplication.shared.isIdleTimerDisabled = true
                self.coverView.isHidden = true
                self.noDeviceLabel.isHidden = true
                self.activityIndicator.isHidden = true
                
                #if targetEnvironment(macCatalyst)
                self.resetCursorHideTimer()
                #endif
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
            #if targetEnvironment(macCatalyst)
            connectedDeviceIDs.forEach { trackedDeviceIDs.update(with: $0) }
            #endif
            
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


#if targetEnvironment(macCatalyst)
// MARK: - UIPointerInteractionDelegate (Chrome Auto-Hide - Mac Catalyst)
extension ViewController: UIPointerInteractionDelegate {

    // MARK: - Chrome Auto-Hide Orchestration

    fileprivate func setupChromeAutoHide() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        view.addGestureRecognizer(hover)

        let pointerInteraction = UIPointerInteraction(delegate: self)
        view.addInteraction(pointerInteraction)

        /// Force a dark appearance so title text can remain readable over arbitrary video content.

        guard let nsWindow = sharedKeyWindow else { return }

        if let appearanceClass = NSClassFromString("NSAppearance") as? NSObject.Type {
            let sel = NSSelectorFromString("appearanceNamed:")
            let darkAqua = (appearanceClass as AnyObject)
                .perform(sel, with: "NSAppearanceNameDarkAqua")?
                .takeUnretainedValue()
            nsWindow.setValue(darkAqua, forKey: "appearance")
        } else {
            print("Unable to force dark appearance.")
        }
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
        chromeHideTimer?.invalidate()
        chromeHideTimer = Timer.scheduledTimer(withTimeInterval: chromeHideDelay, repeats: false) { [weak self] _ in
            self?.hideChrome()
        }
    }

    fileprivate func cancelCursorHideTimer() {
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
        /// NOTE: If the app had hidden its chrome prior to being backgrounded, when the app returns
        /// to the foreground, UIKit resets its own state — effectively restoring `title​Visibility` to
        /// `.visible` and invalidates/resets the underlying `UIPointer​Interaction` so the
        /// cursor reappears. However, the AppKit-level `hidden` property set directly on the
        /// `NSButton` objects is not reset by the system.  To keep concerns as self-contained as
        /// possible, allow callers to force our state to be coherent with UIKit.
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

    // MARK: - UIPointerInteractionDelegate

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        return isCursorHidden ? .hidden() : nil
    }

    // MARK: - Titlebar Visibility

    private func setTitlebarHidden(_ hidden: Bool) {
        guard let windowScene = view.window?.windowScene,
              let titlebar = windowScene.titlebar else { return }

        titlebar.titleVisibility = hidden ? .hidden : .visible

        /// Hide/show standard window buttons (close, minimize, zoom) using Mac Catalyst method
        /// See <https://developer.apple.com/forums/thread/769279>, <https://developer.apple.com/documentation/UIKit/mac-catalyst>.

        let buttonSel = NSSelectorFromString("standardWindowButton:")
        guard let nsWindow = sharedKeyWindow,
              nsWindow.responds(to: buttonSel) else { return }

        typealias ButtonIMP = @convention(c) (NSObject, Selector, Int) -> NSObject?
        let imp = nsWindow.method(for: buttonSel)
        let buttonFunc = unsafeBitCast(imp, to: ButtonIMP.self)

        /// The value space (0...2) is a set representing the NSWindowButton enumeration:
        /// (NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton)
        for buttonType in 0...2 {
            if let button = buttonFunc(nsWindow, buttonSel, buttonType) {
                button.setValue(hidden, forKey: "hidden")
            }
        }
    }

    // MARK: - AppKit Helpers

    private var sharedKeyWindow: NSObject? {
        if let nsApp = NSClassFromString("NSApplication"),
              let sharedApp = nsApp.value(forKeyPath: "sharedApplication") as? NSObject,
              let nsWindow = sharedApp.value(forKey: "keyWindow") as? NSObject {
            nsWindow
        } else {
            nil
        }
    }
}
#endif
