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

    /// Farthest distance included in the label grid, in meters.
    @Published var maxRangeMeters: Float = 2.0

    let arView = ARView(frame: .zero)

    private var isRenderingOverlay = false
    private var frameCounter = 0
    private let renderQueue = DispatchQueue(label: "com.TedSchultz.lidar.grid", qos: .userInitiated)

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
        case composeFailed

        var errorDescription: String? {
            switch self {
            case .snapshotFailed:
                return "Couldn't capture the camera image."
            case .composeFailed:
                return "Couldn't compose the distance overlay image."
            }
        }
    }

    struct CapturePair {
        let plain: UIImage
        let annotated: UIImage
    }

    /// Captures a clean camera frame and a second frame with distance numbers.
    func captureImages() async throws -> CapturePair {
        let camera = try await snapshotCamera()
        guard let annotated = CaptureComposer.compose(
            camera: camera,
            overlay: overlayImage
        ) else {
            throw CaptureError.composeFailed
        }
        return CapturePair(plain: camera, annotated: annotated)
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

    fileprivate func handleDepthFrame(
        _ depthMap: CVPixelBuffer,
        displayTransform: CGAffineTransform,
        viewportSize: CGSize
    ) {
        status = .tracking
        frameCounter += 1
        guard !isRenderingOverlay, frameCounter % 2 == 0 else { return }
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }

        isRenderingOverlay = true
        nonisolated(unsafe) let depthBuffer = depthMap
        let transform = displayTransform
        let size = viewportSize
        let maxMeters = maxRangeMeters

        renderQueue.async { [weak self] in
            let image = DistanceGridRenderer.makeImage(
                from: depthBuffer,
                viewportSize: size,
                displayTransform: transform,
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
