import UIKit
import AVFoundation

class ViewController: UIViewController, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    @IBOutlet weak var noDeviceLabel: UILabel!
    @IBOutlet weak var coverView: UIView!
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    var isDeviceConnectedAtStartup: Bool = false
    
    var audioEngine: AVAudioEngine!
    var audioPlayerNode: AVAudioPlayerNode!
    var audioOutput: AVCaptureAudioDataOutput!
    
    let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)
    
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        coverView.isHidden = true  // Hide the video feed at first
        
        // Register for camera connect/disconnect notifications
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceConnected), name: NSNotification.Name.AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceDisconnected), name: NSNotification.Name.AVCaptureDeviceWasDisconnected, object: nil)
        
        setupCaptureSession()
        setupAudioEngine()
        
    }
    
    func setupCaptureSession() {
        if captureSession == nil {
            captureSession = AVCaptureSession()
        }
        
        guard let session = captureSession else {
            print("Error initializing capture session")
            return
        }
        
        session.sessionPreset = .high
        
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        
        if let device = discoverySession.devices.first {
            isDeviceConnectedAtStartup = true
            
            configureExternalDevice(device)
            
            configureAudio()
            
            
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = false
                self.isStatusBarHidden = false
                self.noDeviceLabel.isHidden = false
                self.coverView.isHidden = false
            }
        }
    }
    
    func configureExternalDevice(_ device: AVCaptureDevice) {
        configureCameraForHighestFrameRate(device: device)
        setupDeviceInput(for: device)
        isStatusBarHidden = true
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
            self.noDeviceLabel.isHidden = true
            self.coverView.isHidden = true
        }
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
            
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
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
    
    @objc func handleDeviceConnected(notification: Notification) {
        if let device = notification.object as? AVCaptureDevice, device.deviceType == .external {
            
            if !isDeviceConnectedAtStartup {
                // This creates a clean startup
                configureExternalDevice(device)
                isDeviceConnectedAtStartup = true  // reset the flag
                print("Session Launching From HotPlug")
                // Clean device input from no device at launch
                if let session = captureSession {
                    for input in session.inputs {
                        if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device == device {
                            session.removeInput(deviceInput)
                        }
                    }
                }
                setupCaptureSession()
                
            } else {
                // For reconnection, switch to the device
                configureExternalDevice(device)
                
                DispatchQueue.global(qos: .userInitiated).async {
                    self.captureSession?.startRunning()  // Start the session again
                }
                print("Session Resuming From HotPlug")
            }
        }
    }
    
    @objc func handleDeviceDisconnected(notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice, device.deviceType == .external else {
            return
        }
        
        // Remove input associated with disconnected device
        if let session = captureSession {
            for input in session.inputs {
                if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device == device {
                    session.removeInput(deviceInput)
                }
            }
        }
        
        print("Session disconnect")
        
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
            self.isStatusBarHidden = false
            self.noDeviceLabel.isHidden = false
            self.coverView.isHidden = false
        }
    }
    func configureCameraForHighestFrameRate(device: AVCaptureDevice) {
        
        var bestFormat: AVCaptureDevice.Format?
        var bestFrameRateRange: AVFrameRateRange?
        
        
        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate > bestFrameRateRange?.maxFrameRate ?? 0 {
                    bestFormat = format
                    bestFrameRateRange = range
                }
            }
        }
        
        if let bestFormat = bestFormat,
           let bestFrameRateRange = bestFrameRateRange {
            do {
                try device.lockForConfiguration()
                
                // Set the device's active format.
                device.activeFormat = bestFormat
                
                // Set the device's min/max frame duration.
                let duration = bestFrameRateRange.minFrameDuration
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                
                device.unlockForConfiguration()
            } catch {
                // Handle error.
            }
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
    
    // Audio Engine
    
    func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        audioPlayerNode = AVAudioPlayerNode()
        audioEngine.attach(audioPlayerNode)
        audioEngine.connect(audioPlayerNode, to: audioEngine.mainMixerNode, format: monoFormat)
        audioPlayerNode.volume = 1.0
        
        do {
                try audioEngine.start()
                audioPlayerNode.play()
        } catch {
            print("Error starting audio engine during setup: \(error)")
        }
    }
    
    func configureAudio() {
        
        guard let session = captureSession else {
            print("Session is nil")
            return
        }
        
        let audioDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .microphone], mediaType: .audio, position: .unspecified)
        
        print("Found \(audioDiscoverySession.devices.count) audio devices.")
        
        for device in audioDiscoverySession.devices {
            print("Audio device name: \(device.localizedName)")
        }
        
        if let audioDevice = audioDiscoverySession.devices.first(where: { $0.deviceType == .microphone }) {
            print("Attempting to configure the external audio device.")
            do {
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                if session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                    print("Added external audio input: \(audioDevice.localizedName)")
                } else {
                    print("Cannot add external audio input to the session.")
                }
            } catch {
                print("Error setting up external audio capture session input: \(error)")
            }
        } else {
            print("No external audio device found.")
        }
        audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "audioQueue"))
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }
    }
    
    func convertSampleBufferToMonoPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                print("Can't get data buffer from sample buffer")
                return nil
            }
            
            var lengthAtOffsetOut: size_t = 0
            var totalLengthOut: size_t = 0
            var dataPointerOut: UnsafeMutablePointer<Int8>?

            let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffsetOut, totalLengthOut: &totalLengthOut, dataPointerOut: &dataPointerOut)
            
            guard status == kCMBlockBufferNoErr, let dataPointer = dataPointerOut else {
                print("Error retrieving data pointer from block buffer")
                return nil
            }

            return convertDataPointerToMonoPCM(dataPointer: dataPointer, totalLength: totalLengthOut)
        }
    
    func convertDataPointerToMonoPCM(dataPointer: UnsafeMutablePointer<Int8>, totalLength: Int) -> AVAudioPCMBuffer? {
        let frameCapacity = AVAudioFrameCount(totalLength / 2)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat!, frameCapacity: frameCapacity) else {
            print("Failed to create audio buffer.")
            return nil
        }

        pcmBuffer.frameLength = pcmBuffer.frameCapacity

        let channel = pcmBuffer.floatChannelData![0]
        let dataBytes = UnsafeMutableRawPointer(dataPointer).assumingMemoryBound(to: Int16.self) 

        for frameIndex in 0..<pcmBuffer.frameLength {
            channel[Int(frameIndex)] = Float(dataBytes[Int(frameIndex)]) / Float(Int16.max)
        }

        return pcmBuffer
    }
}

extension ViewController {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pcmBuffer = convertSampleBufferToMonoPCMBuffer(sampleBuffer) else { return }
        audioPlayerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }
}

