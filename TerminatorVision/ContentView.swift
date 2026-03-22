import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var detector = Detector()
    @StateObject private var audioManager = AudioManager()

    var body: some View {
        ZStack {
            CameraPreview(session: cameraManager.session)
                .ignoresSafeArea()

            TerminatorScreenEffect()
                .ignoresSafeArea()

            OverlayView(
                boxes: detector.boxes,
                telemetry: detector.telemetry,
                silhouette: detector.silhouette,
                environmentSamples: audioManager.environmentSamples,
                voiceSamples: audioManager.voiceSamples,
                environmentLevel: audioManager.environmentLevel,
                voiceLevel: audioManager.voiceLevel
            )
                .ignoresSafeArea()

            VStack {
                topHUD
                Spacer()
                bottomHUD
                    .padding(.bottom, 130)
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 8)
        }
        .background(.black)
        .task {
            cameraManager.onFrame = { pixelBuffer, orientation in
                detector.detect(pixelBuffer: pixelBuffer, orientation: orientation)
            }
            cameraManager.start()
            audioManager.startAudioSystems()
        }
        .onDisappear {
            cameraManager.stop()
            audioManager.stopAudioSystems()
        }
    }

    private var topHUD: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("CYBERDYNE SYSTEMS")
                Text("HUMAN TARGET ACQUISITION")
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(.red.opacity(0.95))

            Spacer()

            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .trailing, spacing: 5) {
                    Text(Self.clockFormatter.string(from: context.date))
                    Text(detector.boxes.isEmpty ? "SCAN MODE" : "TARGET MODE")
                }
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.red.opacity(0.95))
            }
        }
    }

    private var bottomHUD: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("VISION: ONLINE")
                Text("FILTER: PERSON ONLY")
                Text(detector.boxes.isEmpty ? "TRACKING: SEARCHING" : "TRACKING: LOCKED")
                Text("SRC: \(detector.debugInfo.activeSource)")
                Text("STATE: \(detector.telemetry.lockState.rawValue)")
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.red.opacity(0.92))

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("TARGETS: \(detector.boxes.count)")
                Text(detector.boxes.isEmpty ? "LOCK: NONE" : "LOCK: PERSON")
                Text(targetConfidenceLine)
                Text("THREAT: \(detector.telemetry.threatScore)")
                Text("Y:\(detector.debugInfo.yoloCandidates) S:\(detector.debugInfo.segmentationDetected ? 1 : 0) H:\(detector.debugInfo.humanRectangles)")
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.red.opacity(0.92))
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
    }

    private var targetConfidenceLine: String {
        guard let target = detector.boxes.first else { return "CONF: 0.00" }
        return "CONF: \(String(format: "%.2f", target.confidence))"
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

#Preview {
    ContentView()
}
