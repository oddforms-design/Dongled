//
//  AudioManager.swift
//  Dongled
//
//  Created by Charles Sheppa on 5/5/24.
//

import AVFoundation

class AudioManager: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    var audioEngine: AVAudioEngine!
    var audioPlayerNode: AVAudioPlayerNode!
    var audioOutput: AVCaptureAudioDataOutput!
    var detectedChannels: UInt32 = 1
    var pcmFormat: AVAudioFormat? {
        
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: detectedChannels, interleaved: false)
    }
    private var tapArmed: Bool = false
    
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
    
    func configureAudio(forCaptureSession session: AVCaptureSession) {
        
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
        
        if detectedChannels == 0 {
            print("No audio channels detected. Aborting audio start.")
            return
        }
        
        if !(audioEngine?.isRunning ?? false) {
            do {
                try audioEngine?.start()
                print("Starting Audio Engine")
            } catch {
                print("Error starting audio engine during setup: \(error)")
                return
            }
        }
        
        if !(audioPlayerNode?.isPlaying ?? false) {
            audioPlayerNode?.play()
        }
        
        bufferTap()
        
    }
    // Audio Helpers
    func bufferTap() {
        if tapArmed {
            print("Tap is already armed.")
            return
        }
        
        tapArmed = true
        print("Arming Tap to Gain Session Control")
        
        audioPlayerNode?.installTap(onBus: 0, bufferSize: 64, format: nil) { (buffer, time) in
            if buffer.frameLength > 0 {
                self.setupAudioSession()
                self.audioPlayerNode?.removeTap(onBus: 0)
                self.tapArmed = false
                print("Tap Disarmed")
            }
        }
        // Tap Removal failsafe if unplugged immediately after plug
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
    func playAudio() {
        audioPlayerNode?.play()
    }
    // Stop the audio system
    func stopAudio(withCaptureSession session: AVCaptureSession?) {
        guard let session = session else {
            print("Capture session is nil")
            return
        }
        
        if audioEngine?.isRunning == true {
            audioEngine.stop()
        }
        audioPlayerNode.stop()
        audioEngine?.reset()
        print("Stopping Audio")
        
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
