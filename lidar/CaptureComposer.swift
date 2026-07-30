//
//  CaptureComposer.swift
//  lidar
//
//  Created by Ted Schultz on 7/30/26.
//

import UIKit

enum CaptureComposer {
    static func compose(
        camera: UIImage,
        overlay: UIImage?
    ) -> UIImage? {
        let size = camera.size
        guard size.width > 0, size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = camera.scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            let bounds = CGRect(origin: .zero, size: size)
            camera.draw(in: bounds)

            if let overlay {
                overlay.draw(in: bounds)
            }
        }
    }
}
