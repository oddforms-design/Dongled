import UIKit
import AVFoundation

class ViewController: UIViewController, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    @IBOutlet weak var noDeviceLabel: UILabel!
    @IBOutlet weak var coverView: UIView!
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    
    var audioEngine: AVAudioEngine!
    var audioPlayerNode: AVAudioPlayerNode!
    var audioOutput: AVCaptureAudioDataOutput!
    
    var detectedChannels: UInt32 = 1
    var pcmFormat: AVAudioFormat? {
        
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: detectedChannels, interleaved: false)
    }
    
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
            self.coverView.isHidden = false
            self.noDeviceLabel.isHidden = false
        }
        
        // Register for camera connect/disconnect notifications
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceConnected), name: NSNotification.Name.AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceDisconnected), name: NSNotification.Name.AVCaptureDeviceWasDisconnected, object: nil)
        
        DispatchQueue.global(qos: .background).async {
            self.setupCaptureSession()
            self.setupAudioSession()
        }
    }
    
    func setupCaptureSession() {
        if captureSession == nil {
            captureSession = AVCaptureSession()
        }
        setMaxSupportedResolution(for: captureSession!)
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        
        if let device = discoverySession.devices.first {
            DispatchQueue.main.async {
                self.noDeviceLabel.text = "Connecting to Device"
            }
            // Delay the rest of the code by 2 seconds to ensure device is booted
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.captureSession?.beginConfiguration()
                self.configureExternalDevice(device)
                self.setupAudioEngine()
                self.configureAudio()
                self.captureSession?.commitConfiguration()
                self.startSesssion()
                
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
    
    func configureExternalDevice(_ device: AVCaptureDevice) {
        configureCameraForHighestFrameRate(device: device)
        setupDeviceInput(for: device)
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
    
    func startSesssion() {
        guard let session = captureSession else {
            print("Session is nil")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }
    
    @objc func handleDeviceConnected(notification: Notification) {
        if let device = notification.object as? AVCaptureDevice, device.deviceType == .external {
            
        
            DispatchQueue.main.async {
                self.noDeviceLabel.text = "Connecting to Device"
            }
            
            // Delay the rest of the code by 2.2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                self.captureSession?.beginConfiguration()
                self.configureExternalDevice(device)
                self.setupAudioEngine()
                self.configureAudio()
                self.captureSession?.commitConfiguration()
                self.startSesssion()
                
                DispatchQueue.main.async {
                    UIApplication.shared.isIdleTimerDisabled = true
                    self.isStatusBarHidden = true
                    self.coverView.isHidden = true
                    self.noDeviceLabel.isHidden = true
                }
            }
        }
    }
    
    @objc func handleDeviceDisconnected(notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice, device.deviceType == .external else {
            return
        }
        
        DispatchQueue.main.async {
            self.noDeviceLabel.text = "Scanning for Hardware"
        }
        
        if let session = captureSession
        {
            session.stopRunning()
        }
        
        // Remove input associated with disconnected device
        if let session = captureSession {
            for input in session.inputs {
                if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device == device {
                    session.removeInput(deviceInput)
                }
            }
        }
        
        // Stop the audio player node and engine & disconnect audio input
        stopAudio()
        
        print("Session disconnect")
        
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
            self.isStatusBarHidden = false
            self.noDeviceLabel.isHidden = false
            self.coverView.isHidden = false
            
        }
    }
    
    // Helpers //
    func setMaxSupportedResolution(for session: AVCaptureSession) {
        let presetsInDecreasingOrder: [AVCaptureSession.Preset] = [
            .hd1920x1080,
            .hd1280x720,
            .high,
            .medium,
            .low
            // Add any other relevant presets here if needed.
        ]

        for preset in presetsInDecreasingOrder {
            if session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
                break
            }
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
        guard let audioEngine = audioEngine else {
            print("Error: Failed to initialize audioEngine.")
            return
        }

        // Get the channel count
        let channelCount = audioEngine.inputNode.inputFormat(forBus: 0).channelCount
        print("Number of channels: \(channelCount)")
        detectedChannels = channelCount
        
        guard let safePCMFormat = pcmFormat else {
            print("Error: PCM format is not available.")
            return
        }

        audioPlayerNode = AVAudioPlayerNode()
        audioEngine.attach(audioPlayerNode)
        audioEngine.connect(audioPlayerNode, to: audioEngine.mainMixerNode, format: safePCMFormat)
        audioPlayerNode.volume = 1.0

        do {
            try audioEngine.start()
            audioPlayerNode?.play()
        } catch {
            print("Error starting audio engine during setup: \(error)")
        }
    }
    
    // Discover the device and set it as the session input
    func configureAudio() {
        guard let session = captureSession else {
            print("Session is nil")
            return
        }

        let audioDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .microphone], mediaType: .audio, position: .unspecified)
                
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
    
    // Stop the audio system
    func stopAudio() {
        if audioEngine?.isRunning == true {
            audioPlayerNode.stop()
            audioEngine.stop()
            print("Stopping Audio")
        }
       
        if let session = captureSession {
            // Remove audio inputs
            for input in session.inputs {
                if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device.hasMediaType(.audio) {
                    session.removeInput(deviceInput)
                }
            }
            
            // Remove audio outputs in case of switch to stereo
            for output in session.outputs {
                if output is AVCaptureAudioDataOutput {
                    session.removeOutput(output)
                }
            }
        }
    }
    
    // Audio Session
    func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker] )
            try audioSession.setActive(true)
          
        } catch {
            print("Failed to set up audio session: \(error)")
        }
    }
    
    // Connect the Output to the Sample Buffer
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Convert the sample buffer directly to PCM buffer
        guard let pcmBuffer = self.sampleBufferToPCMBuffer(sampleBuffer) else {
            print("Error converting sample buffer to PCM buffer")
            return
        }
        
        // Schedule the buffer for playback and play
        audioPlayerNode.scheduleBuffer(pcmBuffer) {
        }
    }
    
    // The PCM Sample Buffer
    func sampleBufferToPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        // Check buffer validity
        if !CMSampleBufferIsValid(sampleBuffer) {
            print("Invalid sample buffer")
            return nil
        }
        
        // Create an AudioBufferList
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(mNumberBuffers: UInt32(detectedChannels), mBuffers: AudioBuffer(mNumberChannels: detectedChannels, mDataByteSize: 0, mData: nil))
        
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &audioBufferList, bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        
        guard status == noErr else {
            print("Error getting audio buffer list from sample buffer. OSStatus: \(status)")
            return nil
        }
        
        // Create a PCM buffer from the audio buffer list
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat!, frameCapacity: AVAudioFrameCount(frameCount)) else {
            print("Failed to create audio buffer.")
            return nil
        }
        /*
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
            print("Sample Buffer Format: \(streamDescription.debugDescription)")
        }
        */
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        guard let floatChannelData = pcmBuffer.floatChannelData else {
            print("Error accessing PCM buffer's float channel data")
            return nil
        }
        
        let int16DataBytes = audioBufferList.mBuffers.mData?.assumingMemoryBound(to: Int16.self)
        
        if detectedChannels == 2 {
            let leftChannel = floatChannelData[0]
            let rightChannel = floatChannelData[1]
            
            for frameIndex in 0..<Int(frameCount) {
                leftChannel[frameIndex] = Float(int16DataBytes![2 * frameIndex]) / Float(Int16.max)     // Left channel
                rightChannel[frameIndex] = Float(int16DataBytes![2 * frameIndex + 1]) / Float(Int16.max) // Right channel
            }
        } else if detectedChannels == 1 {
            let monoChannel = floatChannelData[0]
            
            for frameIndex in 0..<Int(frameCount) {
                monoChannel[frameIndex] = Float(int16DataBytes![frameIndex]) / Float(Int16.max)
            }
        } else {
            print("Unsupported number of channels: \(detectedChannels)")
            return nil
        }
        
        return pcmBuffer
    }
}

