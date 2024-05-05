import UIKit
import AVFoundation

class ViewController: UIViewController {
    
    @IBOutlet weak var noDeviceLabel: UILabel!
    @IBOutlet weak var coverView: UIView!
    
    var sessionBlocked: Bool = false
    var isInitialLaunch = true

    let audioManager = AudioManager()
    let captureManager = CaptureManager()
    
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
        
    override func viewDidLoad() {
        super.viewDidLoad()
        captureManager.viewController = self
        view.backgroundColor = .black
        showIdleUI()
        
        // Register for camera connect/disconnect notifications
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceConnected), name: NSNotification.Name.AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceDisconnected), name: NSNotification.Name.AVCaptureDeviceWasDisconnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
      
        captureManager.setupCaptureSession()
    }
    func showConnectingUI() {
        DispatchQueue.main.async {
            self.noDeviceLabel.text = "Connecting to Device"
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

    
    @objc func appWillResignActive(_ notification: Notification) {
            self.audioManager.pauseAudio()
            print("Session Resigned Active")
    }
    
    //
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
    
    // Helpers //
    // Connects and Active
    
    @objc func handleDeviceConnected(notification: Notification) {
        if let device = notification.object as? AVCaptureDevice, device.deviceType == .external {
            captureManager.rebootSession()
        }
    }
    
    @objc func handleDeviceDisconnected(notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice, device.deviceType == .external else {
            return
        }
        
        DispatchQueue.main.async {
            self.noDeviceLabel.text = "Scanning for Hardware"
        }
        
        captureManager.sessionStop()
        /*
        // Remove input associated with disconnected device
        if let session = captureSession {
            for input in session.inputs {
                if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device == device {
                    session.removeInput(deviceInput)
                }
            }
        }
        
        // Stop the audio player node and engine & disconnect audio input
        audioManager.stopAudio(withCaptureSession: captureSession)
        */
        print("Session disconnect")
        
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
            self.isStatusBarHidden = false
            self.noDeviceLabel.isHidden = false
            self.coverView.isHidden = false
            
        }
    }
    
    
    // UI Helpers
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
    // Util
    deinit {
        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceWasDisconnected, object: nil)
        NotificationCenter.default.removeObserver(self)
        isInitialLaunch = true
    }

}
