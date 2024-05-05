//
//  CaptureSessionManager.swift
//  Dongled
//
//  Created by Charles Sheppa on 5/5/24.
//

import AVFoundation
import UIKit

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
            viewController?.showConnectingTextUI()
            // Delay the rest of the code by 2 seconds to ensure device is booted
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self else { return }
                
                self.launchSession(with: device)
                
                viewController?.showActiveUI()
            }
        } else {
            viewController?.showIdleUI()
        }
    }
    
    // Main Setup Functions
    
    func launchSession(with device: AVCaptureDevice) {
        captureSession?.beginConfiguration()
        setupDeviceInput(for: device)
        audioManager.setupAudioSession()
        audioManager.setupAudioEngine()
        audioManager.configureAudio(forCaptureSession: self.captureSession!)
        audioManager.startAudio()
        captureSession?.commitConfiguration()
        startSession()
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
            
            viewController?.noDeviceLabel.isHidden = true
            
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
    func applyVideoRotationForPreview() {
        guard let previewLayerConnection = previewLayer?.connection, let rotationCoordinator = rotationCoordinator else {
            return
        }
        
        let rotationAngle = rotationCoordinator.videoRotationAngleForHorizonLevelPreview
        if previewLayerConnection.isVideoRotationAngleSupported(rotationAngle) {
            previewLayerConnection.videoRotationAngle = rotationAngle
        }
    }
    func deviceDisconnected(for device: AVCaptureDevice) {
        if let viewController = self.viewController {
            viewController.showScanningTextUI()
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
        audioManager.stopAudio(withCaptureSession: captureSession)
        
        viewController?.showIdleUI()
        
        print("Session disconnect")
    }
    func rebootSession(){
        // Clean up
        sessionStop()
        
        viewController?.showConnectingTextUI()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { // Wait for Hardware
            if UIApplication.shared.applicationState == .active {
                let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
                    
                if let device = discoverySession.devices.first {
                    self.launchSession(with: device)
                    self.viewController?.showActiveUI()
                    }
                } else {
                    self.viewController?.sessionBlocked = true
                    print("App is not active. Preventing session start.")
                }
            }
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
    
   
}
