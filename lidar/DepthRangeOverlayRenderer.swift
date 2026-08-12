//
//  DepthRangeOverlayRenderer.swift
//  lidar
//
//  Created by Ted Schultz on 7/30/26.
//

import CoreGraphics
import CoreVideo
import UIKit

enum DepthRangeOverlayRenderer {
    /// Renders a view-aligned overlay of in-range depth pixels (same mask as the TIFF).
    /// Outside the fixed depth range is transparent; inside is a translucent false-color of distance.
    static func makeImage(
        from depthMap: CVPixelBuffer,
        viewportSize: CGSize,
        displayTransform: CGAffineTransform
    ) -> UIImage? {
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        guard depthWidth > 0, depthHeight > 0 else { return nil }
        guard viewportSize.width > 1, viewportSize.height > 1 else { return nil }

        let minD = DepthRange.minMeters
        let maxD = DepthRange.maxMeters
        let range = maxD - minD
        let inverseTransform = displayTransform.inverted()

        // Overlay is a preview only — keep it cheap (~QVGA-ish).
        let maxDimension: CGFloat = 320
        let scale = min(1, maxDimension / max(viewportSize.width, viewportSize.height))
        let outWidth = max(1, Int((viewportSize.width * scale).rounded()))
        let outHeight = max(1, Int((viewportSize.height * scale).rounded()))

        var pixels = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        let lut = Self.colorLUT
        let alpha: Float = 0.55
        let alphaByte = UInt8((alpha * 255).rounded())

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let outWidthF = CGFloat(outWidth)
        let outHeightF = CGFloat(outHeight)
        let depthWidthF = CGFloat(depthWidth)
        let depthHeightF = CGFloat(depthHeight)

        for y in 0..<outHeight {
            let viewY = (CGFloat(y) + 0.5) / outHeightF
            let rowBase = y * outWidth
            for x in 0..<outWidth {
                let viewX = (CGFloat(x) + 0.5) / outWidthF
                let imagePoint = CGPoint(x: viewX, y: viewY).applying(inverseTransform)

                guard imagePoint.x >= 0, imagePoint.x <= 1,
                      imagePoint.y >= 0, imagePoint.y <= 1 else {
                    continue
                }

                let depthX = min(max(Int(imagePoint.x * depthWidthF), 0), depthWidth - 1)
                let depthY = min(max(Int(imagePoint.y * depthHeightF), 0), depthHeight - 1)
                let row = baseAddress.advanced(by: depthY * bytesPerRow)
                    .assumingMemoryBound(to: Float32.self)
                let depth = row[depthX]

                guard depth.isFinite, depth >= minD, depth <= maxD else {
                    continue
                }

                let t = (depth - minD) / range
                let lutIndex = min(max(Int(t * 255), 0), 255)
                let color = lut[lutIndex]
                let index = (rowBase + x) * 4
                pixels[index] = UInt8((Float(color.r) * alpha).rounded())
                pixels[index + 1] = UInt8((Float(color.g) * alpha).rounded())
                pixels[index + 2] = UInt8((Float(color.b) * alpha).rounded())
                pixels[index + 3] = alphaByte
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: &pixels,
            width: outWidth,
            height: outHeight,
            bitsPerComponent: 8,
            bytesPerRow: outWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ),
        let cgImage = context.makeImage() else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// Near → far: red → yellow → green → cyan → blue (precomputed; avoids UIColor per pixel).
    private static let colorLUT: [(r: UInt8, g: UInt8, b: UInt8)] = {
        (0..<256).map { i in
            let hue = CGFloat(i) / 255.0 * 0.7
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1)
                .getRed(&r, green: &g, blue: &b, alpha: nil)
            return (
                UInt8((r * 255).rounded()),
                UInt8((g * 255).rounded()),
                UInt8((b * 255).rounded())
            )
        }
    }()
}
