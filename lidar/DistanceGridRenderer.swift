//
//  DistanceGridRenderer.swift
//  lidar
//
//  Created by Ted Schultz on 7/30/26.
//

import CoreGraphics
import CoreVideo
import UIKit

enum DistanceGridRenderer {
    /// Renders upright millimeter labels in view/display space.
    static func makeImage(
        from depthMap: CVPixelBuffer,
        viewportSize: CGSize,
        displayTransform: CGAffineTransform,
        maxMeters: Float
    ) -> UIImage? {
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        guard depthWidth > 0, depthHeight > 0 else { return nil }
        guard viewportSize.width > 1, viewportSize.height > 1 else { return nil }

        let minD: Float = 0.05
        let maxD = max(maxMeters, minD + 0.05)
        let columns = 8
        let rows = 12
        let renderScale: CGFloat = 2
        let canvasSize = CGSize(
            width: viewportSize.width * renderScale,
            height: viewportSize.height * renderScale
        )

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let inverseTransform = displayTransform.inverted()

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            let cellW = canvasSize.width / CGFloat(columns)
            let cellH = canvasSize.height / CGFloat(rows)
            let fontSize = max(9, min(cellW, cellH) * 0.20)
            let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
                .strokeColor: UIColor.black.withAlphaComponent(0.85),
                .strokeWidth: -3
            ]
            let dotRadius = max(2.5, fontSize * 0.22)

            for row in 0..<rows {
                for column in 0..<columns {
                    let viewX = (CGFloat(column) + 0.5) / CGFloat(columns)
                    let viewY = (CGFloat(row) + 0.5) / CGFloat(rows)
                    let imagePoint = CGPoint(x: viewX, y: viewY).applying(inverseTransform)

                    guard imagePoint.x >= 0, imagePoint.x <= 1,
                          imagePoint.y >= 0, imagePoint.y <= 1 else {
                        continue
                    }

                    let depthX = Int((imagePoint.x * CGFloat(depthWidth)).rounded())
                    let depthY = Int((imagePoint.y * CGFloat(depthHeight)).rounded())

                    guard let depth = averagedDepth(
                        baseAddress: baseAddress,
                        bytesPerRow: bytesPerRow,
                        width: depthWidth,
                        height: depthHeight,
                        x: depthX,
                        y: depthY
                    ),
                    depth.isFinite,
                    depth >= minD,
                    depth <= maxD else {
                        continue
                    }

                    let samplePoint = CGPoint(
                        x: (CGFloat(column) + 0.5) * cellW,
                        y: (CGFloat(row) + 0.5) * cellH
                    )

                    // Dot marks the exact depth sample location.
                    let dotRect = CGRect(
                        x: samplePoint.x - dotRadius,
                        y: samplePoint.y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )
                    cg.setFillColor(UIColor.white.cgColor)
                    cg.fillEllipse(in: dotRect)
                    cg.setStrokeColor(UIColor.black.withAlphaComponent(0.75).cgColor)
                    cg.setLineWidth(max(1, dotRadius * 0.35))
                    cg.strokeEllipse(in: dotRect)

                    let mm = Int((depth * 1000).rounded())
                    let text = "\(mm)" as NSString
                    let textSize = text.size(withAttributes: attrs)
                    let textRect = CGRect(
                        x: samplePoint.x - textSize.width / 2,
                        y: samplePoint.y - textSize.height - dotRadius - 2,
                        width: textSize.width,
                        height: textSize.height
                    )
                    text.draw(in: textRect, withAttributes: attrs)
                }
            }
        }

        return image
    }

    private static func averagedDepth(
        baseAddress: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        x: Int,
        y: Int
    ) -> Float? {
        let clampedX = min(max(x, 0), width - 1)
        let clampedY = min(max(y, 0), height - 1)
        var sum: Float = 0
        var count: Float = 0
        let radius = 1

        for dy in -radius...radius {
            let sampleY = min(max(clampedY + dy, 0), height - 1)
            let row = baseAddress.advanced(by: sampleY * bytesPerRow)
                .assumingMemoryBound(to: Float32.self)
            for dx in -radius...radius {
                let sampleX = min(max(clampedX + dx, 0), width - 1)
                let value = row[sampleX]
                if value.isFinite, value > 0.01 {
                    sum += value
                    count += 1
                }
            }
        }

        guard count > 0 else { return nil }
        return sum / count
    }
}
