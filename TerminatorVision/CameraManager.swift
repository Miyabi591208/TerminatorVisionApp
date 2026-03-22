import Foundation
import AVFoundation
import SwiftUI
import ImageIO

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "terminatorvision.session.queue", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "terminatorvision.frame.queue", qos: .userInitiated)
    private var isConfigured = false
    private var currentCameraPosition: AVCaptureDevice.Position = .back

    override init() {
        super.init()
    }

    private func configureSession() {
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        let device =
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ??
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)

        guard let device else {
            print("No available camera device found")
            session.commitConfiguration()
            return
        }

        do {
            try configureDevice(device)
            currentCameraPosition = device.position

            let input = try AVCaptureDeviceInput(device: device)

            guard session.canAddInput(input) else {
                print("Cannot add camera input to session")
                session.commitConfiguration()
                return
            }

            session.addInput(input)
            print("Camera input added successfully")
        } catch {
            print("Failed to create AVCaptureDeviceInput: \(error)")
            session.commitConfiguration()
            return
        }

        if session.canAddOutput(videoOutput) {
            videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            session.addOutput(videoOutput)
            print("Video output added successfully")
        } else {
            print("Cannot add video output")
        }

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = false
            }
        }

        session.commitConfiguration()
        isConfigured = true
        print("Camera session configured")
    }

    private func configureDevice(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }

        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }

        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 }) {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        }
    }

    func start() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        print("Camera authorization status: \(status.rawValue)")

        switch status {
        case .authorized:
            sessionQueue.async {
                self.configureSession()
                if !self.session.isRunning {
                    self.session.startRunning()
                    print("Capture session started")
                }
            }

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                print("Camera access granted: \(granted)")

                guard granted else {
                    print("Camera permission denied")
                    return
                }

                self.sessionQueue.async {
                    self.configureSession()
                    if !self.session.isRunning {
                        self.session.startRunning()
                        print("Capture session started")
                    }
                }
            }

        case .denied, .restricted:
            print("Camera permission denied or restricted")

        @unknown default:
            print("Unknown camera authorization status")
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
                print("Capture session stopped")
            }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer, visionOrientation)
    }

    private var visionOrientation: CGImagePropertyOrientation {
        switch currentCameraPosition {
        case .front:
            return .leftMirrored
        case .back:
            return .right
        default:
            return .right
        }
    }
}
