import UIKit
import AVFoundation

class ViewController: UIViewController {
    
    @IBOutlet weak var noDeviceLabel: UILabel!
    @IBOutlet weak var coverView: UIView!
    
    var sessionBlocked: Bool = false
    var isInitialLaunch = true
    
    // Visual Overrides
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    var isStatusBarHidden = false {
        didSet {
            DispatchQueue.main.async {
                self.setNeedsStatusBarAppearanceUpdate()
            }
        }
    }
    
    override var prefersStatusBarHidden: Bool {
        return isStatusBarHidden
    }
    
    // Connect Classes
    let captureManager = CaptureManager()
    let audioManager = AudioManager()
    
    // Setup View and Start Session
    override func viewDidLoad() {
        super.viewDidLoad()
        captureManager.viewController = self
        view.backgroundColor = .black
        showIdleUI()
        registerNotifications()
        // Start the session
        captureManager.setupCaptureSession()
    }
    
    // Setup Listeners
    func registerNotifications() {
        // Register for camera connect/disconnect notifications
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceConnected), name: NSNotification.Name.AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceDisconnected), name: NSNotification.Name.AVCaptureDeviceWasDisconnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    // App Lifecycle Events
    @objc func appWillResignActive(_ notification: Notification) {
            self.audioManager.pauseAudio()
            print("Session Resigned Active")
    }
    @objc func appDidBecomeActive(_ notification: Notification) {
        if isInitialLaunch {
            isInitialLaunch = false
            return  // Exit early if initial launch
        }
        if sessionBlocked { // Session was unplugged outside the app
            print("App became active. Attempting to discover and reconnect session.")
            captureManager.rebootSession()
            sessionBlocked = false
        } else {
            // Session was not unplugged, but app resigned, resuming
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { // Delay for device needed to prevent audio drop
                self.audioManager.startAudio()
                self.captureManager.startSession()
                print("Session Resumed Unblocked Active")
            }
        }
    }
    
    // Hotplug Logic
    @objc func handleDeviceConnected(notification: Notification) {
        captureManager.rebootSession()
    }
    
    @objc func handleDeviceDisconnected(notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice, device.deviceType == .external else {
            return
        }
        captureManager.deviceDisconnected(for: device)
    }
    
    // UI Helpers
    func showConnectingTextUI() {
        DispatchQueue.main.async {
            self.noDeviceLabel.text = "Connecting to Device"
        }
    }
    func showScanningTextUI() {
        DispatchQueue.main.async {
            self.noDeviceLabel.text = "Scanning for Hardware"
        }
    }
    func showActiveUI() {
        self.isStatusBarHidden = true
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
            self.coverView.isHidden = true
            self.noDeviceLabel.isHidden = true
        }
    }
    func showIdleUI() {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
            self.isStatusBarHidden = false
            self.noDeviceLabel.isHidden = false
            self.coverView.isHidden = false
        }
    }
    
    // Util
    deinit {
        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceWasDisconnected, object: nil)
        NotificationCenter.default.removeObserver(self)
        isInitialLaunch = true
    }

}
