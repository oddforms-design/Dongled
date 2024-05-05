//
//  CaptureSessionManager.swift
//  Dongled
//
//  Created by Charles Sheppa on 5/5/24.
//

import AVFoundation

class CaptureManager {
    
    let audioManager = AudioManager()
    var viewController: ViewController?
    
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
   
    
    func setupCaptureSession() {
        if captureSession == nil {
            captureSession = AVCaptureSession()
        }
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        
        if let device = discoverySession.devices.first {
            if let viewController = viewController {
                viewController.showConnectingUI()
            } else {
                print("Could not access viewcontroller")
            }
            // Delay the rest of the code by 2 seconds to ensure device is booted
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self else { return }
                
                self.launchSession(with: device)
                
                if let viewController = self.viewController {
                    viewController.showActiveUI()
                }
            }
        } else {
            if let viewController = self.viewController {
                viewController.showIdleUI()
            }
        }
    }
    
    // Main Setup Functions
    
    func launchSession(with device: AVCaptureDevice) {
        self.captureSession?.beginConfiguration()
        self.setupDeviceInput(for: device)
        audioManager.self.setupAudioSession()
        audioManager.self.setupAudioEngine()
        audioManager.self.configureAudio(forCaptureSession: self.captureSession!)
        audioManager.self.startAudio()
        self.captureSession?.commitConfiguration()
        self.startSession()
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
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                self.viewController?.noDeviceLabel.isHidden = true
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
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let viewController = self.viewController else { return }
            
            previewLayer.frame = viewController.view.bounds
            previewLayer.videoGravity = .resizeAspect
            previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            viewController.view.layer.insertSublayer(previewLayer, at: 0)
        }
        
        if let device = self.captureSession?.inputs.first as? AVCaptureDeviceInput {
            self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device.device, previewLayer: previewLayer)
            self.applyVideoRotationForPreview()
        }
    }

    func rebootSession(){/*
        sessionStop()
        
        DispatchQueue.main.async {
            self.viewController.showConnectingUI()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if UIApplication.shared.applicationState == .active {
                let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
                    
                if let device = discoverySession.devices.first {
                    self.launchSession(with: device)

                    DispatchQueue.main.async {
                        UIApplication.shared.isIdleTimerDisabled = true
                        self.isStatusBarHidden = true
                        self.coverView.isHidden = true
                        self.noDeviceLabel.isHidden = true
                        }
                    }
                } else {
                    self.sessionBlocked = true
                    print("App is not active. Preventing session start.")
                }
            }*/
    }
    func startSession() {
        guard let session = captureSession else {
            print("Session is nil")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }
    
    func sessionStop() {
        if let session = captureSession
        {
            session.stopRunning()
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
   
}
