
//  AudioManager.swift
//  Dongled
//
//  Created by Charles Sheppa on 9/13/23.
//


import AVFoundation

class AudioManager: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    var captureSession: AVCaptureSession!
    var audioEngine: AVAudioEngine!

    init(captureSession: AVCaptureSession) {
        self.captureSession = captureSession
        super.init()
    }
    var audioPlayerNode: AVAudioPlayerNode!
    var audioOutput: AVCaptureAudioDataOutput!
    
    // Audio Engine
    
    let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)
    
    func setupAudioEngine() {
        
        guard let safePCMFormat = pcmFormat else {
            print("Error: PCM format is not available.")
            return
        }
        
        audioEngine = AVAudioEngine()
        audioPlayerNode = AVAudioPlayerNode()
        audioEngine.attach(audioPlayerNode)
        audioEngine.connect(audioPlayerNode, to: audioEngine.mainMixerNode, format: safePCMFormat)
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
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Convert the sample buffer directly to PCM buffer
        guard let pcmBuffer = self.sampleBufferToPCMBuffer(sampleBuffer) else {
            print("Error converting sample buffer to PCM buffer")
            return
        }
        
        // Schedule the buffer for playback and play
        audioPlayerNode.scheduleBuffer(pcmBuffer)
    }
    
    func sampleBufferToPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        // Check buffer validity
        if !CMSampleBufferIsValid(sampleBuffer) {
            print("Invalid sample buffer")
            return nil
        }
        
        // Print the format of the incoming buffer for debugging
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
            print("Sample Buffer Format: \(streamDescription.debugDescription)")
        }
        
        // Create an AudioBufferList
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
        
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
        
        let channel = floatChannelData[0]
        let int16DataBytes = audioBufferList.mBuffers.mData?.assumingMemoryBound(to: Int16.self)
        
        for frameIndex in 0..<Int(frameCount) {
            channel[frameIndex] = Float(int16DataBytes![frameIndex]) / Float(Int16.max)
        }
        
        return pcmBuffer
    }
}
