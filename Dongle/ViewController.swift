import UIKit
import AVFoundation

class ViewController: UIViewController {

    @IBOutlet weak var noDeviceLabel: UILabel!
    @IBOutlet weak var coverView: UIView!
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        // Register for camera connect/disconnect notifications
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceConnected), name: NSNotification.Name.AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceDisconnected), name: NSNotification.Name.AVCaptureDeviceWasDisconnected, object: nil)
        
        setupCaptureSession()
        coverView.isHidden = true  // Hide the video feed at first
    }

    func setupCaptureSession() {
        captureSession = AVCaptureSession()
        
        guard let session = captureSession else {
            print("Error initializing capture session")
            return
        }
        
        session.sessionPreset = .high
        
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        
        if let device = discoverySession.devices.first {
            setupDeviceInput(for: device)
            self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: self.previewLayer)
            applyVideoRotationForPreview()
            DispatchQueue.main.async {
                        UIApplication.shared.isIdleTimerDisabled = true
                    }
            isStatusBarHidden = true
        } else if let rearCamera = AVCaptureDevice.default(for: .video) {
            setupDeviceInput(for: rearCamera)
            DispatchQueue.main.async {
                        UIApplication.shared.isIdleTimerDisabled = false
                    }
            isStatusBarHidden = false
            DispatchQueue.main.async {
                self.noDeviceLabel.isHidden = false
                self.coverView.isHidden = false
            }
        }
    }
    
    func setupDeviceInput(for device: AVCaptureDevice) {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard let session = captureSession, session.canAddInput(input) else {
                print("Can't add input to the session")
                return
            }
            
            session.addInput(input)
            DispatchQueue.main.async {
                self.noDeviceLabel.isHidden = true
            }
            setupPreviewLayer(for: session)
            
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        } catch {
            print("Error setting up capture session input: \(error)")
        }
    }

    func setupPreviewLayer(for session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        guard let previewLayer = previewLayer else {
            print("Error setting up preview layer")
            return
        }
        
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspect
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        view.layer.insertSublayer(previewLayer, at: 0)
    }
    
    func switchTo(device: AVCaptureDevice) {
        guard let session = captureSession else {
            print("Capture session not available")
            return
        }
        
        session.beginConfiguration()
        
        for input in session.inputs {
            session.removeInput(input)
        }
        
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            session.addInput(newInput)
        } catch {
            print("Error switching to device: \(error)")
        }
        
        session.commitConfiguration()
    }
    
    @objc func handleDeviceConnected(notification: Notification) {
        
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        
        print("Session preset on device connect: \(captureSession?.sessionPreset.rawValue ?? "none")")
        
        DispatchQueue.main.async {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        
        isStatusBarHidden = true
        
        guard let device = discoverySession.devices.first else {
            print("External device not found in discovery session!")
            return
        }
        
        switchTo(device: device)
        self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: self.previewLayer)
        applyVideoRotationForPreview()
        
        DispatchQueue.main.async {
            self.noDeviceLabel.isHidden = true
            self.coverView.isHidden = true
        }
    }

    @objc func handleDeviceDisconnected(notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice, device.deviceType == .external else {
            return
        }
        
        print("Session preset on device disconnect: \(captureSession?.sessionPreset.rawValue ?? "none")")
        
        DispatchQueue.main.async {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        
        isStatusBarHidden = false
        
        for input in captureSession?.inputs ?? [] {
            captureSession?.removeInput(input)
        }
        
        DispatchQueue.main.async {
            self.noDeviceLabel.isHidden = false
            self.coverView.isHidden = false
        }
    }
    
    func applyVideoRotationForPreview() {
        guard let previewLayerConnection = previewLayer?.connection, let rotationCoordinator = rotationCoordinator else {
            return
        }
        
        let rotationAngle = rotationCoordinator.videoRotationAngleForHorizonLevelPreview
        if previewLayerConnection.isVideoRotationAngleSupported(rotationAngle) {
            previewLayerConnection.videoRotationAngle = rotationAngle
        }
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

    deinit {
        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceWasDisconnected, object: nil)
    }
}
