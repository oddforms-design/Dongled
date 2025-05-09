import AVFoundation

final class AudioManager: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    // MARK: - Properties

    private let audioQueue = DispatchQueue(label: "com.Dongled.audioQueue", qos: .userInitiated)
    private var audioCaptureSession: AVCaptureSession?
    private var audioInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?
    weak var viewController: ViewController?

    // MARK: - Audio Lifecycle

    internal func startEngineInputPassThrough() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            // Stop any existing session
            self.stopEnginePassThrough()

            // Discover USB audio devices
            let audioDevices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external],
                mediaType: .audio,
                position: .unspecified
            ).devices

            print("Discovered audio devices:")
            for device in audioDevices {
                print(" - \(device.localizedName) | \(device.uniqueID) | \(device.modelID)")
            }
            let devices = AVCaptureDevice.devices(for: .audio)
            for device in devices {
                print("Found audio device: \(device.localizedName), \(device.deviceType), \(device.uniqueID)")
            }
            guard let usbAudioDevice = audioDevices.first else {
                print("❌ No USB audio device found. Blocking audio capture.")
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: usbAudioDevice)
                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: self.audioQueue)

                let session = AVCaptureSession()
                if session.canAddInput(input) { session.addInput(input) }
                if session.canAddOutput(output) { session.addOutput(output) }

                session.startRunning()
                print("🎙️ Audio session started with: \(usbAudioDevice.localizedName)")

                self.audioInput = input
                self.audioOutput = output
                self.audioCaptureSession = session
            } catch {
                print("❌ Failed to set up audio session: \(error)")
            }
        }
    }

    internal func stopEnginePassThrough() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            if let session = self.audioCaptureSession {
                session.stopRunning()
                self.audioInput = nil
                self.audioOutput = nil
                self.audioCaptureSession = nil
                print("🛑 Audio session stopped.")
            }
        }
    }

    internal func resetEngineInputPassThrough() {
        stopEnginePassThrough()
        startEngineInputPassThrough()
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // If needed, forward raw audio buffers here.
        // For now, just log format and silence
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let streamDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        if let s = streamDesc {
            print("🎧 Captured audio buffer — \(s.pointee.mSampleRate) Hz, \(s.pointee.mChannelsPerFrame) ch")
        }
    }
}
