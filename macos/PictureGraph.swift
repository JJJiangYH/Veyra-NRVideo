// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct PictureGraph: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case exposure, colour, lut, fxaa, sharpen

        var label: String {
            switch self {
            case .exposure: "曝光"
            case .colour: "调色"
            case .lut: "3D LUT"
            case .fxaa: "FXAA"
            case .sharpen: "锐化"
            }
        }
    }

    struct Node: Codable, Equatable {
        var id: UUID = UUID()
        var kind: Kind
        var strength: Float = 1
        var position: Position?
    }

    struct Position: Codable, Equatable {
        var x: Double
        var y: Double
    }

    var nodes: [Node]
    var links: [Link]

    struct Link: Codable, Equatable {
        var from: UUID
        var to: UUID
    }

    static let input = UUID(uuidString: "9FDA7948-5DF7-4194-92CC-40E6D6457611")!
    static let output = UUID(uuidString: "86140C55-BEE6-4F11-B6AE-2F28CA68AB92")!
    static let standard = linear(Kind.allCases.map { Node(kind: $0) })

    static func linear(_ nodes: [Node]) -> PictureGraph {
        let order = [input] + nodes.map(\.id) + [output]
        return PictureGraph(nodes: nodes, links: zip(order, order.dropFirst()).map { Link(from: $0, to: $1) })
    }

    mutating func connect(_ from: UUID, to: UUID) {
        guard from != to, from != Self.output, to != Self.input else { return }
        links.removeAll { $0.from == from || $0.to == to }
        links.append(Link(from: from, to: to))
    }

    mutating func remove(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        links.removeAll { $0.from == id || $0.to == id }
    }

    mutating func insert(_ id: UUID, after predecessor: UUID) {
        guard id != predecessor, let existing = links.first(where: { $0.from == predecessor }),
              existing.to != id, !links.contains(where: { $0.from == id || $0.to == id }) else { return }
        connect(predecessor, to: id)
        connect(id, to: existing.to)
    }

    func compile() throws -> [Node] {
        guard nodes.count <= 24, links.count <= 26,
              Set(nodes.map(\.id)).count == nodes.count,
              nodes.allSatisfy({ $0.id != Self.input && $0.id != Self.output && (0...2).contains($0.strength) }) else {
            throw MediaProblem("处理链节点过多、重复或包含无效强度。")
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let known = Set(nodesByID.keys).union([Self.input, Self.output])
        guard links.allSatisfy({ known.contains($0.from) && known.contains($0.to) &&
                               $0.from != Self.output && $0.to != Self.input }),
              Set(links.map(\.from)).count == links.count, Set(links.map(\.to)).count == links.count else {
            throw MediaProblem("处理链只接受一条从输入到输出的路径。")
        }
        let edges = Dictionary(uniqueKeysWithValues: links.map { ($0.from, $0.to) })
        var result: [Node] = []
        var visited: Set<UUID> = [Self.input]
        var cursor = Self.input
        while let next = edges[cursor] {
            if next == Self.output { return result }
            guard visited.insert(next).inserted, let node = nodesByID[next] else { break }
            result.append(node)
            cursor = next
        }
        throw MediaProblem("草稿未运行。请连接从输入到输出的完整路径。")
    }
}
