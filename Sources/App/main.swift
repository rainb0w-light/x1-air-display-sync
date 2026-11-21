import AppKit
import Darwin
import SwiftUI
import ServiceManagement

enum BrightnessResult: Sendable {
    case value(Int)
    case missing
    case unreadable
    case unconfirmed

    init(status: Int32, reading: BrightnessReading) {
        switch status {
        case Int32(BrightnessOK):
            self = .value(Int((Double(reading.current) / Double(reading.maximum) * 100).rounded()))
        case Int32(BrightnessMissing):
            self = .missing
        case Int32(BrightnessUnreadable):
            self = .unreadable
        default:
            self = .unconfirmed
        }
    }

    var percent: Int? {
        if case let .value(value) = self { return value }
        return nil
    }

    var label: String {
        switch self {
        case let .value(percent): "\(percent)%"
        case .missing: "未检测到显示器"
        case .unreadable: "无法读取亮度"
        case .unconfirmed: "未确认亮度变化"
        }
    }
}

enum PictureSetting: Int, CaseIterable, Identifiable, Sendable {
    case brightness, contrast, saturation, hue, colorPreset, rgb, picturePreset, dynamicContrast, eyeComfort

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .brightness: "亮度"
        case .contrast: "对比度"
        case .saturation: "饱和度"
        case .hue: "色调"
        case .colorPreset: "色温与色彩预设"
        case .rgb: "自定义 RGB"
        case .picturePreset: "画面模式"
        case .dynamicContrast: "动态对比度"
        case .eyeComfort: "护眼模式"
        }
    }

    var choices: [String] {
        switch self {
        case .colorPreset: ["9300 K", "6500 K", "sRGB", "自定义 RGB"]
        case .picturePreset: ["游戏", "电影", "网页", "阅读"]
        case .dynamicContrast, .eyeComfort: ["关", "开"]
        default: []
        }
    }

    var unit: String { self == .brightness ? "%" : "" }

    func displayValue(_ value: Int?) -> String {
        guard let value else { return "无法读取" }
        if self == .rgb {
            return RGB(value).values.map(String.init).joined(separator: " / ")
        }
        if choices.indices.contains(value) {
            return choices[value]
        }
        return "\(value)\(unit)"
    }
}

struct RGB {
    let values: [Int]

    init(_ value: Int) {
        values = [(value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff]
    }

    static func pack(_ values: [Int]) -> Int {
        (values[0] << 16) | (values[1] << 8) | values[2]
    }
}

struct PanelPairReading: Sendable {
    let upper: Int?
    let lower: Int?

    init(_ values: PanelValues) {
        upper = values.upper >= 0 ? Int(values.upper) : nil
        lower = values.lower >= 0 ? Int(values.lower) : nil
    }

    var available: Bool { upper != nil && lower != nil }
    var preferred: Int? { lower ?? upper }
}

struct PictureSnapshot: Sendable {
    let settings: [PanelPairReading]
    let status: Int32
    let upperDisplay: UInt32
    let lowerDisplay: UInt32

    var referenceDisplay: UInt32 { referenceDisplayID(upperDisplay, lowerDisplay) }

    subscript(_ setting: PictureSetting) -> PanelPairReading { settings[setting.rawValue] }
}

enum Hardware {
    static func readLeft(_ display: UInt32) -> BrightnessResult {
        var reading = BrightnessReading()
        let status = readBrightness(display, &reading)
        return BrightnessResult(status: status, reading: reading)
    }

    static func readRight() -> PictureSnapshot {
        snapshot { values, displays in readPanelSettings(values, displays) }
    }

    static func syncRight(_ setting: PictureSetting, to value: Int) -> PictureSnapshot {
        snapshot { values, displays in syncPanelSetting(Int32(setting.rawValue), Int32(value), values, displays) }
    }

    private static func snapshot(
        _ operation: (UnsafeMutablePointer<PanelValues>?, UnsafeMutablePointer<PanelDisplays>) -> Int32
    ) -> PictureSnapshot {
        var values = Array(repeating: PanelValues(), count: Int(PanelSettingCount))
        var displays = PanelDisplays()
        let status = values.withUnsafeMutableBufferPointer { operation($0.baseAddress, &displays) }
        return PictureSnapshot(
            settings: values.map(PanelPairReading.init), status: status,
            upperDisplay: displays.upper, lowerDisplay: displays.lower
        )
    }
}

@MainActor
final class BrightnessModel: ObservableObject {
    @Published var setting = PictureSetting.brightness {
        didSet {
            notice = nil
            loadTarget()
        }
    }
    @Published var target = ""
    @Published var rgbTarget = ["", "", ""]
    @Published private(set) var left: BrightnessResult?
    @Published private(set) var right: PictureSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    @Published private(set) var comparisonVisible = false
    private var comparisonWindows: [NSWindow] = []

    var reading: PanelPairReading? { right?[setting] }

    var locked: Bool {
        setting == .rgb && (right?[.colorPreset].upper != 3 || right?[.colorPreset].lower != 3)
    }

    var canApply: Bool { !busy && !locked && reading?.available == true }

    var targetValue: Int? {
        if setting == .rgb {
            let channels = rgbTarget.compactMap(percentInteger)
            return channels.count == 3 ? RGB.pack(channels) : nil
        }
        if !setting.choices.isEmpty {
            guard let value = Int(target), setting.choices.indices.contains(value) else { return nil }
            return value
        }
        return percentInteger(target)
    }

    private func percentInteger(_ text: String) -> Int? {
        let value = Int(text.trimmingCharacters(in: .whitespaces))
        return value.flatMap { (0...100).contains($0) ? $0 : nil }
    }

    private func loadTarget() {
        let value = setting == .brightness ? left?.percent ?? reading?.preferred : reading?.preferred
        if setting == .rgb {
            rgbTarget = value.map { RGB($0).values.map(String.init) } ?? ["", "", ""]
        } else {
            target = value.map(String.init) ?? ""
        }
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        notice = nil
        let (leftResult, rightResult) = await Task.detached(priority: .userInitiated) {
            let snapshot = Hardware.readRight()
            return (Hardware.readLeft(snapshot.referenceDisplay), snapshot)
        }.value
        left = leftResult
        right = rightResult
        loadTarget()
        busy = false
    }

    func apply() async {
        guard canApply, let value = targetValue else { return }
        let selected = setting
        busy = true
        notice = nil
        let result = await Task.detached(priority: .userInitiated) {
            Hardware.syncRight(selected, to: value)
        }.value
        right = result
        switch result.status {
        case Int32(BrightnessOK):
            notice = "已同步\(selected.title)至右侧双屏。"
        case Int32(PanelSettingLocked):
            notice = "先将两块屏的色彩预设切换为「自定义 RGB」。"
        case Int32(PanelPairAmbiguous):
            notice = "找到了多组 X1 Air。请只连接一组后重新读取。"
        case Int32(BrightnessMissing):
            notice = "请确认 X1 Air 的 USB-C 视频和数据连接，再重新读取。"
        default:
            notice = "两块屏未能确认同步，已显示最新读数。"
        }
        busy = false
    }

    private func screen(_ id: UInt32) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    func toggleComparison() {
        if comparisonVisible {
            hideComparison()
            return
        }

        guard let right else {
            notice = "正在读取显示器，请稍后再试。"
            return
        }
        let upper = screen(right.upperDisplay)
        let lower = screen(right.lowerDisplay)
        guard let rightScreen = lower ?? upper else {
            notice = "显示对比色块需要连接 X1 Air。"
            return
        }

        let leftFrame = screen(right.referenceDisplay)?.visibleFrame
        let rightFrame = rightScreen.frame
        let size = NSSize(width: 190, height: 140)
        let margin: CGFloat = 40
        let rightIsToTheRight = leftFrame.map { rightFrame.midX > $0.midX } ?? true
        func rightOrigin(_ frame: NSRect, centerY: CGFloat) -> NSPoint {
            let x = rightIsToTheRight ? frame.minX + margin : frame.maxX - size.width - margin
            return NSPoint(x: x, y: centerY - size.height / 2)
        }

        var origins: [NSPoint]
        if let upper, let lower, upper != lower {
            origins = [upper, lower].map { rightOrigin($0.frame, centerY: $0.frame.midY) }
        } else if rightFrame.height > rightFrame.width {
            let quarterHeight = rightFrame.height / 4
            origins = [rightFrame.midY + quarterHeight, rightFrame.midY - quarterHeight].map {
                rightOrigin(rightFrame, centerY: $0)
            }
        } else {
            origins = [rightOrigin(rightFrame, centerY: rightFrame.midY)]
        }
        if let leftFrame, let first = origins.first {
            let x = rightIsToTheRight ? leftFrame.maxX - size.width - margin : leftFrame.minX + margin
            let y = min(max(first.y, leftFrame.minY + margin), leftFrame.maxY - size.height - margin)
            origins.append(NSPoint(x: x, y: y))
        }

        for origin in origins {
            let panel = NSPanel(
                contentRect: NSRect(origin: origin, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.contentView = ComparisonSwatch(frame: NSRect(origin: .zero, size: size))
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.setFrameOrigin(origin)
            panel.orderFrontRegardless()
            comparisonWindows.append(panel)
        }
        comparisonVisible = true
    }

    func hideComparison() {
        comparisonWindows.forEach { $0.orderOut(nil) }
        comparisonWindows.removeAll()
        comparisonVisible = false
    }
}

final class ComparisonSwatch: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let grayLevels: [CGFloat] = [0.08, 0.25, 0.5, 0.75, 0.94]
        let grayHeight = bounds.height * 0.67
        let grayWidth = bounds.width / CGFloat(grayLevels.count)
        for (index, level) in grayLevels.enumerated() {
            NSColor(srgbRed: level, green: level, blue: level, alpha: 1).setFill()
            NSRect(x: CGFloat(index) * grayWidth, y: bounds.height - grayHeight,
                   width: grayWidth, height: grayHeight).fill()
        }

        let colors: [NSColor] = [
            NSColor(srgbRed: 0.76, green: 0.24, blue: 0.25, alpha: 1),
            NSColor(srgbRed: 0.29, green: 0.65, blue: 0.35, alpha: 1),
            NSColor(srgbRed: 0.29, green: 0.44, blue: 0.78, alpha: 1)
        ]
        let width = bounds.width / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height - grayHeight).fill()
        }
    }
}

struct BrightnessView: View {
    @StateObject private var model = BrightnessModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Picker("调节项目", selection: $model.setting) {
                    ForEach(PictureSetting.allCases) { setting in
                        Text(setting.title).tag(setting)
                    }
                }
                .frame(width: 262)
                .disabled(model.busy)
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新读取显示器设置")
                .accessibilityLabel("重新读取显示器设置")
                .disabled(model.busy)
            }

            HStack(spacing: 16) {
                if model.setting == .brightness {
                    displayReading("参考屏", value: model.left?.label)
                    Divider().frame(height: 42)
                }
                displayReading("右上屏", value: panelLabel(model.reading?.upper))
                displayReading("右下屏", value: panelLabel(model.reading?.lower))
            }
            .padding(14)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 9) {
                if model.setting == .rgb {
                    ForEach(0..<3) { index in
                        valueSlider(
                            title: ["红", "绿", "蓝"][index],
                            target: $model.rgbTarget[index],
                            unit: ""
                        )
                    }
                } else if !model.setting.choices.isEmpty {
                    Picker("目标值", selection: Binding(
                        get: { Int(model.target) ?? -1 },
                        set: { model.target = String($0); apply() }
                    )) {
                        if model.target.isEmpty || model.reading?.upper != model.reading?.lower {
                            Text("请选择").tag(-1)
                        }
                        ForEach(Array(model.setting.choices.enumerated()), id: \.offset) { index, title in
                            Text(title).tag(index)
                        }
                    }
                } else {
                    valueSlider(title: "目标\(model.setting.title)", target: $model.target, unit: model.setting.unit)
                }
            }
            .disabled(!model.canApply)

            HStack {
                Button(model.comparisonVisible ? "关闭对比色块" : "显示对比色块") {
                    model.toggleComparison()
                }
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small)
                }
                Button("同步右侧双屏", action: apply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canApply || model.targetValue == nil)
            }

            if let message = model.notice ?? settingHelp {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(width: 465)
        .task { await model.refresh() }
        .onDisappear { model.hideComparison() }
    }

    private func apply() {
        Task { await model.apply() }
    }

    private var settingHelp: String? {
        guard let right = model.right else { return nil }
        if right.status == Int32(PanelPairAmbiguous) {
            return "找到了多组 X1 Air。请只连接一组后重新读取。"
        }
        if right.status == Int32(BrightnessMissing) || model.reading?.available != true {
            return "无法读取两块屏的设置。请确认 USB-C 视频和数据连接后重新读取。"
        }
        if model.locked {
            return "先在「色温与色彩预设」里选择「自定义 RGB」。"
        }
        if model.setting == .brightness && model.left?.percent == nil {
            return "可输入参考屏机身菜单里的亮度，或用色块对照微调。"
        }
        return model.setting.choices.isEmpty ? "拖动滑块后松手，或输入数值后按回车，即可同步两块屏。" : nil
    }

    private func valueSlider(title: String, target: Binding<String>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                TextField("0–100", text: target)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 57)
                    .onSubmit(apply)
                if !unit.isEmpty {
                    Text(unit).foregroundStyle(.secondary)
                }
            }
            Slider(value: Binding(
                get: { Double(Int(target.wrappedValue) ?? 0) },
                set: { target.wrappedValue = String(Int($0.rounded())) }
            ), in: 0...100) { editing in
                if !editing { apply() }
            }
            .accessibilityLabel(title)
        }
    }

    private func panelLabel(_ value: Int?) -> String? {
        model.right == nil ? nil : model.setting.displayValue(value)
    }

    private func displayReading(_ title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "正在读取…")
                .font(.headline)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func report(_ snapshot: PictureSnapshot, setting: PictureSetting) {
    let reading = snapshot[setting]
    print("\(setting.title) 右上 \(setting.displayValue(reading.upper)) · 右下 \(setting.displayValue(reading.lower))")
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--status":
    let snapshot = Hardware.readRight()
    print("参考屏 \(Hardware.readLeft(snapshot.referenceDisplay).label)")
    PictureSetting.allCases.forEach { report(snapshot, setting: $0) }
case "--set-right":
    guard arguments.count == 2, let percent = Int(arguments[1]), (0...100).contains(percent) else {
        fputs("请输入 0 到 100 的整数。\n", stderr)
        exit(2)
    }
    let result = Hardware.syncRight(.brightness, to: percent)
    report(result, setting: .brightness)
    exit(result.status == Int32(BrightnessOK) ? 0 : 1)
case "--login-status":
    print(LoginItem.statusLabel)
case "--enable-login", "--disable-login":
    do {
        if arguments[0] == "--enable-login" {
            try LoginItem.enable()
        } else {
            try LoginItem.disable()
        }
        print(LoginItem.statusLabel)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
default:
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = DisplaySyncAppDelegate(showOnLaunch: arguments.contains("--show-panel"))
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
