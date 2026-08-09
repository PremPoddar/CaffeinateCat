import Cocoa

// Design tokens in one place, so the panel views hold no colours of their own.
// Nothing here has behaviour.

extension NSColor {
    // The design specifies colours in OKLCH; these are the sRGB conversions.
    static func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}

struct Palette {
    let accent: NSColor
    let text: NSColor
    let subtext: NSColor
    let panelBackground: NSColor
    let panelBorder: NSColor
    let divider: NSColor
    let segmentBackground: NSColor
    let switchOffTrack: NSColor
    let fieldBackground: NSColor
    let fieldBorder: NSColor

    static let light = Palette(
        accent: .srgb(0x127EEE),
        text: .srgb(0x171614),
        subtext: .srgb(0x5F5D5A),
        panelBackground: .srgb(0xF9F8F7, alpha: 0.92),
        panelBorder: NSColor.black.withAlphaComponent(0.06),
        divider: NSColor.black.withAlphaComponent(0.08),
        segmentBackground: .srgb(0xE2E1E0),
        switchOffTrack: .srgb(0xCECECC),
        fieldBackground: NSColor.white,
        fieldBorder: NSColor.black.withAlphaComponent(0.15)
    )

    static let dark = Palette(
        accent: .srgb(0x127EEE),
        text: .srgb(0xF2F2F0),
        subtext: .srgb(0xA6A4A1),
        panelBackground: .srgb(0x272624, alpha: 0.92),
        panelBorder: NSColor.white.withAlphaComponent(0.08),
        divider: NSColor.white.withAlphaComponent(0.09),
        segmentBackground: .srgb(0x171614),
        switchOffTrack: .srgb(0x484845),
        fieldBackground: NSColor.white.withAlphaComponent(0.06),
        fieldBorder: NSColor.white.withAlphaComponent(0.15)
    )

    static var current: Palette {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

enum Typography {
    static let rowTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let rowSubtitle = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let segment = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    static let segmentSelected = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let customField = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let countdown = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    static let quit = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let quitShortcut = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let menuBar = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
}

enum Metrics {
    static let panelWidth: CGFloat = 320
    /// Roughly NSPopover's own radius. The popover clips our content to its shape anyway, so
    /// erring small here is safe — too large would expose the popover's material at the corners.
    static let panelCornerRadius: CGFloat = 10
    static let panelVerticalPadding: CGFloat = 6

    static let rowHorizontalPadding: CGFloat = 16
    static let rowVerticalPadding: CGFloat = 10
    static let titleHeight: CGFloat = 16
    static let subtitleGap: CGFloat = 2
    static let subtitleHeight: CGFloat = 14
    static let headerToggleGap: CGFloat = 12
    static let sectionGap: CGFloat = 12   // header -> segmented control
    static let controlGap: CGFloat = 8    // segmented -> custom fields -> countdown

    static let switchWidth: CGFloat = 38
    static let switchHeight: CGFloat = 22
    static let switchThumb: CGFloat = 18
    static let switchInset: CGFloat = 2
    static let switchOnX: CGFloat = 18

    static let segmentedHeight: CGFloat = 28
    static let segmentedRadius: CGFloat = 7
    static let segmentedPadding: CGFloat = 2
    static let segmentGap: CGFloat = 2
    static let segmentRadius: CGFloat = 6

    static let customFieldWidth: CGFloat = 44
    static let customFieldHeight: CGFloat = 22
    static let customFieldRadius: CGFloat = 5
    static let customGap: CGFloat = 5
    static let customUnitWidth: CGFloat = 14
    static let stepperWidth: CGFloat = 13
    static let stepperGap: CGFloat = 3   // field -> its stepper
    static let customPairGap: CGFloat = 12  // "h" group -> "m" group

    static let countdownHeight: CGFloat = 14

    static let dividerHeight: CGFloat = 1
    static let dividerMargin: CGFloat = 2

    static let quitRowHeight: CGFloat = 26

    /// Header block: title, 2pt gap, subtitle.
    static var headerHeight: CGFloat { titleHeight + subtitleGap + subtitleHeight }
}

/// Views that cache palette colours outside `draw(_:)` (layers, text field colours) adopt this so
/// `PanelView` can push a new palette through the whole tree when the system appearance flips.
protocol PaletteAware: AnyObject {
    func applyPalette()
}

enum Labels {
    static func make(_ string: String, font: NSFont, alignment: NSTextAlignment = .left) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = font
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}

/// A countdown rendering whose width is fixed by the run's *initial* total rather than by whatever
/// is left. The design formats as `H:MM:SS` / `M:SS`, which changes length as it counts down —
/// "10:00" to "9:59" loses a character, and every such change resizes the menu bar item and shoves
/// everything anchored to it sideways. Fixing the field widths up front keeps the text one constant
/// size for the entire run, at the cost of a leading zero on short timers.
struct CountdownFormat {
    /// Digits reserved for the hours field; 0 means the run is under an hour and shows none.
    private let hourDigits: Int

    init(total: Int) {
        let hours = max(0, total) / 3600
        hourDigits = hours > 0 ? String(hours).count : 0
    }

    func string(_ remaining: Int) -> String {
        let remaining = max(0, remaining)
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60
        if hourDigits > 0 {
            return String(format: "%0\(hourDigits)d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
