//
//  Detector.swift
//  TerminatorVision
//
//  Created by 齋藤仁志 on 2026/03/22.
//

import Foundation
import Vision
import CoreML

struct DetectionBox: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let rect: CGRect   // normalized [0,1]
}

final class Detector: ObservableObject {
    @Published var boxes: [DetectionBox] = []

    private var visionModel: VNCoreMLModel?

    init() {
        setupModel()
    }

    private func setupModel() {
        do {
            // ここを Xcode が生成したモデル名に変更
            let coreMLModel = try YourModelName(configuration: MLModelConfiguration()).model
            visionModel = try VNCoreMLModel(for: coreMLModel)
        } catch {
            print("Failed to load Core ML model: \(error)")
        }
    }

    func detect(pixelBuffer: CVPixelBuffer) {
        guard let visionModel else { return }

        let request = VNCoreMLRequest(model: visionModel) { [weak self] request, error in
            if let error = error {
                print("Vision request error: \(error)")
                return
            }

            // まずは Vision 標準の object observation を期待する形
            if let results = request.results as? [VNRecognizedObjectObservation] {
                let mapped = results.map { obs in
                    let top = obs.labels.first
                    return DetectionBox(
                        label: top?.identifier ?? "object",
                        confidence: top?.confidence ?? 0,
                        rect: obs.boundingBox
                    )
                }

                DispatchQueue.main.async {
                    self?.boxes = mapped
                }
            } else {
                DispatchQueue.main.async {
                    self?.boxes = []
                }
                print("Unexpected result type. You may need custom YOLO post-processing.")
            }
        }

        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])

        do {
            try handler.perform([request])
        } catch {
            print("Failed to perform Vision request: \(error)")
        }
    }
}
