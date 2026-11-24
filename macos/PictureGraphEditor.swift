// SPDX-License-Identifier: GPL-3.0-only
import AppKit

final class PictureGraphEditor: NSView {
    private let canvas: PictureGraphCanvas
    private let nodeKind = NSPopUpButton()
    private let strength = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)
    private let remove = NSButton(title: "删除选中", target: nil, action: nil)
    private let duplicate = NSButton(title: "复制选中", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    var graph: PictureGraph { canvas.graph }
    var onValidityChanged: ((Bool) -> Void)?

    init(graph: PictureGraph) {
        canvas = PictureGraphCanvas(graph: graph)
        super.init(frame: NSRect(x: 0, y: 0, width: 720, height: 335))
        let additions = PictureGraph.Kind.allCases
        nodeKind.addItems(withTitles: additions.map(\.label))
        let add = NSButton(title: "添加节点", target: self, action: #selector(addNode))
        let arrange = NSButton(title: "自动排列", target: self, action: #selector(autoArrange))
        remove.target = self
        remove.action = #selector(removeSelected)
        duplicate.target = self
        duplicate.action = #selector(duplicateSelected)
        strength.target = self
        strength.action = #selector(setStrength)
        strength.setAccessibilityLabel("选中节点的强度")
        strength.widthAnchor.constraint(equalToConstant: 78).isActive = true

        let toolbar = NSStackView(views: [nodeKind, add, duplicate, remove, arrange,
                                          NSTextField(labelWithString: "强度"), strength])
        toolbar.spacing = 6
        let scroll = NSScrollView()
        scroll.documentView = canvas
        scroll.borderType = .bezelBorder
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.6
        scroll.maxMagnification = 1.8
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [toolbar, scroll, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        canvas.onChange = { [weak self] in self?.refreshControls() }
        refreshControls()
    }

    required init?(coder: NSCoder) { nil }

    func refreshControls() {
        let node = canvas.graph.nodes.first { $0.id == canvas.selection }
        let valid = (try? graph.compile()) != nil
        strength.isEnabled = node != nil
        remove.isEnabled = node != nil
        duplicate.isEnabled = node != nil && graph.nodes.count < 24
        if let node { strength.floatValue = node.strength }
        status.stringValue = valid ? "从节点右端拖到另一节点左端即可连接，按住 Option 拖动节点可断开。" :
            "草稿未运行。请连接从输入到输出的完整路径。"
        onValidityChanged?(valid)
    }

    @objc private func addNode() {
        guard PictureGraph.Kind.allCases.indices.contains(nodeKind.indexOfSelectedItem) else { return }
        canvas.add(PictureGraph.Node(kind: PictureGraph.Kind.allCases[nodeKind.indexOfSelectedItem]))
    }

    @objc private func removeSelected() { canvas.removeSelected() }
    @objc private func duplicateSelected() { canvas.duplicateSelected() }
    @objc private func autoArrange() { canvas.arrange() }
    @objc private func setStrength() { canvas.setStrength(strength.floatValue) }
}

private final class PictureGraphCanvas: NSView {
    var graph: PictureGraph
    private(set) var selection: UUID?
    var onChange: (() -> Void)?
    private var wireStart: UUID?
    private var wireCursor: NSPoint?
    private var dragging: (id: UUID, offset: NSPoint)?
    override var isFlipped: Bool { true }

    init(graph: PictureGraph) {
        self.graph = graph
        super.init(frame: NSRect(x: 0, y: 0, width: 1140, height: 530))
        setAccessibilityLabel("处理链节点画布")
        setAccessibilityHelp("选择节点后可用画布上方的按钮编辑。")
    }

    required init?(coder: NSCoder) { nil }

    private var ids: [UUID] { [PictureGraph.input] + graph.nodes.map(\.id) + [PictureGraph.output] }

    private func nodeRect(_ id: UUID) -> NSRect {
        if id == PictureGraph.input { return NSRect(x: 24, y: 132, width: 78, height: 42) }
        if id == PictureGraph.output { return NSRect(x: 613, y: 132, width: 78, height: 42) }
        guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return .zero }
        let node = graph.nodes[index]
        let point: PictureGraph.Position
        if let saved = node.position, saved.x.isFinite, saved.y.isFinite {
            point = PictureGraph.Position(x: min(max(saved.x, 14), frame.width - 120),
                                         y: min(max(saved.y, 16), frame.height - 60))
        } else {
            point = PictureGraph.Position(x: 130 + Double(index % 4) * 119,
                y: Double([60, 183, 112][index % 3]) + Double(index / 4) * 43)
        }
        return NSRect(x: point.x, y: point.y, width: 100, height: 42)
    }

    private func port(_ id: UUID, output: Bool) -> NSPoint {
        let rect = nodeRect(id)
        return NSPoint(x: output ? rect.maxX : rect.minX, y: rect.midY)
    }

    private func wire(_ from: NSPoint, _ to: NSPoint) -> NSBezierPath {
        let bend = max(26, abs(from.x - to.x) * 0.46)
        let path = NSBezierPath()
        path.move(to: from)
        path.curve(to: to, controlPoint1: NSPoint(x: from.x + bend, y: from.y),
                   controlPoint2: NSPoint(x: to.x - bend, y: to.y))
        path.lineWidth = 2.3
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        for link in graph.links {
            NSColor.controlAccentColor.withAlphaComponent(0.72).setStroke()
            wire(port(link.from, output: true), port(link.to, output: false)).stroke()
        }
        if let from = wireStart, let cursor = wireCursor {
            NSColor.controlAccentColor.setStroke()
            wire(port(from, output: true), cursor).stroke()
        }
        for id in ids {
            let rect = nodeRect(id)
            let node = graph.nodes.first { $0.id == id }
            let shape = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            NSColor.controlBackgroundColor.setFill()
            shape.fill()
            (selection == id ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            shape.lineWidth = selection == id ? 2 : 1
            shape.stroke()
            let title = node?.kind.label ?? (id == PictureGraph.input ? "输入" : "输出")
            title.draw(at: NSPoint(x: rect.minX + 12, y: rect.minY + (node == nil ? 12 : 5)),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
            if let node {
                String(format: "%.2f", node.strength).draw(at: NSPoint(x: rect.minX + 12, y: rect.minY + 22),
                    withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                     .foregroundColor: NSColor.secondaryLabelColor])
            }
            NSColor.controlAccentColor.setFill()
            for output in [false, true] where id != (output ? PictureGraph.output : PictureGraph.input) {
                let point = port(id, output: output)
                NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
            }
        }
    }

    private func hitPort(_ point: NSPoint, output: Bool) -> UUID? {
        ids.first { id in
            guard id != (output ? PictureGraph.output : PictureGraph.input) else { return false }
            let center = port(id, output: output)
            return hypot(point.x - center.x, point.y - center.y) <= 11
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let from = hitPort(point, output: true) {
            wireStart = from
            wireCursor = point
        } else if let from = wireStart, let to = hitPort(point, output: false) {
            graph.connect(from, to: to)
            wireStart = nil
            wireCursor = nil
        } else if let id = graph.nodes.map(\.id).reversed().first(where: { nodeRect($0).contains(point) }) {
            selection = id
            let origin = nodeRect(id).origin
            dragging = (id, NSPoint(x: point.x - origin.x, y: point.y - origin.y))
            wireStart = nil
            wireCursor = nil
        } else {
            selection = nil
            wireStart = nil
            wireCursor = nil
        }
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if wireStart != nil { wireCursor = point }
        if let drag = dragging, let index = graph.nodes.firstIndex(where: { $0.id == drag.id }) {
            graph.nodes[index].position = .init(x: min(max(point.x - drag.offset.x, 14), frame.width - 120),
                                                y: min(max(point.y - drag.offset.y, 16), frame.height - 60))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let from = wireStart, let to = hitPort(point, output: false), from != to {
            graph.connect(from, to: to)
            wireStart = nil
            wireCursor = nil
        }
        if let id = dragging?.id {
            if event.modifierFlags.contains(.option) {
                graph.links.removeAll { $0.from == id || $0.to == id }
            } else if let edge = graph.links.first(where: { edge in
                let path = wire(port(edge.from, output: true), port(edge.to, output: false))
                return path.cgPath.copy(strokingWithWidth: 14, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(point)
            }) {
                graph.insert(id, after: edge.from)
            }
        }
        dragging = nil
        refresh()
    }

    func add(_ node: PictureGraph.Node) {
        guard graph.nodes.count < 24 else { return }
        graph.nodes.append(node)
        selection = node.id
        refresh()
    }

    func duplicateSelected() {
        guard let selection, let node = graph.nodes.first(where: { $0.id == selection }) else { return }
        add(PictureGraph.Node(kind: node.kind, strength: node.strength))
    }

    func removeSelected() {
        guard let selection else { return }
        graph.remove(selection)
        self.selection = nil
        refresh()
    }

    func setStrength(_ value: Float) {
        guard let selection, let index = graph.nodes.firstIndex(where: { $0.id == selection }) else { return }
        graph.nodes[index].strength = value
        needsDisplay = true
    }

    func arrange() {
        let running = (try? graph.compile()) ?? []
        let ids = Set(running.map(\.id))
        graph.nodes = running + graph.nodes.filter { !ids.contains($0.id) }
        for index in graph.nodes.indices { graph.nodes[index].position = nil }
        refresh()
    }

    private func refresh() {
        needsDisplay = true
        onChange?()
    }
}
