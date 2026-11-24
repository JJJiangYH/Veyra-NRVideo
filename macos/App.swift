// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import AVFoundation
import ScreenCaptureKit
import Speech
import Translation
import UniformTypeIdentifiers

final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 690),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    let sourceMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    let surface = VideoSurface(frame: .zero)
    let welcome = NSButton(title: "打开或拖入视频、图片", target: nil, action: nil)
    let filename = NSTextField(labelWithString: "请选择本地媒体")
    let formatLabel = NSTextField(labelWithString: "")
    let details = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "")
    let time = NSTextField(labelWithString: "00:00 / 00:00")
    let seek = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let volume = NSSlider(value: 0.65, minValue: 0, maxValue: 1, target: nil, action: nil)
    let audioTrack = NSPopUpButton()
    let subtitleSelector = NSPopUpButton()
    let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    let playlistControl = NSPopUpButton()
    let speed = NSPopUpButton()
    let playButton = NSButton(title: "播放", target: nil, action: nil)
    let scale = NSPopUpButton()
    let interpolate = NSButton(checkboxWithTitle: "启用补帧", target: nil, action: nil)
    let multiplier = NSPopUpButton()
    let cadence = NSButton(checkboxWithTitle: "60→30 源帧重采样", target: nil, action: nil)
    let hdrOutput = NSButton(checkboxWithTitle: "保留源 HDR（播放与导出）", target: nil, action: nil)
    let antiAlias = NSButton(checkboxWithTitle: "FXAA 抗锯齿", target: nil, action: nil)
    let comparison = NSButton(checkboxWithTitle: "查看原画", target: nil, action: nil)
    let noiseReduction = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let exposure = NSSlider(value: 0, minValue: -2, maxValue: 2, target: nil, action: nil)
    let saturation = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)
    let contrast = NSSlider(value: 1, minValue: 0.55, maxValue: 1.65, target: nil, action: nil)
    let sharpness = NSSlider(value: 0, minValue: 0, maxValue: 1.25, target: nil, action: nil)
    let lutName = NSTextField(labelWithString: "未加载")
    let export = NSButton(title: "导出视频…", target: nil, action: nil)
    let exportQueue = NSPopUpButton(frame: .zero, pullsDown: true)
    let recordButton = NSButton(title: "录制…", target: nil, action: nil)
    let cancel = NSButton(title: "取消导出", target: nil, action: nil)
    let progress = NSProgressIndicator()
    private var effectControls: [NSControl] = []
    private var active: Preview?
    private var capture: CapturePreview?
    private var pcForm: PCConnectionForm?
    private var pendingXbox: VeyraXboxStream?
    private var captureRecording = false
    private var captureHasAudio = false
    private var obsOutput: VeyraOBSOutput?
    private var captureIsNetwork = false
    private var replayEnabled = false
    private var media: MediaFile?
    private var still: StillImage?
    private var stillOutput: CGImage?
    private let stillQueue = DispatchQueue(label: "io.veyra.image", qos: .userInitiated)
    private var stillWork: DispatchWorkItem?
    private var stillRequest = UUID()
    private var effect = Effects()
    private var loadRequest = UUID()
    private var wantsPlayback = false
    private var ready = false
    private var currentExport: VideoExport?
    private struct ExportRequest {
        let media: MediaFile
        let settings: Effects
        let range: CMTimeRange
        let destination: URL
    }
    private var pendingExports: [ExportRequest] = []
    private var failedExport: ExportRequest?
    private var clock: Timer?
    private var inputLUT: CubeLookup?
    private var pictureGraph: PictureGraph?
    private var colourGrade = ColourGrade.identity
    private var additionalDenoise: [Float] = []
    private var denoiseProtection: [DenoiseRegion] = []
    private var lastLoadedPreset: URL?
    private var playlist: [URL] = []
    private var subtitle: SubtitleTrack?
    private var captionMode: (source: String, target: String?)?
    private var captions: LiveCaptions?
    private var translatedCaption = ""
    private var captionTask: Task<Void, Never>?
    private var lastCaptionSubmit = Date.distantPast
    private var subtitleRequest = UUID()

    private final class PCConnectionForm {
        let host = NSTextField(string: "")
        let applications = NSPopUpButton()
        let status = NSTextField(wrappingLabelWithString: "")
        let start: NSButton
        var stream: VeyraPCStream?
        var entries: [VeyraPCApp] = []

        init(start: NSButton) { self.start = start }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureUI()
        configureMenu()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refreshPosition() }
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if !paths.isEmpty { openPlaylist(paths.map { URL(fileURLWithPath: $0) }) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !urls.isEmpty { openPlaylist(urls) }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard effect.interpolate, comparison.state == .off, let active else { return }
        restart(at: active.time)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        clock?.invalidate()
        active?.stop()
        capture?.stop()
        stillWork?.cancel()
        pcForm?.stream?.stop()
        pendingXbox?.stop()
        captions?.stop()
        captionTask?.cancel()
        currentExport?.cancel()
    }

    private func configureUI() {
        window.title = "Veyra"
        window.minSize = NSSize(width: 840, height: 520)
        window.delegate = self
        window.setFrameAutosaveName("VeyraMacWindow")

        filename.font = .systemFont(ofSize: 16, weight: .semibold)
        filename.lineBreakMode = .byTruncatingMiddle
        formatLabel.font = .systemFont(ofSize: 11)
        formatLabel.textColor = .secondaryLabelColor
        bind(recordButton, #selector(toggleCaptureRecording))
        exportQueue.addItem(withTitle: "导出队列")
        let retry = NSMenuItem(title: "重试上次失败任务", action: #selector(retryExport), keyEquivalent: "")
        retry.target = self
        exportQueue.menu?.addItem(retry)
        let clear = NSMenuItem(title: "清空等待任务", action: #selector(clearExports), keyEquivalent: "")
        clear.target = self
        exportQueue.menu?.addItem(clear)
        let exportActions = horizontal([export, exportQueue, cancel, recordButton], spacing: 7)
        playlistControl.addItem(withTitle: "播放列表")
        playlistControl.setAccessibilityLabel("播放列表")
        playlistControl.widthAnchor.constraint(lessThanOrEqualToConstant: 184).isActive = true
        bind(playlistControl, #selector(selectPlaylistItem))
        sourceMenu.addItem(withTitle: "采集")
        for (title, action) in [("打开网络地址…", #selector(pickNetwork)),
                                ("回看 15 秒", #selector(shiftNetworkBack)),
                                ("回到直播", #selector(returnToLive)),
                                ("屏幕或窗口…", #selector(pickScreen)),
                                ("采集卡或摄像机…", #selector(pickDevice)),
                                ("开关 OBS 处理画面输出", #selector(toggleOBS)),
                                ("开关即时回放", #selector(toggleReplay)),
                                ("保存最近 15 秒…", #selector(saveReplay)),
                                ("停止采集", #selector(stopCapture))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            sourceMenu.menu?.addItem(item)
        }
        if VeyraPCStream.available {
            let item = NSMenuItem(title: "PC 串流…", action: #selector(pickPC), keyEquivalent: "")
            item.target = self
            sourceMenu.menu?.insertItem(item, at: 2)
        }
        if VeyraPS5Stream.available {
            let item = NSMenuItem(title: "PS5 局域网串流…", action: #selector(pickPS5), keyEquivalent: "")
            item.target = self
            sourceMenu.menu?.insertItem(item, at: VeyraPCStream.available ? 3 : 2)
        }
        if VeyraXboxStream.available {
            let item = NSMenuItem(title: "Xbox 串流…", action: #selector(pickXbox), keyEquivalent: "")
            item.target = self
            sourceMenu.menu?.insertItem(item, at: 2 + (VeyraPCStream.available ? 1 : 0) + (VeyraPS5Stream.available ? 1 : 0))
        }
        let header = horizontal([button("打开媒体…", #selector(pickFile)), sourceMenu,
                                 vertical([filename, formatLabel], spacing: 3),
                                 spacer(), playlistControl, exportActions], spacing: 12)
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        surface.receiveFile = { [weak self] in self?.openPlaylist([$0]) }
        surface.activatePlayback = { [weak self] in self?.togglePlay() }
        bind(welcome, #selector(pickFile))
        welcome.bezelStyle = .inline
        welcome.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(welcome)
        subtitleLabel.font = .systemFont(ofSize: 18, weight: .medium)
        subtitleLabel.textColor = .white
        subtitleLabel.alignment = .center
        subtitleLabel.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        subtitleLabel.drawsBackground = true
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.isHidden = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            subtitleLabel.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -24),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: surface.widthAnchor, multiplier: 0.88)
        ])
        NSLayoutConstraint.activate([
            welcome.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            welcome.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
        ])

        scale.addItems(withTitles: ["原始尺寸", "1.5×", "2×"])
        bind(scale, #selector(changeEffects))
        bind(interpolate, #selector(changeEffects))
        multiplier.addItems(withTitles: Effects.multipliers.map { "\($0)×" })
        multiplier.setAccessibilityLabel("补帧倍率")
        bind(multiplier, #selector(changeEffects))
        bind(cadence, #selector(changeEffects))
        bind(hdrOutput, #selector(changeEffects))
        hdrOutput.state = .on
        bind(antiAlias, #selector(changeEffects))
        cadence.toolTip = "60 fps 左右的素材可先按时间戳重采样到约 30 fps，再选择补帧。"
        bind(comparison, #selector(changeEffects))
        scale.setAccessibilityLabel("MetalFX 超分倍率")
        for (slider, name) in [(noiseReduction, "时域降噪"), (exposure, "曝光"), (saturation, "饱和度"), (contrast, "对比度"), (sharpness, "锐化")] {
            bind(slider, #selector(changeEffects))
            slider.setAccessibilityLabel(name)
            slider.isContinuous = false
        }
        lutName.font = .systemFont(ofSize: 11)
        lutName.textColor = .secondaryLabelColor
        lutName.lineBreakMode = .byTruncatingMiddle
        let chooseLUT = button("加载 LUT…", #selector(pickLUT))
        let removeLUT = button("移除", #selector(clearLUT))
        let reset = button("重置效果", #selector(resetEffects))
        effectControls = [scale, interpolate, multiplier, cadence, hdrOutput, comparison, noiseReduction, exposure, saturation, contrast, sharpness, antiAlias, chooseLUT, removeLUT, reset]

        let controls = vertical([
            heading("画质"), labeled("MetalFX 超分", scale),
            horizontal([interpolate, multiplier], spacing: 5), cadence, hdrOutput, comparison, NSBox.separator(),
            labeled("时域降噪", noiseReduction), labeled("曝光", exposure),
            labeled("饱和度", saturation), labeled("对比度", contrast), labeled("锐化", sharpness), antiAlias,
            NSBox.separator(), labeled("3D LUT", horizontal([chooseLUT, removeLUT], spacing: 6)),
            lutName, reset, spacer()
        ], spacing: 11, insets: NSEdgeInsets(top: 16, left: 15, bottom: 12, right: 15))
        controls.translatesAutoresizingMaskIntoConstraints = false
        let controlScroller = NSScrollView()
        controlScroller.drawsBackground = false
        controlScroller.hasVerticalScroller = true
        controlScroller.autohidesScrollers = true
        controlScroller.documentView = controls
        controls.widthAnchor.constraint(equalTo: controlScroller.contentView.widthAnchor).isActive = true
        controlScroller.widthAnchor.constraint(equalToConstant: 214).isActive = true
        controlScroller.setContentHuggingPriority(.defaultLow, for: .vertical)

        bind(playButton, #selector(togglePlay))
        bind(seek, #selector(seekChanged))
        seek.isContinuous = false
        seek.setAccessibilityLabel("播放进度")
        speed.addItems(withTitles: ["1×", "1.5×", "2×", "3×"])
        speed.setAccessibilityLabel("播放速度")
        bind(speed, #selector(changePlaybackSpeed))
        bind(audioTrack, #selector(changeAudioTrack))
        audioTrack.addItem(withTitle: "音轨")
        audioTrack.setAccessibilityLabel("播放音轨")
        subtitleSelector.addItem(withTitle: "关闭字幕")
        subtitleSelector.setAccessibilityLabel("播放字幕")
        bind(subtitleSelector, #selector(selectSubtitle))
        bind(volume, #selector(volumeChanged))
        volume.isContinuous = true
        volume.setAccessibilityLabel("音量")
        volume.widthAnchor.constraint(equalToConstant: 82).isActive = true
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        time.setContentHuggingPriority(.required, for: .horizontal)
        seek.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = horizontal([playButton, seek, time, button("全屏", #selector(fullscreen)),
                                 button("截图…", #selector(saveScreenshot)), speed, audioTrack, subtitleSelector, volume], spacing: 9)

        details.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        details.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setAccessibilityLabel("处理状态")
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.widthAnchor.constraint(equalToConstant: 110).isActive = true
        progress.isHidden = true
        bind(export, #selector(pickExport))
        bind(cancel, #selector(cancelExport))
        cancel.isHidden = true
        let bottom = horizontal([status, progress, spacer(), details], spacing: 9)

        let mediaRow = horizontal([surface, controlScroller], spacing: 0)
        controlScroller.topAnchor.constraint(equalTo: mediaRow.topAnchor).isActive = true
        controlScroller.bottomAnchor.constraint(equalTo: mediaRow.bottomAnchor).isActive = true
        mediaRow.distribution = .fill
        surface.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let content = vertical([header, mediaRow, footer, bottom], spacing: 8,
                               insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
        mediaRow.setContentHuggingPriority(.defaultLow, for: .vertical)
        surface.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = content
        updateEnabledControls()
    }

    private func configureMenu() {
        let mainMenu = NSMenu()
        let app = NSMenuItem()
        mainMenu.addItem(app)
        let appMenu = NSMenu()
        app.submenu = appMenu
        appMenu.addItem(withTitle: "退出 Veyra", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem()
        mainMenu.addItem(file)
        let fileMenu = NSMenu(title: "文件")
        file.submenu = fileMenu
        for (title, action, key) in [("打开媒体…", #selector(pickFile), "o"),
                                      ("导出视频…", #selector(pickExport), "e"),
                                      ("保存性能记录…", #selector(savePerformance), ""),
                                      ("保存画质预设…", #selector(savePreset), ""),
                                      ("打开画质预设…", #selector(openPreset), ""),
                                      ("实时字幕与翻译…", #selector(pickCaptionMode), ""),
                                      ("编辑处理链…", #selector(editGraph), ""),
                                      ("降噪叠层…", #selector(editDenoiseLayers), ""),
                                      ("降噪保护区域…", #selector(editDenoiseProtection), ""),
                                      ("高级调色…", #selector(editColourGrade), "")] {
            let item = fileMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        let video = NSMenuItem()
        mainMenu.addItem(video)
        let videoMenu = NSMenu(title: "播放")
        video.submenu = videoMenu
        let play = videoMenu.addItem(withTitle: "播放或暂停", action: #selector(togglePlay), keyEquivalent: " ")
        play.target = self
        play.keyEquivalentModifierMask = []
        NSApp.mainMenu = mainMenu
    }

    private func updateEnabledControls() {
        let loaded = media != nil
        let loadedOrLive = loaded || capture != nil
        let hasPicture = loadedOrLive || still != nil
        for control in effectControls { control.isEnabled = hasPicture }
        scale.isEnabled = hasPicture && VideoRenderer.canUpscale
        interpolate.isEnabled = capture != nil ? VeyraInterpolation.isSupported : media.map(VideoFrames.canInterpolate) ?? false
        interpolate.toolTip = loaded && !interpolate.isEnabled ? "这台 Mac 或当前视频尺寸不支持补帧。" : nil
        multiplier.isEnabled = interpolate.isEnabled && interpolate.state == .on
        hdrOutput.isEnabled = media?.hdr ?? false
        noiseReduction.isEnabled = loadedOrLive && VeyraDenoiser.isSupported
        cadence.isEnabled = capture != nil || (media.map { (55...65).contains($0.frameRate) } ?? false)
        comparison.isEnabled = hasPicture
        audioTrack.isEnabled = (media?.audioTracks.count ?? 0) > 1
        subtitleSelector.isEnabled = loaded
        playButton.isEnabled = loadedOrLive
        speed.isEnabled = loaded
        playlistControl.isHidden = playlist.count < 2 || capture != nil
        seek.isEnabled = loaded
        export.isEnabled = loaded
        export.title = currentExport == nil ? "导出视频…" : "加入导出…"
        exportQueue.setTitle("导出队列" + (pendingExports.isEmpty ? "" : " (\(pendingExports.count))"))
        exportQueue.isHidden = currentExport == nil && pendingExports.isEmpty && failedExport == nil
        export.isHidden = capture != nil || still != nil
        recordButton.isHidden = capture == nil || captureIsNetwork
        recordButton.title = captureRecording ? "停止录制" : "录制…"
    }

    @objc private func pickNetwork() {
        let address = NSTextField(string: "")
        address.placeholderString = "https://…、udp://… 或 rtp://…"
        let history = NSPopUpButton()
        history.addItems(withTitles: ["1 分钟", "2 分钟", "5 分钟"])
        let inputs = vertical([address, labeled("RTP/UDP 时移", history)], spacing: 8)
        inputs.frame = NSRect(x: 0, y: 0, width: 440, height: 72)
        let alert = NSAlert()
        alert.messageText = "打开网络地址"
        alert.accessoryView = inputs
        alert.addButton(withTitle: "打开")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = address
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let text = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "rtp", "udp"].contains(scheme), url.host != nil else {
                self.status.stringValue = "请输入有效的 HTTP、HTTPS、RTP 或 UDP 地址。"
                return
            }
            let preview = self.beginCapture(url.host ?? "网络流", hasAudio: false, network: true)
            Task { @MainActor [weak self, weak preview] in
                guard let self, let preview else { return }
                do {
                    try await preview.startNetwork(url, historyMinutes: [1, 2, 5][max(0, history.indexOfSelectedItem)])
                } catch {
                    if self.capture === preview { self.failCapture(error.localizedDescription) }
                }
            }
        }
    }

    @objc private func shiftNetworkBack() { if captureIsNetwork { capture?.shiftNetwork(seconds: -15) } }
    @objc private func returnToLive() { if captureIsNetwork { capture?.shiftNetwork(seconds: nil) } }

    @objc private func pickPC() {
        guard pcForm == nil else { return }
        let alert = NSAlert()
        alert.messageText = "连接 Sunshine 主机"
        let form = PCConnectionForm(start: alert.addButton(withTitle: "开始串流"))
        pcForm = form
        form.start.isEnabled = false
        alert.addButton(withTitle: "取消")
        form.host.placeholderString = "主机名或 IP，可附带端口"
        form.host.target = self
        form.host.action = #selector(pairPC)
        form.applications.isEnabled = false
        let connect = button("配对并获取游戏列表", #selector(pairPC))
        let inputs = vertical([labeled("主机", form.host), connect,
                               labeled("游戏", form.applications), form.status], spacing: 8)
        inputs.frame = NSRect(x: 0, y: 0, width: 430, height: 112)
        alert.accessoryView = inputs
        alert.window.initialFirstResponder = form.host
        alert.beginSheetModal(for: window) { [weak self, form] response in
            guard let self, self.pcForm === form else { return }
            self.pcForm = nil
            let index = form.applications.indexOfSelectedItem
            guard response == .alertFirstButtonReturn, let stream = form.stream,
                  form.entries.indices.contains(index) else {
                form.stream?.stop()
                return
            }
            let app = form.entries[index]
            let preview = self.beginCapture(app.name, hasAudio: true)
            self.formatLabel.stringValue = "PC 串流 · 1080p60 SDR"
            preview.startRemote(stream, window: self.window) { done in
                stream.start(application: app.identifier, completion: done)
            }
        }
    }

    @objc private func pairPC() {
        guard let form = pcForm else { return }
        form.stream?.stop()
        let stream = VeyraPCStream()
        form.stream = stream
        form.applications.removeAllItems()
        form.applications.isEnabled = false
        form.start.isEnabled = false
        form.entries = []
        form.status.stringValue = "正在连接…"
        stream.pair(host: form.host.stringValue, announcePIN: { [weak form, weak stream] pin in
            DispatchQueue.main.async {
                guard let form, let stream, form.stream === stream else { return }
                form.status.stringValue = "请在 Sunshine 输入配对码 \(pin)"
            }
        }, completion: { [weak form, weak stream] entries, error in
            DispatchQueue.main.async {
                guard let form, let stream, form.stream === stream else { return }
                form.entries = entries ?? []
                form.applications.addItems(withTitles: form.entries.map {
                    $0.name.isEmpty ? "应用 \($0.identifier)" : $0.name
                })
                form.applications.isEnabled = !form.entries.isEmpty
                form.start.isEnabled = !form.entries.isEmpty
                form.status.stringValue = error ?? (form.entries.isEmpty ? "主机没有返回可串流的游戏。" : "")
            }
        })
    }

    @objc private func pickPS5() {
        let host = NSTextField(string: "")
        host.placeholderString = "PS5 的局域网 IP 或主机名"
        let account = NSTextField(string: "")
        account.placeholderString = "十进制数字或 Base64"
        let pin = NSSecureTextField(string: "")
        pin.placeholderString = "首次连接填 8 位码，已配对时留空"
        let inputs = vertical([labeled("主机", host), labeled("PSN Account ID", account),
                               labeled("关联设备配对码", pin)], spacing: 7)
        inputs.frame = NSRect(x: 0, y: 0, width: 470, height: 90)
        let alert = NSAlert()
        alert.messageText = "连接 PS5"
        alert.accessoryView = inputs
        alert.addButton(withTitle: "开始串流")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = host
        alert.beginSheetModal(for: window) { [weak self] reply in
            guard let self, reply == .alertFirstButtonReturn else { return }
            let address = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let identifier = account.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, !identifier.isEmpty else {
                self.status.stringValue = "请输入 PS5 地址和 PSN Account ID。"
                return
            }
            let stream = VeyraPS5Stream()
            let preview = self.beginCapture("PS5", hasAudio: true)
            self.formatLabel.stringValue = "PS5 串流 · 1080p60 SDR"
            preview.startRemote(stream, window: self.window) { done in
                stream.start(host: address, account: identifier, registrationPIN: pin.stringValue, completion: done)
                pin.stringValue = ""
            }
        }
    }

    @objc private func pickXbox() {
        guard pendingXbox == nil else { return }
        let stream = VeyraXboxStream()
        pendingXbox = stream
        let alert = NSAlert()
        alert.messageText = "连接 Xbox"
        let connect = alert.addButton(withTitle: "开始串流")
        connect.isEnabled = false
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "退出登录")
        let status = NSTextField(wrappingLabelWithString: "正在获取主机列表…")
        status.maximumNumberOfLines = 3
        let consoles = NSPopUpButton()
        consoles.addItem(withTitle: "正在获取…")
        consoles.isEnabled = false
        let inputs = vertical([status, labeled("主机", consoles)], spacing: 8)
        inputs.frame = NSRect(x: 0, y: 0, width: 455, height: 81)
        alert.accessoryView = inputs
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.pendingXbox === stream else { return }
            self.pendingXbox = nil
            if response == .alertThirdButtonReturn {
                stream.signOut()
                self.status.stringValue = "Xbox 登录已清除。"
                return
            }
            let index = consoles.indexOfSelectedItem
            guard response == .alertFirstButtonReturn, index >= 0,
                  let consoleName = consoles.selectedItem?.title else {
                stream.stop()
                return
            }
            let preview = self.beginCapture(consoleName, hasAudio: true)
            self.formatLabel.stringValue = "Xbox 串流 · SDR"
            preview.startRemote(stream, window: self.window) { done in
                stream.start(console: index, completion: done)
            }
        }
        stream.listConsoles(announceCode: { [weak self, weak stream] code in
            DispatchQueue.main.async {
                guard let self, let stream, self.pendingXbox === stream else { return }
                status.stringValue = "请在 microsoft.com/link 输入 \(code)"
                status.isSelectable = true
            }
        }, completion: { [weak self, weak stream] names, error in
            DispatchQueue.main.async {
                guard let self, let stream, self.pendingXbox === stream else { return }
                let entries = names ?? []
                consoles.removeAllItems()
                for name in entries { consoles.menu?.addItem(withTitle: name, action: nil, keyEquivalent: "") }
                if !entries.isEmpty { consoles.selectItem(at: 0) }
                connect.isEnabled = !entries.isEmpty
                consoles.isEnabled = !entries.isEmpty
                status.stringValue = error ?? (entries.isEmpty ? "账号下没有可串流的 Xbox 主机。" : "")
            }
        })
    }

    @objc private func pickScreen() {
        let request = UUID()
        loadRequest = request
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard self.loadRequest == request else { return }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
                let windows = content.windows.filter {
                    $0.owningApplication?.processID != ownPID && $0.windowLayer == 0 &&
                        $0.frame.width > 32 && $0.frame.height > 32
                }
                let displays = content.displays
                let labels = displays.enumerated().map { "显示器 \($0.offset + 1) · \($0.element.width)×\($0.element.height)" } +
                    windows.map { window in
                        let app = window.owningApplication?.applicationName ?? "窗口"
                        return "窗口 · " + app + " · " + (window.title ?? "")
                    }
                guard !labels.isEmpty else { throw MediaProblem("没有可采集的屏幕或窗口。") }
                self.pickSource(title: "屏幕或窗口", labels: labels) { [weak self] index in
                    guard let self else { return }
                    let filter: SCContentFilter
                    let dimensions: CGSize
                    if displays.indices.contains(index) {
                        let display = displays[index]
                        filter = CapturePreview.displayFilter(display, excluding: ownWindows)
                        dimensions = CGSize(width: display.width, height: display.height)
                    } else {
                        let window = windows[index - displays.count]
                        filter = CapturePreview.windowFilter(window)
                        let scale = CGFloat(filter.pointPixelScale)
                        dimensions = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
                    }
                    let preview = self.beginCapture(labels[index], hasAudio: true)
                    Task { @MainActor [weak self, weak preview] in
                        guard let self, let preview else { return }
                        do { try await preview.startScreen(filter: filter, dimensions: dimensions) }
                        catch {
                            if self.capture === preview { self.failCapture(error.localizedDescription) }
                        }
                    }
                }
            } catch {
                if self.loadRequest == request { self.status.stringValue = error.localizedDescription }
            }
        }
    }

    @objc private func pickDevice() {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
        let inputs = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
        guard !devices.isEmpty else { status.stringValue = "没有检测到支持的采集卡或摄像机。"; return }
        let audioOptions = NSPopUpButton()
        let audioDevices = [nil] + inputs.map(Optional.some)
        audioOptions.addItems(withTitles: ["仅视频（无音频）"] +
            inputs.map(\.localizedName))
        pickSource(title: "采集卡或摄像机", labels: devices.map(\.localizedName), extra: audioOptions) { [weak self] index in
            guard let self else { return }
            let request = UUID()
            self.loadRequest = request
            let chosenAudio = audioDevices[max(0, audioOptions.indexOfSelectedItem)]
            Task { @MainActor [weak self] in
                guard let self else { return }
                let videoPermission = await AVCaptureDevice.requestAccess(for: .video)
                guard self.loadRequest == request else { return }
                guard videoPermission else {
                    self.status.stringValue = "摄像机权限未授予。"
                    return
                }
                if chosenAudio != nil {
                    let audioPermission = await AVCaptureDevice.requestAccess(for: .audio)
                    guard self.loadRequest == request else { return }
                    guard audioPermission else {
                        self.status.stringValue = "音频采集权限未授予。"
                        return
                    }
                }
                let preview = self.beginCapture(devices[index].localizedName, hasAudio: chosenAudio != nil)
                preview.startDevice(devices[index], audioDevice: chosenAudio)
            }
        }
    }

    private func pickSource(title: String, labels: [String], extra: NSView? = nil, select: @escaping (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let menu = NSPopUpButton()
        for label in labels { menu.menu?.addItem(withTitle: label, action: nil, keyEquivalent: "") }
        menu.selectItem(at: 0)
        let controls = vertical([menu] + (extra.map { [$0] } ?? []), spacing: 8)
        controls.frame = NSRect(x: 0, y: 0, width: 400, height: extra == nil ? 26 : 58)
        alert.accessoryView = controls
        alert.addButton(withTitle: "开始采集")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn, labels.indices.contains(menu.indexOfSelectedItem) {
                select(menu.indexOfSelectedItem)
            }
        }
    }

    private func beginCapture(_ name: String, hasAudio: Bool, network: Bool = false) -> CapturePreview {
        loadRequest = UUID()
        active?.stop()
        active = nil
        capture?.stop()
        media = nil
        clearStill()
        resetSubtitleOptions(0)
        comparison.state = .off
        interpolate.state = .off
        cadence.state = .off
        filename.stringValue = name
        formatLabel.stringValue = network ? "网络播放 · SDR" : "实时采集 · SDR"
        time.stringValue = "实时"
        seek.doubleValue = 0
        wantsPlayback = true
        ready = true
        playButton.title = "暂停"
        details.stringValue = ""
        welcome.isHidden = true
        replayEnabled = false
        captureHasAudio = hasAudio
        captureIsNetwork = network
        captureRecording = false
        recordButton.isEnabled = true
        let preview = CapturePreview(effects: currentEffects())
        capture = preview
        surface.show(preview.display)
        preview.setVolume(volume.floatValue)
        preview.setOBSOutput(obsOutput)
        resetLiveCaptions()
        updateEnabledControls()
        status.stringValue = "正在等待采集信号…"
        preview.onError = { [weak self, weak preview] reason in
            guard let self, let preview, self.capture === preview else { return }
            self.failCapture(reason)
        }
        preview.onReplayError = { [weak self, weak preview] error in
            DispatchQueue.main.async {
                guard let self, let preview, self.capture === preview else { return }
                self.status.stringValue = error.localizedDescription
            }
        }
        preview.onRecording = { [weak self, weak preview] result in
            guard let self, let preview, self.capture === preview else { return }
            self.captureRecording = false
            self.recordButton.isEnabled = true
            self.updateEnabledControls()
            switch result {
            case .success(let recording): self.status.stringValue = "录制已保存 · \(recording.files) 个文件 · \(recording.frames) 帧"
            case .failure(let error): self.status.stringValue = error.localizedDescription
            }
        }
        preview.onStatistics = { [weak self, weak preview] frames, generated, dropped, stats in
            guard let self, let preview, self.capture === preview else { return }
            if self.status.stringValue == "正在等待采集信号…" { self.status.stringValue = "" }
            let gpu = stats["metal"].map { String(format: " · GPU %.2f ms", $0.p50Ms) } ?? ""
            self.details.stringValue = "采集帧 \(frames) · 补帧 \(generated) · 缓冲跳过 \(dropped)" + gpu
        }
        return preview
    }

    @objc private func toggleOBS() {
        guard active != nil || capture != nil else { return }
        if obsOutput == nil {
            guard !effect.preserveHDR || capture != nil else {
                status.stringValue = "OBS 来源目前需要 SDR 输出。"
                return
            }
            guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                  let publisher = VeyraOBSOutput(cacheDirectory: directory) else {
                status.stringValue = "无法建立本机 OBS 画面来源。"
                return
            }
            obsOutput = publisher
        } else {
            obsOutput = nil
        }
        active?.setOBSOutput(obsOutput)
        capture?.setOBSOutput(obsOutput)
        status.stringValue = obsOutput == nil ? "OBS 画面输出已关闭。" : "OBS 中添加 Veyra Processed Video 来源。"
    }

    private func failCapture(_ reason: String) {
        stopCapture()
        status.stringValue = reason
    }

    @objc private func toggleReplay() {
        guard let capture, !captureIsNetwork else { return }
        replayEnabled.toggle()
        capture.enableReplay(replayEnabled, withAudio: captureHasAudio)
        status.stringValue = replayEnabled ? "即时回放已开启，保存最近 15 秒。" : "即时回放已关闭。"
    }

    @objc private func saveReplay() {
        guard let capture, !captureIsNetwork, replayEnabled else {
            status.stringValue = "开始采集并打开即时回放后可以保存。"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Veyra 回放.mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            capture.saveReplay(to: url) { result in
                switch result {
                case .success: self?.status.stringValue = "已保存即时回放"
                case .failure(let error): self?.status.stringValue = error.localizedDescription
                }
            }
        }
    }

    @objc private func toggleCaptureRecording() {
        guard let capture else { return }
        if captureRecording {
            recordButton.isEnabled = false
            status.stringValue = "正在保存录制…"
            capture.endRecording()
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Veyra 录制.mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        let includeAudio = NSButton(checkboxWithTitle: "录制采集音频", target: nil, action: nil)
        includeAudio.state = captureHasAudio ? .on : .off
        includeAudio.isEnabled = captureHasAudio
        let duration = NSTextField(string: "0")
        let size = NSTextField(string: "0")
        for field in [duration, size] { field.widthAnchor.constraint(equalToConstant: 76).isActive = true }
        let fields = vertical([includeAudio, labeled("分段秒数（0 关闭）", duration),
                               labeled("分段大小 MiB（0 关闭）", size)], spacing: 6)
        fields.frame = NSRect(x: 0, y: 0, width: 310, height: 88)
        panel.accessoryView = fields
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.capture === capture, response == .OK, let url = panel.url else { return }
            guard let seconds = Int(duration.stringValue.trimmingCharacters(in: .whitespaces)), (0...86_400).contains(seconds),
                  let mib = Int(size.stringValue.trimmingCharacters(in: .whitespaces)), (0...1_048_576).contains(mib) else {
                self.status.stringValue = "请输入有效的整数分段秒数和大小。"
                return
            }
            self.recordButton.isEnabled = false
            capture.startRecording(to: url, withAudio: includeAudio.state == .on,
                                   segmentSeconds: seconds, segmentMiB: mib) { result in
                guard self.capture === capture else { return }
                self.recordButton.isEnabled = true
                switch result {
                case .success:
                    self.captureRecording = true
                    self.status.stringValue = "正在录制…"
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription
                }
                self.updateEnabledControls()
            }
        }
    }

    @objc private func stopCapture() {
        loadRequest = UUID()
        guard let capture else { return }
        capture.stop()
        self.capture = nil
        resetLiveCaptions()
        captureIsNetwork = false
        captureRecording = false
        recordButton.isEnabled = true
        surface.show(nil)
        filename.stringValue = "请选择本地媒体"
        formatLabel.stringValue = ""
        status.stringValue = ""
        time.stringValue = "00:00 / 00:00"
        details.stringValue = ""
        welcome.isHidden = false
        wantsPlayback = false
        playButton.title = "播放"
        updateEnabledControls()
    }

    @objc private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image] + (UTType(filenameExtension: "mkv").map { [$0] } ?? [])
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK { self?.openPlaylist(panel.urls) }
        }
    }

    private func openPlaylist(_ files: [URL]) {
        guard let first = files.first else { return }
        playlist = files
        playlistControl.removeAllItems()
        for file in files { playlistControl.menu?.addItem(withTitle: file.lastPathComponent, action: nil, keyEquivalent: "") }
        playlistControl.selectItem(at: 0)
        updateEnabledControls()
        load(first)
    }

    @objc private func selectPlaylistItem() {
        let index = playlistControl.indexOfSelectedItem
        if playlist.indices.contains(index) { load(playlist[index]) }
    }

    private var playbackSpeed: Float { [1, 1.5, 2, 3][max(0, speed.indexOfSelectedItem)] }

    @objc private func changePlaybackSpeed() { restart(at: active?.time ?? .zero) }

    private func load(_ url: URL) {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            loadStill(url)
            return
        }
        let request = UUID()
        loadRequest = request
        status.stringValue = "正在读取视频…"
        Task { @MainActor [weak self] in
            do {
                let file = try await MediaFile.open(url)
                guard let self, self.loadRequest == request else { return }
                self.clearStill()
                self.capture?.stop()
                self.capture = nil
                self.captureIsNetwork = false
                self.media = file
                self.resetSubtitleOptions(file.subtitleCount)
                self.filename.stringValue = url.lastPathComponent
                self.welcome.isHidden = true
                self.wantsPlayback = true
                self.audioTrack.removeAllItems()
                self.audioTrack.addItems(withTitles: file.audioTracks.indices.map { "音轨 \($0 + 1)" })
                if file.audioTracks.isEmpty { self.audioTrack.addItem(withTitle: "无音轨") }
                self.seek.maxValue = file.duration.seconds
                self.seek.doubleValue = 0
                self.comparison.state = .off
                if !VideoFrames.canInterpolate(file) { self.interpolate.state = .off }
                if !(55...65).contains(file.frameRate) { self.cadence.state = .off }
                self.updateEnabledControls()
                self.applyEffects(at: .zero)
            } catch {
                guard let self, self.loadRequest == request else { return }
                self.status.stringValue = error.localizedDescription
            }
        }
    }

    private func clearStill() {
        still = nil
        stillOutput = nil
        stillWork?.cancel()
        stillWork = nil
        stillRequest = UUID()
    }

    private func loadStill(_ url: URL) {
        let request = UUID()
        loadRequest = request
        status.stringValue = "正在读取图片…"
        stillQueue.async { [weak self] in
            let result = Result { try StillImage(url: url) }
            DispatchQueue.main.async {
                guard let self, self.loadRequest == request else { return }
                switch result {
                case .success(let image):
                    self.active?.stop()
                    self.active = nil
                    self.capture?.stop()
                    self.capture = nil
                    self.captureIsNetwork = false
                    self.media = nil
                    self.clearStill()
                    self.still = image
                    self.surface.show(nil)
                    self.resetSubtitleOptions(0)
                    self.resetLiveCaptions()
                    self.subtitleLabel.isHidden = true
                    self.comparison.state = .off
                    self.wantsPlayback = false
                    self.ready = false
                    self.playButton.title = "播放"
                    self.filename.stringValue = url.lastPathComponent
                    self.time.stringValue = ""
                    self.seek.doubleValue = 0
                    self.details.stringValue = ""
                    self.welcome.isHidden = true
                    self.applyEffects(at: .zero)
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription
                }
            }
        }
    }

    private func renderStill(_ still: StillImage, effects: Effects) {
        stillWork?.cancel()
        let request = UUID()
        stillRequest = request
        status.stringValue = "正在处理图片…"
        let work = DispatchWorkItem { [weak self] in
            let result = autoreleasepool { Result { try still.render(effects: effects) } }
            DispatchQueue.main.async {
                guard let self, self.stillRequest == request else { return }
                self.stillWork = nil
                switch result {
                case .success(let output):
                    self.stillOutput = output
                    self.surface.showImage(output)
                    let inputSize = "\(Int(still.size.width))×\(Int(still.size.height))"
                    let outputSize = "\(output.width)×\(output.height)"
                    self.formatLabel.stringValue = inputSize == outputSize ? inputSize : "\(inputSize) → \(outputSize)"
                    self.status.stringValue = ""
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription
                }
            }
        }
        stillWork = work
        stillQueue.async(execute: work)
    }

    private func restart(at seekTime: CMTime) {
        guard let media else { return }
        let remaining = min(0.12, media.duration.seconds * 0.25)
        let seconds = max(0, min(seekTime.seconds, media.duration.seconds - remaining))
        let start = CMTime(seconds: seconds, preferredTimescale: 60000)
        let refresh = window.screen?.maximumFramesPerSecond ?? 60
        let renderEffects = comparison.state == .on ? Effects(preserveHDR: effect.preserveHDR) :
            effect.preview(on: Double(refresh) / Double(playbackSpeed), sourceRate: Double(media.frameRate))
        active?.stop()
        let selectedTrack = media.audioTracks.indices.contains(audioTrack.indexOfSelectedItem)
            ? media.audioTracks[audioTrack.indexOfSelectedItem] : media.audio
        let session = Preview(hasAudio: selectedTrack != nil, time: start)
        session.display.preferredDynamicRange = renderEffects.preserveHDR ? .high : .standard
        active = session
        ready = false
        details.stringValue = ""
        surface.show(session.display)
        session.volume(volume.floatValue)
        session.setOBSOutput(renderEffects.preserveHDR ? nil : obsOutput)
        resetLiveCaptions()
        session.onReady = { [weak self, weak session] in
            guard let self, let session, self.active === session else { return }
            self.ready = true
            if self.wantsPlayback { session.play(at: self.playbackSpeed) }
            if self.currentExport == nil {
                if self.comparison.state == .off, self.effect.interpolate,
                   self.effect.multiplier != renderEffects.multiplier {
                    let current = renderEffects.interpolate ? "\(renderEffects.multiplier)×" : "关闭"
                    self.status.stringValue = "\(refresh) Hz 预览补帧\(current)，导出使用 \(self.effect.multiplier)×。"
                } else {
                    self.status.stringValue = ""
                }
            }
            self.refreshPosition()
        }
        session.onError = { [weak self, weak session] error in
            guard let self, let session, self.active === session else { return }
            self.wantsPlayback = false
            self.ready = false
            session.pause()
            self.status.stringValue = error.localizedDescription
            self.refreshPosition()
        }
        session.onStatistics = { [weak self, weak session] stats in
            guard let self, let session, self.active === session else { return }
            let renderTiming = stats.stages["metal"].map { String(format: " · GPU %.2f ms", $0.p50Ms) }
                ?? stats.stages["hdrOutput"].map { String(format: " · HDR %.2f ms", $0.p50Ms) } ?? ""
            let drops = stats.rendererDrops.map { " · 渲染丢帧 \($0)" } ?? ""
            let skipped = stats.skippedLateGenerated == 0 ? "" : " · 跳过 \(stats.skippedLateGenerated)"
            self.details.stringValue = "源帧 \(stats.source) · 补帧 \(stats.generated) · 入队 \(stats.queued)" + renderTiming + skipped + drops
        }
        if currentExport == nil { status.stringValue = "正在准备画面…" }
        let result = renderEffects.outputSize(for: media)
        let oriented = media.orientedSize
        let source = "\(Int(oriented.width))×\(Int(oriented.height))"
        let out = "\(Int(result.width))×\(Int(result.height))"
        let fps = media.frameRate > 0 ? String(format: " · %.2f fps", media.frameRate) : ""
        let analysis = VideoFrames.interpolationSize(media)
        let limited = effect.interpolate && comparison.state == .off && analysis != media.size
            ? " · 补帧计算 \(Int(analysis.width))×\(Int(analysis.height))" : ""
        let colour = media.hdr ? (effect.preserveHDR ? " · HDR 10-bit" : " · HDR → SDR") : ""
        formatLabel.stringValue = source + (source == out ? "" : " → " + out) + fps + colour + limited
        session.start(media: media, effects: renderEffects, time: start, audioTrack: selectedTrack)
        refreshPosition()
    }

    @objc private func togglePlay() {
        if let capture {
            wantsPlayback.toggle()
            capture.setPlaying(wantsPlayback)
            playButton.title = wantsPlayback ? "暂停" : "播放"
            return
        }
        guard let media else { return }
        wantsPlayback.toggle()
        if wantsPlayback, let active, active.time.seconds >= media.duration.seconds - 0.05 {
            restart(at: .zero)
        } else if wantsPlayback, ready {
            active?.play(at: playbackSpeed)
        } else {
            active?.pause()
        }
        refreshPosition()
    }

    @objc private func seekChanged() {
        restart(at: CMTime(seconds: seek.doubleValue, preferredTimescale: 60000))
    }

    @objc private func pickCaptionMode() {
        let source = NSPopUpButton()
        source.addItems(withTitles: ["英语", "普通话", "日语", "韩语"])
        let target = NSPopUpButton()
        target.addItems(withTitles: ["仅转写", "简体中文", "英语"])
        let box = vertical([labeled("语音语言", source), labeled("翻译为", target)], spacing: 10)
        box.frame = NSRect(x: 0, y: 0, width: 260, height: 120)
        let alert = NSAlert()
        alert.messageText = "实时字幕与翻译"
        alert.informativeText = "使用系统已安装的本机语言资源。"
        alert.accessoryView = box
        alert.addButton(withTitle: "启用")
        alert.addButton(withTitle: "停用")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                self.captionMode = nil
                self.resetLiveCaptions()
                return
            }
            guard response == .alertFirstButtonReturn else { return }
            let inputLanguage = ["en-US", "zh-CN", "ja-JP", "ko-KR"][source.indexOfSelectedItem]
            let outputLanguage: String? = [nil, "zh-Hans", "en"][target.indexOfSelectedItem]
            SFSpeechRecognizer.requestAuthorization { permission in
                DispatchQueue.main.async {
                    guard permission == .authorized else {
                        self.status.stringValue = "本机语音识别权限未授予。"
                        return
                    }
                    self.captionMode = (inputLanguage, outputLanguage)
                    self.resetLiveCaptions()
                }
            }
        }
    }

    private func resetLiveCaptions() {
        captions?.stop()
        captions = nil
        captionTask?.cancel()
        translatedCaption = ""
        lastCaptionSubmit = .distantPast
        guard let mode = captionMode, (active != nil && !((media?.audioTracks.isEmpty) ?? true)) ||
                (capture != nil && captureHasAudio && !captureIsNetwork) else {
            if capture != nil { subtitleLabel.isHidden = true }
            return
        }
        do {
            let engine = try LiveCaptions(locale: Locale(identifier: mode.source))
            captions = engine
            engine.onError = { [weak self, weak engine] error in
                guard let self, self.captions === engine else { return }
                self.status.stringValue = error.localizedDescription
            }
            engine.onText = { [weak self, weak engine] text in
                guard let self, self.captions === engine else { return }
                self.acceptCaption(text, source: mode.source, target: mode.target)
            }
            active?.setCaptions(engine)
            capture?.setCaptions(engine)
            engine.start()
        } catch { status.stringValue = error.localizedDescription }
    }

    private func acceptCaption(_ text: String, source: String, target: String?) {
        guard let target, !source.hasPrefix(String(target.prefix(2))) else {
            showLiveCaption(text)
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastCaptionSubmit) >= 0.6 else { return }
        lastCaptionSubmit = now
        captionTask?.cancel()
        captionTask = Task { @MainActor [weak self] in
            let from = Locale.Language(identifier: source)
            let to = Locale.Language(identifier: target)
            guard await LanguageAvailability().status(from: from, to: to) == .installed else {
                guard !Task.isCancelled, let self else { return }
                self.status.stringValue = "本机缺少该翻译语言包，当前显示原文。"
                self.showLiveCaption(text)
                return
            }
            let session = TranslationSession(installedSource: from, target: to)
            do {
                let result = try await session.translate(text)
                if !Task.isCancelled { self?.showLiveCaption(result.targetText) }
            } catch {
                if !Task.isCancelled { self?.showLiveCaption(text) }
            }
        }
    }

    private func showLiveCaption(_ text: String) {
        translatedCaption = text
        if capture != nil {
            subtitleLabel.stringValue = text
            subtitleLabel.isHidden = text.isEmpty
        } else {
            refreshPosition()
        }
    }

    private func resetSubtitleOptions(_ available: Int) {
        subtitleRequest = UUID()
        subtitle = nil
        subtitleLabel.isHidden = true
        subtitleSelector.removeAllItems()
        subtitleSelector.addItem(withTitle: "关闭字幕")
        if MediaContainer.supportsMatroska {
            subtitleSelector.addItems(withTitles: (0..<available).map { "内嵌字幕 \($0 + 1)" })
        }
        subtitleSelector.addItem(withTitle: "载入 SRT / VTT…")
    }

    @objc private func selectSubtitle() {
        guard let media else { return }
        let index = subtitleSelector.indexOfSelectedItem
        let request = UUID()
        subtitleRequest = request
        if index == 0 {
            subtitle = nil
            subtitleLabel.isHidden = true
        } else if index == subtitleSelector.numberOfItems - 1 {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = ["srt", "vtt"].compactMap { UTType(filenameExtension: $0) }
            panel.beginSheetModal(for: window) { [weak self] reply in
                guard let self, self.subtitleRequest == request else { return }
                if reply == .OK, let url = panel.url {
                    do { self.subtitle = try SubtitleTrack(url: url) }
                    catch { self.status.stringValue = error.localizedDescription }
                }
                if self.subtitle == nil { self.subtitleSelector.selectItem(at: 0) }
                self.refreshPosition()
            }
        } else {
            Task { @MainActor [weak self] in
                do {
                    let track = try await MediaContainer.readSubtitle(from: media.asset.url, index: index - 1)
                    guard let self, self.subtitleRequest == request else { return }
                    self.subtitle = track
                    self.refreshPosition()
                } catch {
                    guard let self, self.subtitleRequest == request else { return }
                    self.status.stringValue = error.localizedDescription
                    self.subtitle = nil
                    self.subtitleSelector.selectItem(at: 0)
                    self.refreshPosition()
                }
            }
        }
    }

    @objc private func changeAudioTrack() { restart(at: active?.time ?? .zero) }

    @objc private func volumeChanged() {
        active?.volume(volume.floatValue)
        capture?.setVolume(volume.floatValue)
    }
    @objc private func fullscreen() { window.toggleFullScreen(nil) }

    @objc private func changeEffects() { applyEffects(at: active?.time ?? .zero) }

    private func applyEffects(at position: CMTime) {
        guard media != nil || capture != nil || still != nil else { return }
        effect = currentEffects()
        effect.preserveHDR = media?.hdr == true && effect.preserveHDR
        updateEnabledControls()
        if let still {
            renderStill(still, effects: comparison.state == .on ? Effects() : effect)
        } else if let capture {
            let refresh = window.screen?.maximumFramesPerSecond ?? 60
            capture.configure(comparison.state == .on ? Effects() : effect.preview(on: Double(refresh), sourceRate: 60))
        }
        else { restart(at: position) }
    }

    private func currentEffects() -> Effects {
        Effects(scale: [1, 1.5, 2][max(0, scale.indexOfSelectedItem)],
                         interpolate: interpolate.state == .on, multiplier: Effects.multipliers[max(0, multiplier.indexOfSelectedItem)],
                         capture60To30: cadence.state == .on,
                         preserveHDR: hdrOutput.state == .on,
                         saturation: saturation.floatValue, contrast: contrast.floatValue,
                         noiseReduction: noiseReduction.floatValue, exposure: exposure.floatValue,
                         sharpness: sharpness.floatValue, fxaa: antiAlias.state == .on, lookup: inputLUT, graph: pictureGraph,
                         grade: colourGrade, additionalDenoise: additionalDenoise, denoiseProtection: denoiseProtection)
    }

    @objc private func pickLUT() {
        let panel = NSOpenPanel()
        if let cubeType = UTType(filenameExtension: "cube") { panel.allowedContentTypes = [cubeType] }
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            do {
                self.inputLUT = try CubeLookup(url: url)
                self.lutName.stringValue = self.inputLUT?.name ?? ""
                self.changeEffects()
            } catch { self.status.stringValue = error.localizedDescription }
        }
    }

    @objc private func clearLUT() {
        inputLUT = nil
        lutName.stringValue = "未加载"
        changeEffects()
    }

    @objc private func resetEffects() {
        scale.selectItem(at: 0)
        interpolate.state = .off
        multiplier.selectItem(at: 0)
        cadence.state = .off
        hdrOutput.state = .on
        comparison.state = .off
        noiseReduction.floatValue = 0
        additionalDenoise = []
        denoiseProtection = []
        exposure.floatValue = 0
        saturation.floatValue = 1
        contrast.floatValue = 1
        sharpness.floatValue = 0
        antiAlias.state = .off
        pictureGraph = nil
        colourGrade = .identity
        clearLUT()
    }

    @objc private func saveScreenshot() {
        let active = active
        let image = stillOutput
        guard active != nil || image != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Veyra.png"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            func show(_ response: Result<Void, Error>) {
                switch response {
                case .success: self?.status.stringValue = "已保存 PNG"
                case .failure(let error): self?.status.stringValue = error.localizedDescription
                }
            }
            if let active { active.screenshot(to: url, completion: show) }
            else if let image, let self {
                self.stillQueue.async {
                    let result = Result { try StillImage.savePNG(image, to: url) }
                    DispatchQueue.main.async { show(result) }
                }
            }
        }
    }

    @objc private func editColourGrade() {
        let grade = colourGrade
        let labels = ["色相（度）", "色温偏移", "色调偏移", "暗部曲线", "中间调曲线", "亮部曲线", "Gamma",
                      "RGB 混色矩阵", "RGB 提升"]
        let values = [grade.hue, grade.temperature, grade.tint, grade.shadow, grade.midpoint, grade.highlight, grade.gamma]
            .map { String(format: "%.3f", $0) } +
            [grade.matrix, grade.lift].map { $0.map { String(format: "%.3f", $0) }.joined(separator: " ") }
        let fields = values.map { NSTextField(string: $0) }
        let rows = zip(labels, fields).map { horizontal([NSTextField(labelWithString: $0.0), $0.1], spacing: 8) }
        let controls = vertical(rows, spacing: 5)
        controls.frame = NSRect(x: 0, y: 0, width: 440, height: 250)
        let alert = NSAlert()
        alert.messageText = "高级调色"
        alert.informativeText = "曲线值使用 0–1。混色矩阵按 RGB 三行填写九个数。"
        alert.accessoryView = controls
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                self.colourGrade = .identity
                self.changeEffects()
                return
            }
            guard response == .alertFirstButtonReturn else { return }
            let numbers = fields.prefix(7).compactMap { Float($0.stringValue) }
            let matrix = fields[7].stringValue.split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
            let lift = fields[8].stringValue.split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
            guard numbers.count == 7 else { self.status.stringValue = "请输入有效的调色数值。"; return }
            do {
                self.colourGrade = try ColourGrade(hue: numbers[0], temperature: numbers[1], tint: numbers[2],
                    shadow: numbers[3], midpoint: numbers[4], highlight: numbers[5], matrix: matrix,
                    lift: lift, gamma: numbers[6]).validated()
                self.changeEffects()
            } catch { self.status.stringValue = error.localizedDescription }
        }
    }

    @objc private func editGraph() {
        let editor = PictureGraphEditor(graph: pictureGraph ?? .standard)
        let alert = NSAlert()
        alert.messageText = "处理链"
        alert.accessoryView = editor
        let apply = alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "恢复默认")
        alert.addButton(withTitle: "取消")
        editor.onValidityChanged = { [weak apply] valid in apply?.isEnabled = valid }
        editor.refreshControls()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                guard (try? editor.graph.compile()) != nil else { return }
                self.pictureGraph = editor.graph
            case .alertSecondButtonReturn:
                self.pictureGraph = nil
            default:
                return
            }
            self.changeEffects()
        }
    }

    @objc private func editDenoiseLayers() {
        let values = [noiseReduction.floatValue] + additionalDenoise + [0, 0, 0]
        let sliders = values.prefix(4).map { value in
            NSSlider(value: Double(value), minValue: 0, maxValue: 1, target: nil, action: nil)
        }
        let rows = sliders.enumerated().map { index, slider in
            slider.setAccessibilityLabel("降噪第 \(index + 1) 层")
            slider.widthAnchor.constraint(equalToConstant: 230).isActive = true
            return labeled("第 \(index + 1) 层", slider)
        }
        let inputs = vertical(rows, spacing: 8)
        inputs.frame = NSRect(x: 0, y: 0, width: 325, height: 112)
        let alert = NSAlert()
        alert.messageText = "时域降噪叠层"
        alert.informativeText = "各层按顺序执行。强度为 0 时跳过该层。"
        alert.accessoryView = inputs
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] reply in
            guard let self, reply == .alertFirstButtonReturn else { return }
            self.noiseReduction.floatValue = sliders[0].floatValue
            self.additionalDenoise = sliders.dropFirst().map(\.floatValue)
            self.changeEffects()
        }
    }

    @objc private func editDenoiseProtection() {
        let values = denoiseProtection.map {
            [$0.x, $0.y, $0.width, $0.height].map { String(format: "%.3f", $0 * 100) }.joined(separator: " ")
        }.joined(separator: "\n")
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 116))
        editor.isRichText = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.string = values
        let scroll = NSScrollView(frame: editor.frame)
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let alert = NSAlert()
        alert.messageText = "降噪保护区域"
        alert.informativeText = "每行输入一个矩形，四列依次为距画面左侧、距顶侧、宽、高的百分比，用空格分隔。最多 8 个，留空可清除。"
        alert.accessoryView = scroll
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] reply in
            guard let self, reply == .alertFirstButtonReturn else { return }
            let lines = editor.string.split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let regions = lines.compactMap { line -> DenoiseRegion? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                let numbers = fields.compactMap { Double($0).map { $0 / 100 } }
                guard fields.count == 4, numbers.count == 4 else { return nil }
                let region = DenoiseRegion(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
                return region.isValid ? region : nil
            }
            guard regions.count == lines.count, regions.count <= 8 else {
                self.status.stringValue = "请输入 0–100 范围内的有效矩形，矩形须完整落在画面内。"
                return
            }
            self.denoiseProtection = regions
            self.changeEffects()
        }
    }

    @objc private func savePreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = lastLoadedPreset?.lastPathComponent ?? "Veyra-画质.json"
        let preset = PicturePreset(effects: currentEffects())
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try preset.write(to: url)
                self?.lastLoadedPreset = url
                self?.status.stringValue = "已保存画质预设"
            } catch { self?.status.stringValue = error.localizedDescription }
        }
    }

    @objc private func openPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let preset = try JSONDecoder().decode(PicturePreset.self, from: data)
                let settings = try preset.restore()
                self.lastLoadedPreset = url
                self.scale.selectItem(at: [1.0, 1.5, 2.0].firstIndex(of: settings.scale) ?? 0)
                self.interpolate.state = settings.interpolate ? .on : .off
                self.multiplier.selectItem(at: Effects.multipliers.firstIndex(of: settings.multiplier) ?? 0)
                self.cadence.state = settings.capture60To30 ? .on : .off
                self.hdrOutput.state = settings.preserveHDR ? .on : .off
                self.comparison.state = .off
                self.noiseReduction.floatValue = settings.noiseReduction
                self.additionalDenoise = settings.additionalDenoise
                self.denoiseProtection = settings.denoiseProtection
                self.exposure.floatValue = settings.exposure
                self.saturation.floatValue = settings.saturation
                self.contrast.floatValue = settings.contrast
                self.sharpness.floatValue = settings.sharpness
                self.antiAlias.state = settings.fxaa ? .on : .off
                self.pictureGraph = settings.graph
                self.colourGrade = settings.grade
                self.inputLUT = settings.lookup
                self.lutName.stringValue = settings.lookup?.name ?? "未加载"
                self.changeEffects()
            } catch { self.status.stringValue = error.localizedDescription }
        }
    }

    @objc private func savePerformance() {
        let active = active
        let capture = capture
        guard active != nil || capture != nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Veyra-性能记录.json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            func save<Report: Encodable>(_ report: Report) {
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(report).write(to: url, options: .atomic)
                    self?.status.stringValue = "已保存性能记录"
                } catch { self?.status.stringValue = error.localizedDescription }
            }
            if let active { active.performance { save($0) } }
            else { capture?.performance { save($0) } }
        }
    }

    @objc private func pickExport() {
        guard let media else { return }
        let settings = effect
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        if MediaContainer.supportsMatroska, let mkv = UTType(filenameExtension: "mkv") {
            panel.allowedContentTypes.append(mkv)
        }
        panel.nameFieldStringValue = media.url.deletingPathExtension().lastPathComponent + "-Veyra.mp4"
        let trimStart = NSTextField(string: "0")
        let trimEnd = NSTextField(string: String(format: "%.3f", media.duration.seconds))
        trimStart.widthAnchor.constraint(equalToConstant: 75).isActive = true
        trimEnd.widthAnchor.constraint(equalToConstant: 75).isActive = true
        let rangeFields = horizontal([NSTextField(labelWithString: "开始（秒）"), trimStart,
                                      NSTextField(labelWithString: "结束（秒）"), trimEnd], spacing: 8)
        rangeFields.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = rangeFields
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            guard let start = Double(trimStart.stringValue), let end = Double(trimEnd.stringValue),
                  start.isFinite, end.isFinite, start >= 0, end > start,
                  end <= media.duration.seconds + 0.001 else {
                self?.status.stringValue = "导出区间必须在视频时长内。"
                return
            }
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600000),
                                    end: CMTime(seconds: end, preferredTimescale: 600000))
            self?.enqueueExport(ExportRequest(media: media, settings: settings, range: range, destination: url))
        }
    }

    @objc private func clearExports() {
        pendingExports.removeAll()
        updateEnabledControls()
    }

    @objc private func retryExport() {
        guard let failedExport else { return }
        self.failedExport = nil
        enqueueExport(failedExport)
    }

    private func enqueueExport(_ request: ExportRequest) {
        pendingExports.append(request)
        updateEnabledControls()
        advanceExports()
    }

    private func advanceExports() {
        guard currentExport == nil, !pendingExports.isEmpty else { return }
        let request = pendingExports.removeFirst()
        active?.pause()
        wantsPlayback = false
        refreshPosition()
        let job = VideoExport()
        currentExport = job
        progress.doubleValue = 0
        progress.isHidden = false
        cancel.isHidden = false
        cancel.isEnabled = true
        status.stringValue = "正在导出…"
        updateEnabledControls()
        job.run(media: request.media, effects: request.settings, destination: request.destination, range: request.range, progress: { [weak self] value in
            self?.progress.doubleValue = value
        }, completion: { [weak self] result in
            guard let self else { return }
            self.currentExport = nil
            self.progress.isHidden = true
            self.cancel.isHidden = true
            self.updateEnabledControls()
            switch result {
            case .success(let summary):
                self.status.stringValue = "已导出 \(summary.width)×\(summary.height) · \(summary.frames) 帧 · 补帧 \(summary.generated) · \(summary.hasAudio ? "\(summary.audioTracks) 条音轨" : "无音轨")"
            case .failure(let error):
                self.failedExport = request
                self.status.stringValue = error.localizedDescription
            }
            self.updateEnabledControls()
            self.advanceExports()
        })
    }

    @objc private func cancelExport() {
        currentExport?.cancel()
        cancel.isEnabled = false
        status.stringValue = "正在取消…"
    }

    private func refreshPosition() {
        guard let media, let active else { return }
        let value = min(media.duration.seconds, max(0, active.time.seconds))
        if ready, wantsPlayback, value >= media.duration.seconds {
            wantsPlayback = false
            active.pause()
            let next = playlistControl.indexOfSelectedItem + 1
            if playlist.indices.contains(next) {
                playlistControl.selectItem(at: next)
                load(playlist[next])
            }
        }
        if NSApp.currentEvent?.type != .leftMouseDragged && NSEvent.pressedMouseButtons & 1 == 0 {
            seek.doubleValue = value
        }
        time.stringValue = readableTime(value) + " / " + readableTime(media.duration.seconds)
        let subtitles = translatedCaption.isEmpty ? (subtitle?.text(at: value) ?? "") : translatedCaption
        if subtitleLabel.stringValue != subtitles { subtitleLabel.stringValue = subtitles }
        subtitleLabel.isHidden = subtitles.isEmpty
        playButton.title = wantsPlayback ? "暂停" : "播放"
    }

    private func readableTime(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func bind(_ control: NSControl, _ action: Selector) {
        control.target = self
        control.action = action
    }

    private func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        return label
    }

    private func labeled(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return vertical([label, control], spacing: 4)
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func vertical(_ views: [NSView], spacing: CGFloat, insets: NSEdgeInsets = NSEdgeInsets()) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = insets
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            let trailing = view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -stack.edgeInsets.right)
            trailing.priority = .defaultHigh
            trailing.isActive = true
        }
        return stack
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

@main
enum VeyraApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
