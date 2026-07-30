//
//  DistanceFormatting.swift
//  lidar
//
//  Created by Ted Schultz on 7/30/26.
//

import Foundation

enum DistanceFormatting {
    static func millimeters(_ meters: Float) -> String {
        "\(Int((meters * 1000).rounded())) mm"
    }
}
