import UIKit
import AVFoundation

class ViewController: UIViewController, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    @IBOutlet weak var noDeviceLabel: UILabel!
    @IBOutlet weak var coverView: UIView!
    var isInitialLaunch = true
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    
    var audioEngine: AVAudioEngine!
    var audioPlayerNode: AVAudioPlayerNode!
    var audioOutput: AVCaptureAudioDataOutput!
    private var tapArmed: Bool = false
    
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
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
      
            setupAudioSession()
            setupCaptureSession()
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
               
                self.captureSession?.beginConfiguration()
                self.configureExternalDevice(device)
                self.setupAudioEngine()
                self.configureAudio()
                self.startAudio()
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
            setMaxSupportedResolution(for: captureSession!)
            let preset = captureSession!.sessionPreset
               print("Capture Session is running at resolution: \(resolutionString(for: preset))")
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
            
            sessionStop()
            DispatchQueue.main.async {
                self.noDeviceLabel.text = "Connecting to Device"
            }
            
            // Delay the rest of the code by 2.2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                self.captureSession?.beginConfiguration()
                self.configureExternalDevice(device)
                self.setupAudioEngine()
                self.configureAudio()
                self.startAudio()
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
        stopAudio()
        
        print("Session disconnect")
        
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
            self.isStatusBarHidden = false
            self.noDeviceLabel.isHidden = false
            self.coverView.isHidden = false
            
        }
    }
    
    @objc func appWillResignActive(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.pauseAudio()
            self.sessionStop()
            print("Session Resigned Active")
        }
    }
    @objc func appDidBecomeActive(_ notification: Notification) {
        if isInitialLaunch {
                isInitialLaunch = false
                return  // Exit early for initial launch
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.startAudio()
            self.startSesssion()
            print("Session Resumed Active")
          }
    }
    
    // Helpers //
    func sessionStop() {
        if let session = captureSession
        {
            session.stopRunning()
        }
    }
    func setMaxSupportedResolution(for session: AVCaptureSession) {
        let presetsInDecreasingOrder: [AVCaptureSession.Preset] = [
            //.hd4K3840x2160,
            .hd1920x1080,
            .inputPriority
        ]

        for preset in presetsInDecreasingOrder {
            if session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
                break
            }
        }
    }
    
    func resolutionString(for preset: AVCaptureSession.Preset) -> String {
        switch preset {
        case .hd1920x1080:
            return "1920x1080"
        case .inputPriority:
            return "Input Priority"
        default:
            return "Unknown"
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
        NotificationCenter.default.removeObserver(self)
        isInitialLaunch = true
    }
    
    // Audio Session
    func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .mixWithOthers] )
            try audioSession.setActive(true)
          
        } catch {
            print("Failed to set up audio session: \(error)")
        }
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
    }
    
    // Discover the device and set it as the session input
    func configureAudio() {
        guard let session = captureSession else {
            print("Session is nil")
            return
        }

        let audioDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
                
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
            print("Adding Audio Output")
        }
    }
    
    func startAudio() {
        if !(audioEngine?.isRunning ?? false) {
            do {
                try audioEngine?.start()
                print("Starting Audio Engine")
            } catch {
                print("Error starting audio engine during setup: \(error)")
                return  // Early return because if the engine didn't start, we shouldn't attempt to play the node.
            }
        }
        
        if !(audioPlayerNode?.isPlaying ?? false) {
            audioPlayerNode?.play()
        }
        
        bufferTap()
        
    }
   
    func bufferTap() {
        if tapArmed {
            print("Tap is already armed.")
            return
        }

        tapArmed = true
        print("Arming Tap")

        audioPlayerNode?.installTap(onBus: 0, bufferSize: 64, format: nil) { (buffer, time) in
            if buffer.frameLength > 0 {
                self.setupAudioSession()
                self.audioPlayerNode?.removeTap(onBus: 0)
                self.tapArmed = false
                print("Tap Disarmed")
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if self.tapArmed { // Check if tap is still installed
                self.audioPlayerNode?.removeTap(onBus: 0)
                self.tapArmed = false
                print("Tap Disarmed due to timeout")
            }
        }
    }
    
    func pauseAudio() {
        audioPlayerNode?.pause()
    }
    
    // Stop the audio system
    func stopAudio() {
        if audioEngine?.isRunning == true {
            audioEngine.stop()
        }
        audioPlayerNode.stop()
        audioEngine?.reset()
        print("Stopping Audio")
        
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
