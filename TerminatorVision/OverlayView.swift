//
//  OverlayView.swift
//  TerminatorVision
//
//  Created by 齋藤仁志 on 2026/03/22.
//

import SwiftUI

struct OverlayView: View {
    let boxes: [DetectionBox]

    var body: some View {
        GeometryReader { geo in
            ForEach(boxes) { box in
                let rect = convertRect(box.rect, in: geo.size)

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(Color.red, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    Text("\(box.label) \(String(format: "%.2f", box.confidence))")
                        .font(.caption2)
                        .padding(4)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.red)
                        .position(x: rect.minX + 60, y: rect.minY - 10)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func convertRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        let width = normalized.width * size.width
        let height = normalized.height * size.height
        let x = normalized.minX * size.width
        let y = (1 - normalized.maxY) * size.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
