import AppKit
import Observation
import SwiftUI

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark, custom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        case .custom: "slider.horizontal.3"
        }
    }
}

enum AppearanceBase: String, Codable, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum RowDensity: String, Codable, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var padding: CGFloat { self == .compact ? 4 : 8 }
}

enum SettingsTab: String, Hashable {
    case general, appearance, mediaTools, chrome
}

private struct AppearancePreferences: Codable {
    var mode: AppearanceMode = .system
    var customBase: AppearanceBase = .dark
    var accentHex = "008653"
    var backgroundHex = "151A1E"
    var fontFamily = "System"
    var fontSize: Double = 14
    var density: RowDensity = .comfortable
}

@MainActor @Observable
final class AppearanceStore {
    /// AppKit may rehost table cells or empty-state content outside a scene's
    /// environment during filtering. Keep their appearance dependency stable.
    static let shared = AppearanceStore()
    private static let storageKey = "HarborAppearance.v1"
    private var preferences: AppearancePreferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
        }
    }
    var settingsTab: SettingsTab = .general
    let fontFamilies: [String]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           var decoded = try? JSONDecoder().decode(AppearancePreferences.self, from: data) {
            decoded.fontSize = decoded.fontSize.isFinite ? min(18, max(11, decoded.fontSize)) : 14
            preferences = decoded
        } else { preferences = AppearancePreferences() }
        fontFamilies = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if preferences.fontFamily != "System", !fontFamilies.contains(preferences.fontFamily) { preferences.fontFamily = "System" }
    }

    var mode: AppearanceMode {
        get { preferences.mode }
        set { preferences.mode = newValue }
    }
    var customBase: AppearanceBase {
        get { preferences.customBase }
        set { preferences.customBase = newValue }
    }
    var fontFamily: String {
        get { preferences.fontFamily }
        set { preferences.fontFamily = newValue }
    }
    var fontSize: Double {
        get { preferences.fontSize }
        set { preferences.fontSize = min(18, max(11, newValue)) }
    }
    var density: RowDensity {
        get { preferences.density }
        set { preferences.density = newValue }
    }
    var customAccent: Color {
        get { Color(nsColor: RGB(hex: preferences.accentHex).nsColor) }
        set { preferences.accentHex = RGB(color: NSColor(newValue)).hex }
    }
    var customBackground: Color {
        get { Color(nsColor: RGB(hex: preferences.backgroundHex).nsColor) }
        set { preferences.backgroundHex = RGB(color: NSColor(newValue)).hex }
    }
    var isCustom: Bool { mode == .custom }
    var colorScheme: ColorScheme? {
        switch mode {
        case .system: nil
        case .light: .light
        case .dark: .dark
        case .custom: customBase == .dark ? .dark : .light
        }
    }

    private var resolvedBackground: RGB {
        var color = RGB(hex: preferences.backgroundHex)
        // Keep native primary/secondary text readable on every user-selected hue.
        let target = customBase == .dark ? RGB.black : RGB.white
        for _ in 0..<80 {
            if customBase == .dark ? color.luminance <= 0.055 : color.luminance >= 0.78 { break }
            color = color.blended(with: target, amount: 0.08)
        }
        return color
    }
    // NSColor's provider resolves against the hosting window's actual appearance.
    // In System mode these colors therefore update along with macOS, including
    // table/toolbar content hosted outside the main SwiftUI scene.
    private func adaptive(light: String, dark: String) -> Color {
        let lightColor = RGB(hex: light).nsColor
        let darkColor = RGB(hex: dark).nsColor
        let forcedDark: Bool? = colorScheme.map { $0 == .dark }
        return Color(nsColor: NSColor(name: nil) { nativeAppearance in
            let isDark = forcedDark ?? (nativeAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            return isDark ? darkColor : lightColor
        })
    }
    private func customSurface(lightAmount: Double, darkAmount: Double) -> Color {
        Color(nsColor: resolvedBackground.blended(with: customBase == .dark ? .white : .black,
                                                 amount: customBase == .dark ? darkAmount : lightAmount).nsColor)
    }
    var backgroundColor: Color {
        isCustom ? Color(nsColor: resolvedBackground.nsColor) : adaptive(light: "FCFDFD", dark: "151A1E")
    }
    var surfaceColor: Color {
        guard isCustom else { return adaptive(light: "FFFFFF", dark: "1B2227") }
        return customSurface(lightAmount: 0.012, darkAmount: 0.035)
    }
    var sidebarColor: Color {
        guard isCustom else { return adaptive(light: "EFF2F3", dark: "1D2429") }
        return customSurface(lightAmount: 0.035, darkAmount: 0.055)
    }
    var separatorColor: Color {
        guard isCustom else { return adaptive(light: "E0E5E8", dark: "333D44") }
        return customSurface(lightAmount: 0.13, darkAmount: 0.15)
    }
    var fieldColor: Color {
        guard isCustom else { return adaptive(light: "FFFFFF", dark: "20282E") }
        return customSurface(lightAmount: 0, darkAmount: 0.055)
    }
    var hoverColor: Color {
        guard isCustom else { return adaptive(light: "F0F5F3", dark: "222E2A") }
        return customSurface(lightAmount: 0.035, darkAmount: 0.065)
    }
    var selectionColor: Color {
        guard isCustom else { return adaptive(light: "E0F0E9", dark: "244436") }
        return Color(nsColor: resolvedBackground.blended(with: resolvedAccent, amount: customBase == .dark ? 0.20 : 0.12).nsColor)
    }
    var mutedTextColor: Color {
        guard isCustom else { return adaptive(light: "64717A", dark: "A7B3BA") }
        var muted = RGB(hex: customBase == .dark ? "A7B3BA" : "64717A")
        let target = customBase == .dark ? RGB.white : RGB.black
        for _ in 0..<80 {
            if muted.contrast(with: resolvedBackground) >= 4.5 { break }
            muted = muted.blended(with: target, amount: 0.08)
        }
        return Color(nsColor: muted.nsColor)
    }
    private var resolvedAccent: RGB {
        var accent = RGB(hex: preferences.accentHex)
        let target = customBase == .dark ? RGB.white : RGB.black
        for _ in 0..<80 {
            if accent.contrast(with: resolvedBackground) >= 4.5 { break }
            accent = accent.blended(with: target, amount: 0.08)
        }
        return accent
    }
    var tintColor: Color {
        isCustom ? Color(nsColor: resolvedAccent.nsColor) : adaptive(light: "008653", dark: "54DDA6")
    }
    /// Text/icon ink for solid accent buttons, including the brighter dark accent.
    var onTintColor: Color {
        guard isCustom else { return adaptive(light: "FFFFFF", dark: "0A2E20") }
        return Color(nsColor: (resolvedAccent.contrast(with: .white) >= resolvedAccent.contrast(with: .black) ? RGB.white : RGB.black).nsColor)
    }

    func font(_ style: HarborTextStyle, weight: Font.Weight? = nil, monospacedDigits: Bool = false) -> Font {
        let pointSize = style.size(base: fontSize)
        let chosenWeight = weight ?? style.weight
        var font: Font
        if fontFamily == "System" {
            font = .system(size: pointSize, weight: chosenWeight)
        } else if let native = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: pointSize) {
            font = Font(native).weight(chosenWeight)
        } else { font = .system(size: pointSize, weight: chosenWeight) }
        if monospacedDigits { font = font.monospacedDigit() }
        return font
    }

    func reset() { preferences = AppearancePreferences() }
}

enum HarborTextStyle {
    case body, callout, caption, headline, subheadline, title, title2, largeTitle
    func size(base: Double) -> Double {
        switch self {
        case .body, .headline, .subheadline: base
        case .callout: max(11, base - 1)
        case .caption: max(10, base - 2)
        case .title: base + 12
        case .title2: base + 5
        case .largeTitle: base + 18
        }
    }
    var weight: Font.Weight { [.headline, .title, .title2, .largeTitle].contains(self) ? .semibold : .regular }
}

@propertyWrapper @MainActor
struct AppAppearance: DynamicProperty {
    @Environment(AppearanceStore.self) private var injected: AppearanceStore?
    var wrappedValue: AppearanceStore { injected ?? AppearanceStore.shared }
}

private struct HarborFontModifier: ViewModifier {
    @AppAppearance private var appearance
    let style: HarborTextStyle
    let weight: Font.Weight?
    let monospacedDigits: Bool
    func body(content: Content) -> some View {
        content.font(appearance.font(style, weight: weight, monospacedDigits: monospacedDigits))
    }
}

struct HarborAppearanceModifier: ViewModifier {
    @AppAppearance private var appearance
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(appearance.colorScheme)
            .tint(appearance.tintColor)
            .accentColor(appearance.tintColor)
            .font(appearance.font(.body))
            .background(appearance.backgroundColor)
    }
}

struct HarborToolbarAppearanceModifier: ViewModifier {
    @AppAppearance private var appearance
    func body(content: Content) -> some View {
        content
            .toolbarBackground(appearance.backgroundColor, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
    }
}

extension View {
    /// Apply at every AppKit hosting/presentation boundary, not only the scene.
    func harborEnvironment(store: DownloadStore, appearance: AppearanceStore) -> some View {
        modifier(HarborAppearanceModifier())
            .environment(appearance)
            .environment(store)
    }

    func harborFont(_ style: HarborTextStyle, weight: Font.Weight? = nil, monospacedDigits: Bool = false) -> some View {
        modifier(HarborFontModifier(style: style, weight: weight, monospacedDigits: monospacedDigits))
    }
}

private struct RGB {
    var red: Double
    var green: Double
    var blue: Double
    static let black = RGB(red: 0, green: 0, blue: 0)
    static let white = RGB(red: 1, green: 1, blue: 1)
    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0x008653
        red = Double((value >> 16) & 255) / 255
        green = Double((value >> 8) & 255) / 255
        blue = Double(value & 255) / 255
    }
    init(color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .systemBlue
        red = min(1, max(0, rgb.redComponent))
        green = min(1, max(0, rgb.greenComponent))
        blue = min(1, max(0, rgb.blueComponent))
    }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    var hex: String { String(format: "%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255)) }
    var luminance: Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return linear(red) * 0.2126 + linear(green) * 0.7152 + linear(blue) * 0.0722
    }
    func contrast(with other: RGB) -> Double { (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05) }
    func blended(with other: RGB, amount: Double) -> RGB {
        RGB(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount, blue: blue + (other.blue - blue) * amount)
    }
}
