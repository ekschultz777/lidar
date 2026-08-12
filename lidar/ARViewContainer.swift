//
//  ARViewContainer.swift
//  lidar
//
//  Created by Ted Schultz on 7/30/26.
//

import RealityKit
import SwiftUI

struct ARViewContainer: UIViewRepresentable {
    let session: LiDARDistanceSession

    func makeUIView(context: Context) -> ARView {
        let view = session.arView
        view.cameraMode = .ar
        view.automaticallyConfigureSession = false
        // Safe extras we never use — avoid options that can interfere with the camera feed.
        view.renderOptions.insert(.disablePersonOcclusion)
        view.renderOptions.insert(.disableDepthOfField)
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableGroundingShadows)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        session.syncViewMetrics()
    }
}
