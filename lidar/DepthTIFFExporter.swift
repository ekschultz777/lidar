//
//  DepthTIFFExporter.swift
//  lidar
//
//  Created by Ted Schultz on 7/30/26.
//

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DepthTIFFExporter {
    enum ExportError: LocalizedError {
        case invalidDepth
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .invalidDepth:
                return "No LiDAR depth available to export."
            case .writeFailed:
                return "Couldn't write the depth TIFF file."
            }
        }
    }

    /// Writes a Float32 grayscale TIFF where each pixel is distance in meters.
    /// Values outside `[minMeters, maxMeters]`, and invalid samples, are 0.
    static func write(
        depthMap: CVPixelBuffer,
        minMeters: Float,
        maxMeters: Float,
        outputSize: CGSize,
        displayTransform: CGAffineTransform,
        to url: URL
    ) throws {
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        guard depthWidth > 0, depthHeight > 0 else { throw ExportError.invalidDepth }
        guard outputSize.width > 1, outputSize.height > 1 else { throw ExportError.invalidDepth }

        // Preserve the view aspect ratio; keep a sensible pixel count for export.
        let maxDimension: CGFloat = 1280
        let scale = min(1, maxDimension / max(outputSize.width, outputSize.height))
        let outWidth = max(1, Int((outputSize.width * scale).rounded()))
        let outHeight = max(1, Int((outputSize.height * scale).rounded()))

        let minD = min(minMeters, maxMeters - 0.01)
        let maxD = max(maxMeters, minD + 0.01)
        let inverseTransform = displayTransform.inverted()

        var pixels = [Float](repeating: 0, count: outWidth * outHeight)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            throw ExportError.invalidDepth
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        for y in 0..<outHeight {
            let viewY = (CGFloat(y) + 0.5) / CGFloat(outHeight)
            for x in 0..<outWidth {
                let viewX = (CGFloat(x) + 0.5) / CGFloat(outWidth)
                let imagePoint = CGPoint(x: viewX, y: viewY).applying(inverseTransform)

                guard imagePoint.x >= 0, imagePoint.x <= 1,
                      imagePoint.y >= 0, imagePoint.y <= 1 else {
                    continue
                }

                let depthX = Int((imagePoint.x * CGFloat(depthWidth)).rounded())
                let depthY = Int((imagePoint.y * CGFloat(depthHeight)).rounded())
                let sampleX = min(max(depthX, 0), depthWidth - 1)
                let sampleY = min(max(depthY, 0), depthHeight - 1)

                let row = baseAddress.advanced(by: sampleY * bytesPerRow)
                    .assumingMemoryBound(to: Float32.self)
                let depth = row[sampleX]

                guard depth.isFinite, depth >= minD, depth <= maxD else {
                    continue
                }

                pixels[y * outWidth + x] = depth
            }
        }

        try writeFloatGrayTIFF(pixels: &pixels, width: outWidth, height: outHeight, to: url)
    }

    private static func writeFloatGrayTIFF(
        pixels: inout [Float],
        width: Int,
        height: Int,
        to url: URL
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(.floatComponents)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 32,
            bytesPerRow: width * MemoryLayout<Float>.size,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ),
        let cgImage = context.makeImage() else {
            throw ExportError.writeFailed
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.writeFailed
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.writeFailed
        }
    }
}
