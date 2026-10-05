import AppKit
import SwiftUI

// Adapted from pitch.dog Studio (StudioKit/Theme.swift and Typography.swift in
// bomkino/pitchdog-drift), AGPL-3.0. See NOTICES.md.

/// Planes, ink, spacing, radii and motion. The interface stays neutral grey so
/// the slide carries all the colour. One warm colour belongs to the camera:
/// its framings on the slide map, its moves on the timeline, the playhead.
public enum Theme {
    // MARK: Planes

    /// Around the output frame. Neutral by rule (R = G = B) so the slide's colour reads true.
    public static let surround = Color(nsColor: .studio(light: 0xE2E2E4, dark: 0x0B0B0C))
    /// Inspector, timeline and transport.
    public static let chrome = Color(nsColor: .studio(light: 0xF5F5F6, dark: 0x151516))
    /// Popovers, tiles and cards.
    public static let raised = Color(nsColor: .studio(light: 0xFFFFFF, dark: 0x1F1F21))
    /// Recessed wells such as slider tracks and fields.
    public static let well = Color(nsColor: .studio(light: 0xE6E6E9, dark: 0x2A2A2D))
    /// The selected segment in a choice row: lifts off its track in both appearances.
    public static let segmentOn = Color(nsColor: .studio(light: 0xFFFFFF, dark: 0x45454A))
    public static let hairline = Color(nsColor: .studioAlpha(light: 0x000000, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.08))

    // MARK: Emphasis

    /// Slider fills and the one prominent button: the interface's own ink.
    public static let accent = Color(nsColor: .studio(light: 0x1C1C1E, dark: 0xF4F4F5))
    public static let accentSoft = Color(nsColor: .studioAlpha(light: 0x000000, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.09))
    /// Text and glyphs set on `accent`.
    public static let onAccent = Color(nsColor: .studio(light: 0xFFFFFF, dark: 0x111112))
    /// The camera's colour: a warm ember, the same one the sample slide marks its detail with.
    public static let camera = Color(nsColor: .studio(light: 0xE5482A, dark: 0xFF6A45))
    public static let cameraSoft = Color(nsColor: .studioAlpha(light: 0xE5482A, lightAlpha: 0.16, dark: 0xFF6A45, darkAlpha: 0.2))
    /// The voice's colour on the timeline: a quiet cool grey-blue, never louder than the camera.
    public static let voice = Color(nsColor: .studio(light: 0x5B6B82, dark: 0x93A4BD))

    // MARK: Space (4 pt grid)

    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
        public static let xxxl: CGFloat = 32
    }

    // MARK: Radii

    public enum Radius {
        public static let thumb: CGFloat = 5
        public static let control: CGFloat = 7
        public static let tile: CGFloat = 10
        public static let stage: CGFloat = 6
    }

    // MARK: Motion

    public static let spring = Animation.spring(response: 0.28, dampingFraction: 1)
    public static let quick = Animation.easeOut(duration: 0.12)
    public static let settle = Animation.spring(response: 0.42, dampingFraction: 0.92)
}

extension NSColor {
    public convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }

    public static func studio(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in NSColor(hex: isDark(appearance) ? dark : light) }
    }

    public static func studioAlpha(light: UInt32, lightAlpha: CGFloat, dark: UInt32, darkAlpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            isDark(appearance) ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        }
    }
}

/// The person's appearance preference. OOO opens in the dark screening room
/// unless asked otherwise.
public enum AppearanceChoice: String, CaseIterable, Identifiable {
    case dark, light, system
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "Match System"
        }
    }
    public var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

// MARK: - Type

/// Interface text roles, set in the system font so OOO reads as a native Mac
/// app: sizes follow the macOS inspector scale and numbers use tabular figures.
public enum TextRole: String, CaseIterable, Sendable {
    case display, title, label, body, bodyCompact, caption, badge, data, mono
}

public struct TextRoleSpec: Sendable {
    public var size: CGFloat
    public var weight: Font.Weight
    public var design: Font.Design = .default
    public var tracking: CGFloat = 0
    public var uppercase = false
    public var monospacedDigits = false
}

public enum StudioType {
    public static func spec(_ role: TextRole) -> TextRoleSpec {
        switch role {
        case .display: return TextRoleSpec(size: 26, weight: .semibold, tracking: -0.4)
        case .title: return TextRoleSpec(size: 15, weight: .semibold, tracking: -0.1)
        case .label: return TextRoleSpec(size: 12, weight: .semibold)
        case .body: return TextRoleSpec(size: 13, weight: .regular)
        case .bodyCompact: return TextRoleSpec(size: 12, weight: .regular)
        case .caption: return TextRoleSpec(size: 11.5, weight: .regular)
        case .badge: return TextRoleSpec(size: 9.5, weight: .semibold, tracking: 0.5, uppercase: true)
        case .data: return TextRoleSpec(size: 11.5, weight: .medium, monospacedDigits: true)
        case .mono: return TextRoleSpec(size: 11, weight: .regular, design: .monospaced)
        }
    }

    public static func font(_ role: TextRole, size: CGFloat? = nil) -> Font {
        let s = spec(role)
        let f = Font.system(size: size ?? s.size, weight: s.weight, design: s.design)
        return s.monospacedDigits ? f.monospacedDigit() : f
    }
}

public struct StudioTextStyle: ViewModifier {
    let role: TextRole
    let size: CGFloat?

    public func body(content: Content) -> some View {
        let s = StudioType.spec(role)
        return content
            .font(StudioType.font(role, size: size))
            .tracking(s.tracking)
            .textCase(s.uppercase ? .uppercase : nil)
    }
}

extension View {
    /// Applies an interface text role.
    public func textStyle(_ role: TextRole, size: CGFloat? = nil) -> some View {
        modifier(StudioTextStyle(role: role, size: size))
    }
}

/// Seconds as the interface shows them: 6.6 s, or 1:04.2 past a minute.
public func secondsLabel(_ t: Double) -> String {
    if t < 60 { return String(format: "%.1f s", t) }
    let m = Int(t) / 60
    return String(format: "%d:%04.1f", m, t - Double(m * 60))
}
