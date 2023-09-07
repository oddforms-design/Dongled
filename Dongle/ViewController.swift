import UIKit
import AVFoundation

class ViewController: UIViewController {

    @IBOutlet weak var noDeviceLabel: UILabel!
    @IBOutlet weak var coverView: UIView!
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        // Register for camera connect/disconnect notifications
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceConnected), name: NSNotification.Name.AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceDisconnected), name: NSNotification.Name.AVCaptureDeviceWasDisconnected, object: nil)
        
        setupCaptureSession()
                coverView.isHidden = true  // Hide the video feed at first
    }
    
    @objc func handleDeviceConnected(notification: Notification) {
        // Run a discovery session
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        
        // Check if an external device is found
        if let device = discoverySession.devices.first {
            switchTo(device: device)
            
            self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: self.previewLayer)
            applyVideoRotationForPreview()
            
            DispatchQueue.main.async {
                self.noDeviceLabel.isHidden = true
                self.coverView.isHidden = true
            }
        } else {
            print("External device not found in discovery session!")
        }
    }

    @objc func handleDeviceDisconnected(notification: Notification) {
        if let device = notification.object as? AVCaptureDevice, device.deviceType == .external {
            
            // Remove all inputs from the capture session
            for input in captureSession?.inputs ?? [] {
                captureSession?.removeInput(input)
            }
            
            // Show the "No Device Connected" message
            DispatchQueue.main.async {
                self.noDeviceLabel.isHidden = false
                self.coverView.isHidden = false
            }
        }
    }

    func setupCaptureSession() {
        captureSession = AVCaptureSession()
        
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        
        if let device = discoverySession.devices.first {
            setupDeviceInput(for: device)
            self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: self.previewLayer)
            applyVideoRotationForPreview()
        } else {
            // No external device found, use the rear camera
            if let rearCamera = AVCaptureDevice.default(for: .video) {
                setupDeviceInput(for: rearCamera)
            }
            
                DispatchQueue.main.async {
                self.noDeviceLabel.isHidden = false
                self.coverView.isHidden = false  // Show the covering view to hide rear camera feed
                }
        }
        
        // Start the capture session
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession?.startRunning()
        }
    }
    
    func setupDeviceInput(for device: AVCaptureDevice) {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession?.canAddInput(input) == true {
                captureSession?.addInput(input)
                DispatchQueue.main.async {
                    self.noDeviceLabel.isHidden = true
                }
                
                if let session = captureSession {
                    setupPreviewLayer(for: session)
                }
                
                // Move startRunning to a background thread
                DispatchQueue.global(qos: .userInitiated).async {
                    self.captureSession?.startRunning()
                }
            }
        } catch {
            print("Error setting up capture session input: \(error)")
        }
    }

    func setupPreviewLayer(for session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        guard let previewLayer = previewLayer else { return }
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspect
        // Add this line to flip the video preview layer horizontally
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        view.layer.insertSublayer(previewLayer, at: 0)
    }
    
    func switchTo(device: AVCaptureDevice) {
        captureSession?.beginConfiguration()
        for input in captureSession?.inputs ?? [] {
            captureSession?.removeInput(input)
        }
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            captureSession?.addInput(newInput)
        } catch {
            print("Error switching to device: \(error)")
        }
        captureSession?.commitConfiguration()
    }
    
    func applyVideoRotationForPreview() {
        guard let previewLayerConnection = previewLayer?.connection,
              let rotationCoordinator = rotationCoordinator else {
            return
        }
        
        let rotationAngle = rotationCoordinator.videoRotationAngleForHorizonLevelPreview
        
        if previewLayerConnection.isVideoRotationAngleSupported(rotationAngle) {
            previewLayerConnection.videoRotationAngle = rotationAngle
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceWasDisconnected, object: nil)
    }
}
