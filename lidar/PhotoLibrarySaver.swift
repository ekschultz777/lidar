//
//  PhotoLibrarySaver.swift
//  lidar
//
//  Created by Ted Schultz on 7/30/26.
//

import Photos
import UIKit

enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case permissionDenied
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Photo library access is required to save captures."
            case .saveFailed:
                return "Couldn't save the image to Photos."
            }
        }
    }

    static func save(_ image: UIImage) async throws {
        try await save([image])
    }

    static func save(_ images: [UIImage]) async throws {
        guard !images.isEmpty else { return }

        let status = await requestAddPermission()
        guard status == .authorized || status == .limited else {
            throw SaveError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                for image in images {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            }, completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? SaveError.saveFailed)
                }
            })
        }
    }

    private static func requestAddPermission() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current != .notDetermined {
            return current
        }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }
}
