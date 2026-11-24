// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Versioned file format. LUT paths refer to user-selected local files.
struct PicturePreset: Codable {
    let version: Int
    let scale: Double
    let interpolate: Bool
    let multiplier: Int
    let cadence: Bool
    let hdr: Bool
    let denoise: Float
    let exposure: Float
    let saturation: Float
    let contrast: Float
    let sharpness: Float
    let fxaa: Bool
    let cube: URL?
    let graph: PictureGraph?
    let grade: ColourGrade?
    let additionalDenoise: [Float]?
    let denoiseProtection: [DenoiseRegion]?

    init(effects: Effects) {
        version = 1
        scale = effects.scale
        interpolate = effects.interpolate
        multiplier = effects.multiplier
        cadence = effects.capture60To30
        hdr = effects.preserveHDR
        denoise = effects.noiseReduction
        exposure = effects.exposure
        saturation = effects.saturation
        contrast = effects.contrast
        sharpness = effects.sharpness
        fxaa = effects.fxaa
        cube = effects.lookup?.url
        graph = effects.graph
        grade = effects.grade
        additionalDenoise = effects.additionalDenoise
        denoiseProtection = effects.denoiseProtection
    }

    func restore() throws -> Effects {
        let layers = additionalDenoise ?? []
        let regions = denoiseProtection ?? []
        guard version == 1, [1, 1.5, 2].contains(scale), Effects.multipliers.contains(multiplier),
              (0...1).contains(denoise), (-2...2).contains(exposure), (0...2).contains(saturation),
              (0.55...1.65).contains(contrast), (0...1.25).contains(sharpness),
              cube?.isFileURL ?? true,
              layers.count <= 3, layers.allSatisfy((0...1).contains),
              regions.count <= 8, regions.allSatisfy(\.isValid) else { throw MediaProblem("预设包含不受支持的值。") }
        _ = try graph?.compile()
        let grading = try grade?.validated() ?? .identity
        let lookup = try cube.map(CubeLookup.init(url:))
        return Effects(scale: scale, interpolate: interpolate, multiplier: multiplier, capture60To30: cadence,
                       preserveHDR: hdr, saturation: saturation, contrast: contrast, noiseReduction: denoise,
                       exposure: exposure, sharpness: sharpness, fxaa: fxaa, lookup: lookup, graph: graph, grade: grading,
                       additionalDenoise: layers, denoiseProtection: regions)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
