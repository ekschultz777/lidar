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

    enum CaptureError: LocalizedError, Equatable {
        case snapshotFailed
        case noDepth
        case photoWriteFailed
        case tiffFailed
        case busy

        var errorDescription: String? {
            switch self {
            case .snapshotFailed:
                return "Couldn't capture the camera image."
            case .noDepth:
                return "No LiDAR depth available to export."
            case .photoWriteFailed:
                return "Couldn't encode the camera image."
            case .tiffFailed:
                return "Couldn't create the depth TIFF file."
            case .busy:
                return "A capture is already in progress."
            }
        }
    }

    struct CaptureExport {
        let basename: String
        let photo: UIImage
        let photoURL: URL
        let depthTIFFURL: URL
    }

    private var isCaptureInFlight = false

    /// Captures, saves to the camera roll, and builds a ZIP of JPEG + depth TIFF.
    func capturePersistAndZip() async throws -> CaptureZipResult {
        let export = try await captureAndPersist()
        let jpegData = try Data(contentsOf: export.photoURL)
        let tiffData = try Data(contentsOf: export.depthTIFFURL)
        let zipData = ZipWriter.makeArchive(entries: [
            .init(filename: "\(export.basename).jpg", data: jpegData),
            .init(filename: "\(export.basename).tiff", data: tiffData),
        ])
        return CaptureZipResult(
            zipData: zipData,
            zipFilename: "\(export.basename).zip"
        )
    }

    /// Captures and saves to the camera roll (photo required; TIFF best-effort).
    func captureAndPersist() async throws -> CaptureExport {
        guard !isCaptureInFlight else { throw CaptureError.busy }
        isCaptureInFlight = true
        defer { isCaptureInFlight = false }

        let export = try await captureExport()
        try await PhotoLibrarySaver.save(images: [export.photo])
        try? await PhotoLibrarySaver.save(fileURLs: [export.depthTIFFURL])
        return export
    }

    /// Captures a clean camera frame and a Float32 depth TIFF (meters; 0 outside Near/Far).
    func captureExport() async throws -> CaptureExport {
        let capturedAt = Date()
        let camera = try await snapshotCamera()
        guard let depthMap = latestDepthMap else { throw CaptureError.noDepth }
        guard let jpegData = camera.jpegData(compressionQuality: 0.95) else {
            throw CaptureError.photoWriteFailed
        }

        // Match the live view framing used for displayTransform (preserves aspect ratio).
        let outputSize = latestCaptureViewportSize.width > 1
            ? latestCaptureViewportSize
            : camera.size
        let transform = latestDisplayTransform
        let minMeters = minRangeMeters
        let maxMeters = maxRangeMeters

        let basename = Self.timestampString(from: capturedAt)
        let photoURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(basename).jpg")
        let tiffURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(basename).tiff")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) let depthBuffer = depthMap
            renderQueue.async {
                do {
                    if FileManager.default.fileExists(atPath: photoURL.path) {
                        try FileManager.default.removeItem(at: photoURL)
                    }
                    try jpegData.write(to: photoURL, options: .atomic)

                    try DepthTIFFExporter.write(
                        depthMap: depthBuffer,
                        minMeters: minMeters,
                        maxMeters: maxMeters,
                        outputSize: outputSize,
                        displayTransform: transform,
                        to: tiffURL
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        return CaptureExport(
            basename: basename,
            photo: camera,
            photoURL: photoURL,
            depthTIFFURL: tiffURL
        )
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

    /// Filename-safe capture time, including milliseconds for uniqueness.
    private static func timestampString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss.SSS"
        return formatter.string(from: date)
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
