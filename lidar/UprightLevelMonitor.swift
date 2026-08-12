//
//  UprightLevelMonitor.swift
//  lidar
//
//  Created by Ted Schultz on 7/30/26.
//

import Combine
import CoreMotion
import Foundation

/// Tracks how close the device is to being held perfectly upright (portrait, plumb).
@MainActor
final class UprightLevelMonitor: ObservableObject {
    /// True only when tilt from vertical is within the near-zero threshold.
    @Published private(set) var isUpright = false
    /// Degrees away from perfectly upright (0 = perfect).
    @Published private(set) var tiltDegrees: Double = 180
    /// Bubble offset in normalized -1...1 space for a simple level UI (x = roll, y = pitch).
    @Published private(set) var bubbleOffset: SIMD2<Double> = .zero

    /// Only green when essentially plumb. Sensor noise after filtering makes ~0.05° practical.
    private let greenThresholdDegrees: Double = 0.05
    /// Must stay inside the threshold this long before going green (rejects brief noise spikes).
    private let holdDuration: TimeInterval = 0.25

    private let motionManager = CMMotionManager()
    /// 20 Hz is plenty for a level bubble and avoids thrashing SwiftUI.
    private let updateInterval = 1.0 / 20.0

    /// Low-pass filtered gravity for a stable plumb reading.
    private var filteredGravity: SIMD3<Double>?
    private let filterAlpha = 0.18
    private var uprightSince: Date?

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = updateInterval
        // Attitude reference keeps gravity estimates stable for leveling.
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.update(with: motion.gravity)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        filteredGravity = nil
        uprightSince = nil
        isUpright = false
    }

    private func update(with gravity: CMAcceleration) {
        // Core Motion: +X right, +Y top of device, +Z out of screen.
        // Upright portrait: gravity ≈ (0, -1, 0).
        let sample = SIMD3(gravity.x, gravity.y, gravity.z)
        let filtered: SIMD3<Double>
        if let previous = filteredGravity {
            filtered = previous + filterAlpha * (sample - previous)
            filteredGravity = filtered
        } else {
            filtered = sample
            filteredGravity = sample
        }

        let gx = filtered.x
        let gy = filtered.y
        let gz = filtered.z

        // atan2 is more accurate near vertical than acos for small angles.
        let horizontal = sqrt(gx * gx + gz * gz)
        let tilt = abs(atan2(horizontal, -gy)) * 180 / .pi
        let rollDegrees = abs(atan2(gx, -gy)) * 180 / .pi
        let pitchDegrees = abs(atan2(gz, -gy)) * 180 / .pi

        // Bubble: highly sensitive so tiny tilts are visible.
        let scale = 40.0
        let offset = SIMD2(
            max(-1, min(1, gx * scale)),
            max(-1, min(1, gz * scale))
        )

        let withinTolerance =
            tilt <= greenThresholdDegrees
            && rollDegrees <= greenThresholdDegrees
            && pitchDegrees <= greenThresholdDegrees
            && gy < -0.999

        let now = Date()
        let nextUpright: Bool
        if withinTolerance {
            if uprightSince == nil {
                uprightSince = now
            }
            if let start = uprightSince, now.timeIntervalSince(start) >= holdDuration {
                nextUpright = true
            } else {
                nextUpright = false
            }
        } else {
            uprightSince = nil
            nextUpright = false
        }

        // Skip @Published writes that wouldn't change the UI.
        if abs(tilt - tiltDegrees) >= 0.01 {
            tiltDegrees = tilt
        }
        if abs(offset.x - bubbleOffset.x) >= 0.01 || abs(offset.y - bubbleOffset.y) >= 0.01 {
            bubbleOffset = offset
        }
        if nextUpright != isUpright {
            isUpright = nextUpright
        }
    }
}
