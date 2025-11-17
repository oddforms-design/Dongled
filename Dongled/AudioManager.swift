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

            /// Check for nil input
            guard let availableInputs = session.availableInputs else {
                print("No available audio inputs. Aborting audio engine start.")
                return
            }

            /// USB devices only please on MacOS
            guard let usbInput = availableInputs.first(where: { $0.portType == .usbAudio }) else {
                print("No USB audio input found. Blocking audio engine startup.")
                return
            }
            /// Assign the preferred input to USB
            do {
                try session.setPreferredInput(usbInput)
                print("Selected USB audio input: \(usbInput.portName) [type: \(usbInput.portType.rawValue)]")
            } catch {
                print("Failed to set preferred USB audio input: \(error)")
                return
            }

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            /// `outputFormat` contains the hardware sample-rate/channels and is required here.
            let format = inputNode.outputFormat(forBus: 0)

            guard format.channelCount > 0 else {
                print("Invalid input format returned from AVAudioEngine. Skipping connection.")
                return
            }

            print("Configuring audio engine with input format:")
            print(" - Channels: \(format.channelCount) @ \(format.sampleRate) Hz")

            engine.connect(inputNode, to: engine.mainMixerNode, format: format)
            engine.prepare()
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
