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
    /// External displays enumerate as USB audio; never auto-select them
    private static let blockedNames = ["Display"]

    /// How the audio input gets chosen on macOS
    enum InputChoice {
        case automatic(AVAudioSessionPortDescription?)
        case userSelection([AVAudioSessionPortDescription])
    }

    // MARK: - Audio Lifecycle

    // Auto-selects a lone USB capture input; multiple candidates defer to the user
    func audioInputChoice() -> InputChoice {
        guard let session = activateSession(), let inputs = session.availableInputs else {
            return .automatic(nil)
        }
        let usbInputs = inputs.filter { $0.portType == .usbAudio }
        let candidates = usbInputs.filter { input in
            !Self.blockedNames.contains { input.portName.localizedCaseInsensitiveContains($0) }
        }
        if candidates.count == 1 { return .automatic(candidates[0]) }
        if candidates.count > 1 { return .userSelection(usbInputs) }
        return .automatic(nil)
    }

    // Starts audio pass-through with the given input, or the first USB input that isn't a display
    internal func startEngineInputPassThrough(preferredInput: AVAudioSessionPortDescription? = nil) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            guard let session = self.activateSession() else { return }
            print("Starting AVAudio Pass-Through.")

            /// Check for nil input
            guard let availableInputs = session.availableInputs else {
                print("No available audio inputs. Aborting audio engine start.")
                return
            }

            /// Use the caller's pick, else USB audio only filtering out display microphones
            guard let usbInput = preferredInput ?? availableInputs.first(where: { input in
                input.portType == .usbAudio &&
                !Self.blockedNames.contains(where: { input.portName.localizedCaseInsensitiveContains($0) })
            }) else {
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

                /// Diagnostic: where is audio actually routed?
                let route = session.currentRoute
                print("Audio route inputs:")
                for input in route.inputs {
                    print("  ← \(input.portName) [type: \(input.portType.rawValue), UID: \(input.uid)]")
                }
                print("Audio route outputs:")
                for output in route.outputs {
                    print("  → \(output.portName) [type: \(output.portType.rawValue), UID: \(output.uid)]")
                }
                print("Output volume: \(engine.mainMixerNode.outputVolume)")
                print("Input node volume: \(inputNode.volume)")
            } catch {
                print("Failed to start AVAudioEngine: \(error)")
            }
        }
    }

    // Configures and activates the shared audio session
    private func activateSession() -> AVAudioSession? {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .allowBluetoothA2DP]
            )
            try session.setActive(true)
            try session.overrideOutputAudioPort(.none)
        } catch {
            print("AVAudioSession setup failed: \(error)")
            return nil
        }
        return session
    }

    // Stops the audio engine and deactivates the audio session
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

}
