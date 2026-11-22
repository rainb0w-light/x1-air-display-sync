import ColorSync
import CoreGraphics
import Darwin
import Foundation

enum DisplayRecovery {
    struct Target: Equatable, Sendable {
        let id: CGDirectDisplayID
        let uuid: String
        let main: CGDirectDisplayID
    }

    enum Failure: LocalizedError {
        case targetChanged, configurationFailed, extensionUnconfirmed

        var errorDescription: String? {
            switch self {
            case .targetChanged: "显示器状态已变化，请重新打开菜单。"
            case .configurationFailed: "macOS 未接受右屏恢复请求。"
            case .extensionUnconfirmed: "未能确认右屏已作为扩展显示器上线。"
            }
        }
    }

    private struct DesktopMode: Codable {
        let width: Int
        let height: Int
        let refreshRate: Double

        init(_ mode: CGDisplayMode) {
            width = mode.width
            height = mode.height
            refreshRate = mode.refreshRate
        }

        func matches(_ mode: CGDisplayMode) -> Bool {
            mode.width == width && mode.height == height &&
                abs(mode.refreshRate - refreshRate) < 0.1 && isSequenceMode(mode)
        }
    }

    private typealias ConfigureIndependentOutput = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32

    // Resolve the private API at runtime. The brightness controls also run on systems where it is absent.
    private static let configureIndependentOutput: ConfigureIndependentOutput? = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let library = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(library, "SLSConfigureDisplayIndependentOutput") else { return nil }
        return unsafeBitCast(symbol, to: ConfigureIndependentOutput.self)
    }()

    static func target() -> Target? {
        guard configureIndependentOutput != nil else { return nil }
        let url = URL(filePath: "/Library/Preferences/com.apple.windowserver.displays.plist")
        guard let data = try? Data(contentsOf: url),
              let preferences = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let store = (preferences["DisplayAnyUserSets"] ?? preferences["DisplaySets"]) as? [String: Any],
              let configs = store["Configs"] as? [[String: Any]],
              let displays = configs.first?["DisplayConfig"] as? [[String: Any]] else { return nil }

        let main = CGMainDisplayID()
        guard main != 0, let mainUUID = uuid(for: main),
              displays.contains(where: { $0["UUID"] as? String == mainUUID }) else { return nil }

        let candidates: [Target] = displays.compactMap { record in
            guard record["IndependentOutput"] as? Bool == true,
                  let uuid = record["UUID"] as? String,
                  let cfUUID = CFUUIDCreateFromString(nil, uuid as CFString) else { return nil }
            let id = CGDisplayGetDisplayIDFromUUID(cfUUID)
            guard id != 0, id != main, CGDisplayIsOnline(id) == 0, CGDisplayIsActive(id) == 0,
                  CGDisplayVendorNumber(id) == 0x312b,
                  let mode = CGDisplayCopyDisplayMode(id), isSequenceMode(mode) else { return nil }
            return Target(id: id, uuid: uuid, main: main)
        }

        guard !candidates.isEmpty else { return nil }
        var serials = PanelSerials()
        guard readPanelSerials(&serials) == Int32(BrightnessOK) else { return nil }
        let matched = candidates.filter { candidate in
            let serial = CGDisplaySerialNumber(candidate.id)
            return serial == serials.upper || serial == serials.lower
        }
        return matched.count == 1 ? matched.first : nil
    }

    static func rememberDesktopModes() {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return }
        for id in displays.prefix(Int(count)) where CGDisplayVendorNumber(id) == 0x312b && CGDisplayIsInMirrorSet(id) == 0 {
            guard let uuid = uuid(for: id), let mode = CGDisplayCopyDisplayMode(id), isSequenceMode(mode),
                  let data = try? PropertyListEncoder().encode(DesktopMode(mode)) else { continue }
            UserDefaults.standard.set(data, forKey: modeKey(uuid))
        }
    }

    // False means the desktop is back and macOS chose a different scale than the remembered mode.
    static func restore(_ target: Target) async throws -> Bool {
        guard self.target() == target, let configureIndependentOutput else { throw Failure.targetChanged }
        try configure { configuration in
            CGMainDisplayID() == target.main && uuid(for: target.id) == target.uuid &&
                CGDisplayIsOnline(target.id) == 0 && configureIndependentOutput(configuration, target.id, false) == 0
        }

        for _ in 0..<20 {
            if extensionIsActive(target) {
                return restoreDesktopMode(target)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.extensionUnconfirmed
    }

    private static func restoreDesktopMode(_ target: Target) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: modeKey(target.uuid)),
              let saved = try? PropertyListDecoder().decode(DesktopMode.self, from: data) else { return true }
        if let current = CGDisplayCopyDisplayMode(target.id), saved.matches(current) { return true }

        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(target.id, options) as? [CGDisplayMode],
              let mode = modes.first(where: saved.matches), extensionIsActive(target) else { return false }
        do {
            try configure { CGConfigureDisplayWithDisplayMode($0, target.id, mode, nil) == .success }
        } catch {
            return false
        }
        return CGDisplayCopyDisplayMode(target.id).map(saved.matches) == true
    }

    private static func configure(_ change: (CGDisplayConfigRef) -> Bool) throws {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            throw Failure.configurationFailed
        }
        guard change(configuration) else {
            CGCancelDisplayConfiguration(configuration)
            throw Failure.configurationFailed
        }
        guard CGCompleteDisplayConfiguration(configuration, .permanently) == .success else {
            throw Failure.configurationFailed
        }
    }

    private static func extensionIsActive(_ target: Target) -> Bool {
        CGMainDisplayID() == target.main && CGDisplayIsOnline(target.id) != 0 &&
            CGDisplayIsActive(target.id) != 0 && CGDisplayIsInMirrorSet(target.id) == 0 &&
            uuid(for: target.id) == target.uuid
    }

    private static func uuid(for id: CGDirectDisplayID) -> String? {
        CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
    }

    private static func isSequenceMode(_ mode: CGDisplayMode) -> Bool {
        mode.pixelWidth == 2520 && mode.pixelHeight == 3360
    }

    private static func modeKey(_ uuid: String) -> String {
        "x1AirDesktopMode.\(uuid)"
    }
}
