//
//  AudioManager.swift
//  Dongled
//
//  Created by Charles Sheppa on 5/5/24.
//

import AVFoundation

final class AudioManager: NSObject {

    // MARK: - Properties

    private let audioQueue = DispatchQueue(label: "com.Dongled.audioQueue", qos: .userInitiated)
    private var audioEngine: AVAudioEngine?
    weak var viewController: ViewController?

    // MARK: - Audio Lifecycle

    internal func startEngineInputPassThrough() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.mixWithOthers, .allowBluetoothA2DP]
                )
                try session.setActive(true)
                try session.overrideOutputAudioPort(.none)
                print("Starting AVAudio Pass-Through.")
            } catch {
                print("AVAudioSession setup failed: \(error)")
                return
            }

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let format = inputNode.inputFormat(forBus: 0)

            print("Configuring audio engine with input format:")
            print(" - Channels: \(format.channelCount) @ \(format.sampleRate) Hz")

            engine.connect(inputNode, to: engine.mainMixerNode, format: format)
            self.audioEngine = engine

            do {
                try engine.start()
                print("AudioEngine started → Session Running")
            } catch {
                print("Failed to start AVAudioEngine: \(error)")
            }
        }
    }

    internal func stopEnginePassThrough() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            if let engine = self.audioEngine {
                engine.stop()
                self.audioEngine = nil
                print("AudioEngine stopped.")
            }

            do {
                try AVAudioSession.sharedInstance().setActive(false)
                print("AVAudioSession deactivated.")
            } catch {
                print("Failed to deactivate AVAudioSession: \(error)")
            }
        }
    }

    internal func resetEngineInputPassThrough() {
        audioQueue.async { [weak self] in
            self?.stopEnginePassThrough()
            self?.startEngineInputPassThrough()
        }
    }
}
