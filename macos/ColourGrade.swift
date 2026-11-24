// SPDX-License-Identifier: GPL-3.0-only
import CoreImage
import Foundation

/// Professional grading is applied inside every connected colour node.
struct ColourGrade: Codable, Equatable {
    var hue: Float = 0
    var temperature: Float = 0
    var tint: Float = 0
    var shadow: Float = 0.25
    var midpoint: Float = 0.5
    var highlight: Float = 0.75
    var matrix: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    var lift: [Float] = [0, 0, 0]
    var gamma: Float = 1

    static let identity = ColourGrade()

    func validated() throws -> ColourGrade {
        guard (-180...180).contains(hue), (-3000...3000).contains(temperature),
            (-100...100).contains(tint), (0...1).contains(shadow), (0...1).contains(midpoint),
            (0...1).contains(highlight), shadow <= midpoint, midpoint <= highlight,
            (0.3...3).contains(gamma), matrix.count == 9,
            matrix.allSatisfy({ (-2...2).contains($0) }), lift.count == 3,
            lift.allSatisfy({ (-0.5...0.5).contains($0) }) else {
            throw MediaProblem("高级调色数值无效。曲线控制点须从暗部到亮部依次递增。")
        }
        return self
    }

    func apply(to source: CIImage, strength: Float) -> CIImage {
        guard self != .identity, strength > 0 else { return source }
        var image = source
        if temperature != 0 || tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(6500 + temperature * strength), y: CGFloat(tint * strength))
            ])
        }
        if hue != 0 {
            image = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: hue * strength * .pi / 180])
        }
        if matrix != Self.identity.matrix || lift != Self.identity.lift {
            let m = zip(matrix, Self.identity.matrix).map { CGFloat($1 + ($0 - $1) * strength) }
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: 0),
                "inputGVector": CIVector(x: m[3], y: m[4], z: m[5], w: 0),
                "inputBVector": CIVector(x: m[6], y: m[7], z: m[8], w: 0),
                "inputBiasVector": CIVector(x: CGFloat(lift[0] * strength), y: CGFloat(lift[1] * strength),
                    z: CGFloat(lift[2] * strength), w: 0)
            ])
        }
        let blend = min(1, strength)
        if shadow != 0.25 || midpoint != 0.5 || highlight != 0.75 {
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: CGFloat(0.25 + (shadow - 0.25) * blend)),
                "inputPoint2": CIVector(x: 0.5, y: CGFloat(0.5 + (midpoint - 0.5) * blend)),
                "inputPoint3": CIVector(x: 0.75, y: CGFloat(0.75 + (highlight - 0.75) * blend)),
                "inputPoint4": CIVector(x: 1, y: 1)
            ])
        }
        if gamma != 1 {
            image = image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 + (gamma - 1) * blend])
        }
        return image
    }
}
