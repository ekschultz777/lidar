//
//  LiDARDistanceSession.swift
//  lidar
//
//  Created by Ted Schultz on 7/30/26.
//

import ARKit
import Combine
import Foundation
import RealityKit
import UIKit

@MainActor
final class LiDARDistanceSession: NSObject, ObservableObject {
    enum Status: Equatable {
        case starting
        case unsupported
        case tracking
        case noDepth
    }

    @Published private(set) var overlayImage: UIImage?
    @Published private(set) var status: Status = .starting

    /// Closest distance included in the label grid / TIFF, in meters.
    @Published var minRangeMeters: Float = 0.25

    /// Farthest distance included in the label grid / TIFF, in meters.
    @Published var maxRangeMeters: Float = 2.0

    func setMinRange(_ value: Float) {
        minRangeMeters = min(max(value, 0.05), maxRangeMeters - 0.05)
    }

    func setMaxRange(_ value: Float) {
        maxRangeMeters = max(min(value, 5.0), minRangeMeters + 0.05)
    }

    let arView = ARView(frame: .zero)

    private var isRenderingOverlay = false
    private var frameCounter = 0
    private let renderQueue = DispatchQueue(label: "com.TedSchultz.lidar.grid", qos: .userInitiated)

    /// Latest depth frame kept for TIFF export.
    private var latestDepthMap: CVPixelBuffer?
    private var latestDisplayTransform: CGAffineTransform = .identity
    private var latestCaptureViewportSize: CGSize = .zero

    /// Updated from the AR callback so we can map depth → screen without hopping threads first.
    nonisolated(unsafe) private var latestViewportSize: CGSize = .zero
    nonisolated(unsafe) private var latestInterfaceOrientation: UIInterfaceOrientation = .portrait

    var supportsLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    func start() {
        guard supportsLiDAR else {
            status = .unsupported
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = [.sceneDepth]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        configuration.environmentTexturing = .automatic

        arView.session.delegate = self
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        status = .tracking
        syncViewMetrics()
    }

    func stop() {
        arView.session.pause()
    }

    func syncViewMetrics() {
        let size = arView.bounds.size
        if size.width > 1, size.height > 1 {
            latestViewportSize = size
        }
        if let orientation = arView.window?.windowScene?.interfaceOrientation {
            latestInterfaceOrientation = orientation
        }
    }

    enum CaptureError: LocalizedError {
        case snapshotFailed
        case noDepth
        case tiffFailed

        var errorDescription: String? {
            switch self {
            case .snapshotFailed:
                return "Couldn't capture the camera image."
            case .noDepth:
                return "No LiDAR depth available to export."
            case .tiffFailed:
                return "Couldn't create the depth TIFF file."
            }
        }
    }

    struct CaptureExport {
        let photo: UIImage
        let depthTIFFURL: URL
    }

    /// Captures a clean camera frame and a Float32 depth TIFF (meters; 0 outside Near/Far).
    func captureExport() async throws -> CaptureExport {
        let camera = try await snapshotCamera()
        guard let depthMap = latestDepthMap else { throw CaptureError.noDepth }

        // Match the live view framing used for displayTransform (preserves aspect ratio).
        let outputSize = latestCaptureViewportSize.width > 1
            ? latestCaptureViewportSize
            : camera.size
        let transform = latestDisplayTransform
        let minMeters = minRangeMeters
        let maxMeters = maxRangeMeters

        let filename = "depth_\(Self.timestampString()).tiff"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) let depthBuffer = depthMap
            renderQueue.async {
                do {
                    try DepthTIFFExporter.write(
                        depthMap: depthBuffer,
                        minMeters: minMeters,
                        maxMeters: maxMeters,
                        outputSize: outputSize,
                        displayTransform: transform,
                        to: url
                    )
                    // Also keep a copy in Documents for Files app access.
                    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                    if let documents {
                        let docsURL = documents.appendingPathComponent(filename)
                        try? FileManager.default.removeItem(at: docsURL)
                        try? FileManager.default.copyItem(at: url, to: docsURL)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        return CaptureExport(photo: camera, depthTIFFURL: url)
    }

    private func snapshotCamera() async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            arView.snapshot(saveToHDR: false) { image in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CaptureError.snapshotFailed)
                }
            }
        }
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    fileprivate func handleDepthFrame(
        _ depthMap: CVPixelBuffer,
        displayTransform: CGAffineTransform,
        viewportSize: CGSize
    ) {
        status = .tracking
        latestDepthMap = depthMap
        latestDisplayTransform = displayTransform
        latestCaptureViewportSize = viewportSize

        frameCounter += 1
        guard !isRenderingOverlay, frameCounter % 2 == 0 else { return }
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }

        isRenderingOverlay = true
        nonisolated(unsafe) let depthBuffer = depthMap
        let transform = displayTransform
        let size = viewportSize
        let minMeters = minRangeMeters
        let maxMeters = maxRangeMeters

        renderQueue.async { [weak self] in
            let image = DepthRangeOverlayRenderer.makeImage(
                from: depthBuffer,
                viewportSize: size,
                displayTransform: transform,
                minMeters: minMeters,
                maxMeters: maxMeters
            )

            Task { @MainActor in
                guard let self else { return }
                self.overlayImage = image
                self.isRenderingOverlay = false
            }
        }
    }

    fileprivate func markNoDepth() {
        status = .noDepth
    }

    nonisolated static func copyDepthBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var copy: CVPixelBuffer?
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            CVPixelBufferGetPixelFormatType(source),
            nil,
            &copy
        )
        guard status == kCVReturnSuccess, let destination = copy else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }

        guard
            let src = CVPixelBufferGetBaseAddress(source),
            let dst = CVPixelBufferGetBaseAddress(destination)
        else {
            return nil
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
        let rowBytes = min(srcBytesPerRow, dstBytesPerRow)

        for row in 0..<height {
            memcpy(dst.advanced(by: row * dstBytesPerRow), src.advanced(by: row * srcBytesPerRow), rowBytes)
        }

        return destination
    }
}

extension LiDARDistanceSession: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let depthMap = frame.sceneDepth?.depthMap else {
            Task { @MainActor in
                self.markNoDepth()
            }
            return
        }

        guard let copied = Self.copyDepthBuffer(depthMap) else { return }

        let viewportSize = latestViewportSize
        let orientation = latestInterfaceOrientation
        let displayTransform: CGAffineTransform
        if viewportSize.width > 1, viewportSize.height > 1 {
            displayTransform = frame.displayTransform(for: orientation, viewportSize: viewportSize)
        } else {
            displayTransform = .identity
        }

        Task { @MainActor in
            self.syncViewMetrics()
            self.handleDepthFrame(
                copied,
                displayTransform: displayTransform,
                viewportSize: viewportSize.width > 1 ? viewportSize : self.arView.bounds.size
            )
        }
    }
}
