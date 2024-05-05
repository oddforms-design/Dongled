import UIKit
import AVFoundation

class ViewController: UIViewController {
    
    @IBOutlet weak var noDeviceLabel: UILabel!
    @IBOutlet weak var coverView: UIView!
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    
    let audioManager = AudioManager()
    
    // Setup the UI for Fullscreen Viewing
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    override var prefersStatusBarHidden: Bool {
        return isStatusBarHidden
    }
    var isStatusBarHidden = false {
        didSet {
            DispatchQueue.main.async {
                self.setNeedsStatusBarAppearanceUpdate()
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configureInitialViewState()
        registerForNotifications()
        setupCaptureSession()
    }

    private func configureInitialViewState() {
        view.backgroundColor = .black
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
            self.coverView.isHidden = false
            self.noDeviceLabel.isHidden = false
        }
    }

    private func registerForNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceConnected), name: NSNotification.Name.AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceDisconnected), name: NSNotification.Name.AVCaptureDeviceWasDisconnected, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }


    func setupCaptureSession() {
        if captureSession == nil {
            captureSession = AVCaptureSession()
        }
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        
        if let device = discoverySession.devices.first {
            DispatchQueue.main.async {
                self.noDeviceLabel.text = "Connecting to Device"
            }
            // Delay the rest of the code by 2 seconds to ensure device is booted
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
               
               
                self.launchSession(with: device)
                        
            
                self.isStatusBarHidden = true
                DispatchQueue.main.async {
                    UIApplication.shared.isIdleTimerDisabled = true
                    self.coverView.isHidden = true
                    self.noDeviceLabel.isHidden = true
                }
            }
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = false
                self.isStatusBarHidden = false
                self.noDeviceLabel.isHidden = false
                self.coverView.isHidden = false
            }
        }
    }
    
    // Main Setup Functions
    
    func launchSession(with device: AVCaptureDevice) {
        self.captureSession?.beginConfiguration()
        self.setupDeviceInput(for: device)
        audioManager.self.setupAudioSession()
        audioManager.self.setupAudioEngine()
        audioManager.self.configureAudio(forCaptureSession: self.captureSession!)
        audioManager.self.startAudio()
        self.captureSession?.commitConfiguration()
        self.startSession()
    }
    
    func setupDeviceInput(for device: AVCaptureDevice) {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard let session = captureSession else {
                print("Session is nil")
                return
            }
            if session.canAddInput(input) {
                session.addInput(input)
                print("Added input: \(session.inputs)")
            }
            
            DispatchQueue.main.async {
                self.noDeviceLabel.isHidden = true
            }
            setupPreviewLayer(for: session)
            
            
        } catch {
            print("Error setting up capture session input: \(error)")
        }
    }
    
    func setupPreviewLayer(for session: AVCaptureSession) {
        // Remove the old preview layer if it exists
        previewLayer?.removeFromSuperlayer()
        
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        guard let previewLayer = previewLayer else {
            print("Error setting up preview layer")
            return
        }
        
        DispatchQueue.main.async {
            previewLayer.frame = self.view.bounds
            previewLayer.videoGravity = .resizeAspect
            previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            self.view.layer.insertSublayer(previewLayer, at: 0)
        }
        
        if let device = self.captureSession?.inputs.first as? AVCaptureDeviceInput {
            self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device.device, previewLayer: previewLayer)
            self.applyVideoRotationForPreview()
        }
        
    }
    
    func startSession() {
        guard let session = captureSession else {
            print("Session is nil")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }
    
    // Connects and Active
    
    @objc func handleDeviceConnected(notification: Notification) {
        if let device = notification.object as? AVCaptureDevice, device.deviceType == .external {
            rebootSession()
        }
    }
    
    @objc func handleDeviceDisconnected(notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice, device.deviceType == .external else {
            return
        }
        
        DispatchQueue.main.async {
            self.noDeviceLabel.text = "Scanning for Hardware"
        }
        
        sessionStop()
        
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
        
        print("Session disconnect")
        
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
            self.isStatusBarHidden = false
            self.noDeviceLabel.isHidden = false
            self.coverView.isHidden = false
            
        }
    }
    
    // Helpers //
    func rebootSession(){
        sessionStop()
        
        DispatchQueue.main.async {
            self.noDeviceLabel.text = "Connecting to Device"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if UIApplication.shared.applicationState == .active {
                let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
                    
                if let device = discoverySession.devices.first {
                    self.launchSession(with: device)

                    DispatchQueue.main.async {
                        UIApplication.shared.isIdleTimerDisabled = true
                        self.isStatusBarHidden = true
                        self.coverView.isHidden = true
                        self.noDeviceLabel.isHidden = true
                        }
                    }
                } else {
                    //self.AppDelegate.sessionBlocked = true
                    print("App is inactive, do not connect to device")
                    return
                }
            }
    }
    func sessionStop() {
        if let session = captureSession
        {
            session.stopRunning()
        }
    }
    
    // Set Device Rotation
    func applyVideoRotationForPreview() {
        guard let previewLayerConnection = previewLayer?.connection, let rotationCoordinator = rotationCoordinator else {
            return
        }
        
        let rotationAngle = rotationCoordinator.videoRotationAngleForHorizonLevelPreview
        if previewLayerConnection.isVideoRotationAngleSupported(rotationAngle) {
            previewLayerConnection.videoRotationAngle = rotationAngle
        }
    }

    // Util
    deinit {
        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceWasDisconnected, object: nil)
    }

}
