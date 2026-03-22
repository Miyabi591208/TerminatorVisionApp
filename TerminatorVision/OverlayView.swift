//
//  OverlayView.swift
//  TerminatorVision
//
//  Created by 齋藤仁志 on 2026/03/22.
//

import SwiftUI

struct OverlayView: View {
    let boxes: [DetectionBox]
    let telemetry: TargetTelemetry
    let silhouette: PersonSilhouette?
    let environmentSamples: [CGFloat]
    let voiceSamples: [CGFloat]
    let environmentLevel: CGFloat
    let voiceLevel: CGFloat

    @State private var blink = false
    private let portraitVideoSize = CGSize(width: 1280, height: 720)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(boxes.enumerated()), id: \.element.id) { index, box in
                    let rect = convertRect(box.rect, in: geo.size)
                    let isPrimaryTarget = index == 0

                    if isPrimaryTarget, let silhouette {
                        SilhouetteOverlayView(silhouette: silhouette, converter: { convertRect($0, in: geo.size) })
                            .opacity(blink ? 0.55 : 0.22)
                    }

                    HUDCornerShape(rect: rect, cornerLength: isPrimaryTarget ? 24 : 16)
                        .stroke(
                            isPrimaryTarget ? Color.red : Color.red.opacity(0.42),
                            lineWidth: isPrimaryTarget ? 2.4 : 1.1
                        )

                    if !isPrimaryTarget {
                        Rectangle()
                            .stroke(Color.red.opacity(0.28), lineWidth: 1)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }

                    if isPrimaryTarget {
                        let targetCenter = CGPoint(x: rect.midX, y: rect.midY)

                        TrackingCrosshairView()
                            .frame(width: min(max(rect.width * 0.62, 96), 148), height: min(max(rect.width * 0.62, 96), 148))
                            .position(targetCenter)
                            .foregroundStyle(.red)
                            .opacity(blink ? 1.0 : 0.18)
                            .scaleEffect(blink ? 1.0 : 0.92)
                            .animation(.easeInOut(duration: 0.22).repeatForever(autoreverses: true), value: blink)

                        TargetSweepView(rect: rect, blink: blink)
                        ThreatBannerView(rect: rect, telemetry: telemetry, blink: blink)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("SUBJECT // \(box.label.uppercased())")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                            Text("LOCK CONF \(String(format: "%.2f", box.confidence))")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                            Text(primaryStatusText)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .opacity(primaryStatusOpacity)
                            Text("THREAT INDEX \(String(format: "%02d", telemetry.threatScore))")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                            Text("RANGE \(String(format: "%.1f", telemetry.estimatedDistanceMeters))M")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            Rectangle()
                                .fill(Color.black.opacity(0.78))
                                .overlay(
                                    Rectangle()
                                        .stroke(Color.red, lineWidth: 1)
                                )
                        )
                        .foregroundStyle(.red)
                        .position(
                            x: min(rect.minX + 92, geo.size.width - 104),
                            y: max(rect.minY - 34, 42)
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("X:\(Int(targetCenter.x)) Y:\(Int(targetCenter.y))")
                            Text("W:\(Int(rect.width)) H:\(Int(rect.height))")
                            Text("VECTOR \(Int(rect.midX - geo.size.width / 2)):\(Int(geo.size.height / 2 - rect.midY))")
                            Text("OFFSET \(telemetry.lateralOffset):\(telemetry.verticalOffset)")
                            Text("STABILITY \(telemetry.stabilityScore)")
                        }
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.92))
                        .position(
                            x: min(rect.maxX - 74, geo.size.width - 84),
                            y: min(rect.maxY + 26, geo.size.height - 34)
                        )
                    }
                }

                RecognitionReadoutView(
                    telemetry: telemetry,
                    silhouette: silhouette,
                    blink: blink
                )
                .position(x: geo.size.width - 108, y: 112)

                FixedCenterHUD()
                    .stroke(Color.red.opacity(0.55), lineWidth: 1.2)
                    .frame(width: 90, height: 90)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .overlay(alignment: .leading) {
                AudioWaveformHUD(
                    environmentSamples: environmentSamples,
                    voiceSamples: voiceSamples,
                    environmentLevel: environmentLevel,
                    voiceLevel: voiceLevel,
                    blink: blink
                )
                .padding(.leading, 12)
                .padding(.bottom, 18)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .onAppear {
                blink = true
            }
        }
        .allowsHitTesting(false)
    }

    private var primaryStatusText: String {
        switch telemetry.lockState {
        case .scanning:
            return "SEARCH PATTERN ACTIVE"
        case .acquiring:
            return "TARGET ACQUIRING"
        case .analyzing:
            return blink ? "ANALYZING THREAT PROFILE" : "SYNCHRONIZING TRACK VECTOR"
        case .locked:
            return blink ? "TARGET ACQUIRED" : "LOCK MAINTAINED"
        }
    }

    private var primaryStatusOpacity: Double {
        switch telemetry.lockState {
        case .locked:
            return blink ? 1.0 : 0.18
        case .analyzing:
            return blink ? 1.0 : 0.12
        default:
            return blink ? 1.0 : 0.24
        }
    }

    private func convertRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        let scale = max(
            size.width / portraitVideoSize.width,
            size.height / portraitVideoSize.height
        )

        let scaledVideoSize = CGSize(
            width: portraitVideoSize.width * scale,
            height: portraitVideoSize.height * scale
        )

        let videoOrigin = CGPoint(
            x: (size.width - scaledVideoSize.width) / 2,
            y: (size.height - scaledVideoSize.height) / 2
        )

        let metadataRect = CGRect(
            x: normalized.minX,
            y: 1 - normalized.maxY,
            width: normalized.width,
            height: normalized.height
        )

        return CGRect(
            x: videoOrigin.x + (metadataRect.minX * scaledVideoSize.width),
            y: videoOrigin.y + (metadataRect.minY * scaledVideoSize.height),
            width: metadataRect.width * scaledVideoSize.width,
            height: metadataRect.height * scaledVideoSize.height
        )
    }
}

struct SilhouetteOverlayView: View {
    let silhouette: PersonSilhouette
    let converter: (CGRect) -> CGRect

    var body: some View {
        Canvas { context, _ in
            for strip in silhouette.strips {
                let normalizedRect = CGRect(
                    x: strip.startX,
                    y: strip.y - 0.006,
                    width: strip.endX - strip.startX,
                    height: 0.012
                )
                let rect = converter(normalizedRect)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(4, rect.height / 2)),
                    with: .color(.red.opacity(0.38))
                )
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}

struct RecognitionReadoutView: View {
    let telemetry: TargetTelemetry
    let silhouette: PersonSilhouette?
    let blink: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("RECOGNITION")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Text("STATE \(telemetry.lockState.rawValue)")
            Text("MASK \(maskCoverageText)")
            Text(zoneText)
            Text("RANGE \(String(format: "%.1f", telemetry.estimatedDistanceMeters))M")
            Text("OFFSET \(telemetry.lateralOffset):\(telemetry.verticalOffset)")
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.red.opacity(blink ? 0.98 : 0.45))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Rectangle()
                .fill(Color.black.opacity(0.7))
                .overlay(Rectangle().stroke(Color.red.opacity(0.8), lineWidth: 1))
        )
    }

    private var maskCoverageText: String {
        guard let silhouette else { return "0.0%" }
        return String(format: "%.1f%%", silhouette.coverage * 100)
    }

    private var zoneText: String {
        silhouette?.zoneReadout ?? "HEAD:0 TORSO:0 LEGS:0"
    }
}

struct AudioWaveformHUD: View {
    let environmentSamples: [CGFloat]
    let voiceSamples: [CGFloat]
    let environmentLevel: CGFloat
    let voiceLevel: CGFloat
    let blink: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("AUDIO INPUT")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.red.opacity(blink ? 0.96 : 0.45))

            waveformPanel(title: "ENV", samples: environmentSamples, level: environmentLevel, scaleText: "WIDE")
            waveformPanel(title: "VOICE", samples: voiceSamples, level: voiceLevel, scaleText: "FOCUS")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            Rectangle()
                .fill(Color.black.opacity(0.66))
                .overlay(Rectangle().stroke(Color.red.opacity(0.42), lineWidth: 1))
        )
    }

    private func waveformPanel(title: String, samples: [CGFloat], level: CGFloat, scaleText: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(scaleText)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.red.opacity(0.9))

            Canvas { context, size in
                guard !samples.isEmpty else { return }

                let midY = size.height / 2
                let stepX = size.width / CGFloat(max(samples.count - 1, 1))
                let gridLevels = 3

                for level in 1...gridLevels {
                    let offset = (size.height * 0.16) * CGFloat(level)

                    var upper = Path()
                    upper.move(to: CGPoint(x: 0, y: midY - offset))
                    upper.addLine(to: CGPoint(x: size.width, y: midY - offset))
                    context.stroke(upper, with: .color(.red.opacity(0.10)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))

                    var lower = Path()
                    lower.move(to: CGPoint(x: 0, y: midY + offset))
                    lower.addLine(to: CGPoint(x: size.width, y: midY + offset))
                    context.stroke(lower, with: .color(.red.opacity(0.10)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                }

                var path = Path()
                path.move(to: CGPoint(x: 0, y: midY))

                for (index, sample) in samples.enumerated() {
                    let x = CGFloat(index) * stepX
                    let amplitude = max(3, sample * (size.height * 0.92))
                    let phase = index.isMultiple(of: 2) ? amplitude : amplitude * 0.84
                    path.addLine(to: CGPoint(x: x, y: midY - phase))
                }

                for (index, sample) in samples.enumerated().reversed() {
                    let x = CGFloat(index) * stepX
                    let amplitude = max(3, sample * (size.height * 0.92))
                    let phase = index.isMultiple(of: 2) ? amplitude : amplitude * 0.84
                    path.addLine(to: CGPoint(x: x, y: midY + phase))
                }

                path.closeSubpath()
                context.fill(path, with: .color(.red.opacity(0.20)))
                context.stroke(path, with: .color(.red.opacity(0.86)), lineWidth: 1.1)

                var centerLine = Path()
                centerLine.move(to: CGPoint(x: 0, y: midY))
                centerLine.addLine(to: CGPoint(x: size.width, y: midY))
                context.stroke(centerLine, with: .color(.red.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .frame(width: 92, height: 28)
            .overlay(
                Rectangle()
                    .stroke(Color.red.opacity(0.65), lineWidth: 1)
            )

            Text("LVL \(String(format: "%.2f", level))")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.red.opacity(0.88))
        }
    }
}

struct ThreatBannerView: View {
    let rect: CGRect
    let telemetry: TargetTelemetry
    let blink: Bool

    var body: some View {
        return ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .overlay(Rectangle().stroke(Color.red.opacity(0.5), lineWidth: 1))

            HStack(spacing: 10) {
                Text("THREAT")
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Color.red.opacity(blink ? 1.0 : 0.18))
                    .shadow(color: .red.opacity(blink ? 0.9 : 0.18), radius: blink ? 10 : 2)

                Text(String(format: "%02d", telemetry.threatScore))
                    .font(.system(size: 18, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color.red.opacity(blink ? 0.96 : 0.3))
            }

            VStack {
                Spacer()
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { index in
                        Rectangle()
                            .fill(index < highlightedSegments ? Color.red.opacity(blink ? 0.95 : 0.28) : Color.red.opacity(0.10))
                            .frame(width: 14, height: 3)
                    }
                }
                .padding(.bottom, 5)
            }
        }
        .frame(width: 170, height: 40)
        .position(x: rect.midX, y: max(rect.minY - 28, 28))
    }

    private var highlightedSegments: Int {
        max(1, min(7, Int(round((Double(telemetry.threatScore) / 100) * 7))))
    }
}

struct TargetSweepView: View {
    let rect: CGRect
    let blink: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.clear, Color.red.opacity(blink ? 0.22 : 0.08), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: rect.width, height: max(18, rect.height * 0.18))
                .position(x: rect.midX, y: rect.midY)
                .blendMode(.screen)

            Path { path in
                path.move(to: CGPoint(x: rect.minX - 20, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX + 20, y: rect.midY))
                path.move(to: CGPoint(x: rect.midX, y: rect.minY - 20))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY + 20))
            }
            .stroke(Color.red.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }
}

struct TerminatorScreenEffect: View {
    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { context in
                let time = context.date.timeIntervalSinceReferenceDate

                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.45, green: 0.02, blue: 0.02).opacity(0.36),
                            Color.black.opacity(0.08),
                            Color(red: 0.78, green: 0.08, blue: 0.08).opacity(0.28)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.screen)

                    ScanlineView(time: time)
                        .opacity(0.28)

                    NoiseView(time: time)
                        .opacity(0.16)

                    Rectangle()
                        .fill(
                            RadialGradient(
                                colors: [Color.clear, Color.black.opacity(0.62)],
                                center: .center,
                                startRadius: min(geo.size.width, geo.size.height) * 0.18,
                                endRadius: max(geo.size.width, geo.size.height) * 0.72
                            )
                        )

                    Rectangle()
                        .fill(Color.red.opacity(0.10))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct ScanlineView: View {
    let time: TimeInterval

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.height + 160
            let offset = CGFloat(time.truncatingRemainder(dividingBy: 2.4) / 2.4) * travel - 80

            ZStack {
                Canvas { context, size in
                    let stripeHeight: CGFloat = 4
                    var y: CGFloat = 0

                    while y < size.height {
                        let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
                        context.fill(Path(rect), with: .color(.red.opacity(0.12)))
                        y += stripeHeight
                    }
                }

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.clear, Color.red.opacity(0.30), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 160)
                    .offset(y: offset - geo.size.height / 2)
                    .blur(radius: 14)
            }
        }
    }
}

struct NoiseView: View {
    let time: TimeInterval

    var body: some View {
        Canvas { context, size in
            let cellSize: CGFloat = 8
            let columns = Int(size.width / cellSize)
            let rows = Int(size.height / cellSize)
            let phase = Int(time * 100)

            for row in 0...rows {
                for column in 0...columns where noiseValue(x: column, y: row, phase: phase) > 0.81 {
                    let rect = CGRect(
                        x: CGFloat(column) * cellSize,
                        y: CGFloat(row) * cellSize,
                        width: cellSize,
                        height: cellSize
                    )
                    context.fill(Path(rect), with: .color(.white.opacity(0.20)))
                }
            }
        }
        .blendMode(.screen)
    }

    private func noiseValue(x: Int, y: Int, phase: Int) -> Double {
        let seed = x &* 73856093 ^ y &* 19349663 ^ phase &* 83492791
        return Double(abs(seed % 1000)) / 1000.0
    }
}

struct HUDCornerShape: Shape {
    let rect: CGRect
    let cornerLength: CGFloat

    func path(in _: CGRect) -> Path {
        var path = Path()

        let x = rect.minX
        let y = rect.minY
        let w = rect.width
        let h = rect.height
        let c = min(cornerLength, min(w, h) / 3)

        // 左上
        path.move(to: CGPoint(x: x, y: y + c))
        path.addLine(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + c, y: y))

        // 右上
        path.move(to: CGPoint(x: x + w - c, y: y))
        path.addLine(to: CGPoint(x: x + w, y: y))
        path.addLine(to: CGPoint(x: x + w, y: y + c))

        // 左下
        path.move(to: CGPoint(x: x, y: y + h - c))
        path.addLine(to: CGPoint(x: x, y: y + h))
        path.addLine(to: CGPoint(x: x + c, y: y + h))

        // 右下
        path.move(to: CGPoint(x: x + w - c, y: y + h))
        path.addLine(to: CGPoint(x: x + w, y: y + h))
        path.addLine(to: CGPoint(x: x + w, y: y + h - c))

        return path
    }
}

struct TrackingCrosshairView: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let midX = w / 2
            let midY = h / 2

            Path { path in
                // 外周リング
                let ringRect = CGRect(x: 10, y: 10, width: w - 20, height: h - 20)
                path.addEllipse(in: ringRect)

                // 横線
                path.move(to: CGPoint(x: 0, y: midY))
                path.addLine(to: CGPoint(x: w, y: midY))

                // 縦線
                path.move(to: CGPoint(x: midX, y: 0))
                path.addLine(to: CGPoint(x: midX, y: h))

                // 中央四角
                let boxSize: CGFloat = min(w, h) * 0.18
                let origin = CGPoint(x: midX - boxSize / 2, y: midY - boxSize / 2)
                path.addRect(CGRect(origin: origin, size: CGSize(width: boxSize, height: boxSize)))
            }
            .stroke(Color.red, lineWidth: 1.5)
        }
    }
}

struct FixedCenterHUD: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midX = rect.midX
        let midY = rect.midY

        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))

        path.move(to: CGPoint(x: midX, y: rect.minY))
        path.addLine(to: CGPoint(x: midX, y: rect.maxY))

        let innerSize = min(rect.width, rect.height) * 0.20
        path.addRect(
            CGRect(
                x: midX - innerSize / 2,
                y: midY - innerSize / 2,
                width: innerSize,
                height: innerSize
            )
        )

        return path
    }
}
