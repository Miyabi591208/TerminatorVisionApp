//
//  ContentView.swift
//  TerminatorVision
//
//  Created by 齋藤仁志 on 2026/03/21.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var detector = Detector()

    var body: some View {
        ZStack {
            CameraPreview(session: cameraManager.session)
                .ignoresSafeArea()

            OverlayView(boxes: detector.boxes)
                .ignoresSafeArea()
        }
        .onAppear {
            cameraManager.onFrame = { pixelBuffer in
                detector.detect(pixelBuffer: pixelBuffer)
            }
            cameraManager.start()
        }
        .onDisappear {
            cameraManager.stop()
        }
    }
}
