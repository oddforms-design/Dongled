//
//  ViewController.swift
//  Dongled
//
//  Created by Charles Sheppa on 9/6/23.
//

import UIKit
import AVFoundation

final class ViewController: UIViewController, CaptureManagerDelegate {

    // MARK: - IBOutlets

    @IBOutlet weak var noDeviceLabel: UILabel!
    @IBOutlet weak var coverView: UIView!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!

    // MARK: - Properties

    private var currentUIState: UIState = .scanning
    private let captureManager = CaptureManager()

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
        print("App Became Active")
        captureManager.authorizeCapture()
    }

    // Passes background event to stop capture manager queue
    @objc private func handleDidEnterBackground() {
        captureManager.teardownSession()
    }

    // Starts capture session if app active when device connects
    @objc private func handleDeviceConnected(notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice else { return }
        /// Make sure the device change is external to fix a strange internal mic detection issue
        guard device.deviceType == .external else {
            return
        }
        print("Found New Device: \(device.localizedName) | id: \(device.uniqueID)")
        self.captureManager.authorizeCapture()
    }

    // Passes teardown event to capture manager
    @objc private func handleDeviceDisconnected(notification: Notification) {
        DispatchQueue.main.async {
            /// Now safe to call UIApplication.shared.applicationState, calling outside app will result in crash
            guard UIApplication.shared.applicationState == .active else { return }
            guard let device = notification.object as? AVCaptureDevice,
                  device.deviceType == .external else { return }
            print("Device disconnected: \(device.localizedName) [modelID: \(device.modelID)]")
            self.captureManager.teardownSession()
        }
    }

    // MARK: - UI State Management

    enum UIState {
        case scanning, connecting, active
    }

    // Updates the UI for the given state
    func updateUI(for state: UIState) {
        DispatchQueue.main.async {
            self.currentUIState = state
            switch state {
            case .scanning:
                self.isStatusBarHidden = false
                UIApplication.shared.isIdleTimerDisabled = false
                self.coverView.isHidden = false
                self.noDeviceLabel.isHidden = false

                let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
                let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

                if camStatus != .authorized {
                    self.noDeviceLabel.text = "Camera access disabled. Enable in Privacy Settings to Continue."
                    self.activityIndicator.isHidden = true
                } else if micStatus == .authorized {
                    self.noDeviceLabel.text = "Scanning for Hardware"
                    self.activityIndicator.isHidden = false
                } else {
                    self.noDeviceLabel.text = "Scanning for Hardware: Silent Mode – Microphone access disabled."
                    self.activityIndicator.isHidden = false
                }

            case .connecting:
                self.isStatusBarHidden = false
                UIApplication.shared.isIdleTimerDisabled = false
                self.coverView.isHidden = false
                self.noDeviceLabel.isHidden = false
                self.noDeviceLabel.text = "Connecting to Device"
                self.activityIndicator.isHidden = false

            case .active:
                self.isStatusBarHidden = true
                UIApplication.shared.isIdleTimerDisabled = true
                self.coverView.isHidden = true
                self.noDeviceLabel.isHidden = true
                self.activityIndicator.isHidden = true
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
        case .active:
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
