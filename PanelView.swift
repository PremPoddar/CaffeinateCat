import Cocoa

// The panel's contents, and the value type + delegate that connect it to the app.
//
// The views hold no app state: `AppDelegate` pushes a `PanelState` down, the views report intent
// back up through `PanelViewDelegate`, and `AppDelegate` pushes a fresh state in response. Nothing
// in here knows about pmset, assertions, or timers.

enum Feature {
    case caffeinate
    case lid
}

enum AwakeDuration: Equatable {
    case indefinite
    case minutes(Int)
    case custom
}

struct PanelState {
    var caffeinateOn = false
    var lidOn = false
    var caffeinateDuration: AwakeDuration = .indefinite
    var lidDuration: AwakeDuration = .indefinite
    var caffeinateCustomHours = 1
    var caffeinateCustomMinutes = 0
    var lidCustomHours = 1
    var lidCustomMinutes = 0
    // Preformatted by AppDelegate, which owns the run's fixed-width CountdownFormat. Empty when the
    // feature is off or indefinite.
    var caffeinateCountdown = ""
    var lidCountdown = ""
}

protocol PanelViewDelegate: AnyObject {
    func panelDidToggle(_ feature: Feature, on: Bool)
    func panelDidSelectDuration(_ feature: Feature, _ duration: AwakeDuration)
    func panelDidEditCustom(_ feature: Feature, hours: Int, minutes: Int)
    func panelDidRequestQuit()
}

// MARK: - Feature row

/// Title + subtitle + switch, with the duration controls revealed underneath when the switch is on.
final class FeatureRowView: NSView {
    weak var delegate: PanelViewDelegate?

    private static let durations: [AwakeDuration] = [.indefinite, .minutes(15), .minutes(30), .minutes(60), .custom]
    private static let durationTitles = ["Indefinite", "15m", "30m", "1h", "Custom"]

    private let feature: Feature
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let toggle = ToggleSwitch()
    private let segmented = SegmentedControl(titles: FeatureRowView.durationTitles)
    private let customRow = DurationFieldRow()
    private let countdownLabel = Labels.make("", font: Typography.countdown)

    private var isOn = false
    private var duration: AwakeDuration = .indefinite

    override var isFlipped: Bool { true }

    init(feature: Feature, title: String, subtitle: String) {
        self.feature = feature
        titleLabel = Labels.make(title, font: Typography.rowTitle)
        subtitleLabel = Labels.make(subtitle, font: Typography.rowSubtitle)
        super.init(frame: .zero)

        for view in [titleLabel, subtitleLabel, toggle, segmented, customRow, countdownLabel] as [NSView] {
            addSubview(view)
        }

        toggle.onToggle = { [weak self] on in
            guard let self else { return }
            self.delegate?.panelDidToggle(self.feature, on: on)
        }
        segmented.onSelect = { [weak self] index in
            guard let self else { return }
            self.delegate?.panelDidSelectDuration(self.feature, Self.durations[index])
        }
        customRow.onChange = { [weak self] hours, minutes in
            guard let self else { return }
            self.delegate?.panelDidEditCustom(self.feature, hours: hours, minutes: minutes)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var showsDurations: Bool { isOn }
    private var showsCustomFields: Bool { isOn && duration == .custom }
    private var showsCountdown: Bool { isOn && duration != .indefinite }

    func apply(on: Bool, duration: AwakeDuration, customHours: Int, customMinutes: Int, countdown: String) {
        isOn = on
        self.duration = duration

        toggle.set(on, animated: true)
        if let index = Self.durations.firstIndex(of: duration) {
            segmented.select(index)
        }
        customRow.set(hours: customHours, minutes: customMinutes)
        countdownLabel.stringValue = "Awake — \(countdown) left"

        segmented.isHidden = !showsDurations
        customRow.isHidden = !showsCustomFields
        countdownLabel.isHidden = !showsCountdown

        needsLayout = true
    }

    /// Pure: used both to lay out this row and to size the panel.
    var fittingHeight: CGFloat {
        var height = Metrics.rowVerticalPadding * 2 + Metrics.headerHeight
        if showsDurations {
            height += Metrics.sectionGap + Metrics.segmentedHeight
            if showsCustomFields {
                height += Metrics.controlGap + Metrics.customFieldHeight
            }
            if showsCountdown {
                height += Metrics.controlGap + Metrics.countdownHeight
            }
        }
        return height
    }

    override func layout() {
        super.layout()

        let palette = Palette.current
        titleLabel.textColor = palette.text
        subtitleLabel.textColor = palette.subtext
        countdownLabel.textColor = palette.accent

        let pad = Metrics.rowHorizontalPadding
        let textWidth = bounds.width - pad * 2 - Metrics.switchWidth - Metrics.headerToggleGap
        var y = Metrics.rowVerticalPadding

        titleLabel.frame = NSRect(x: pad, y: y, width: textWidth, height: Metrics.titleHeight)
        subtitleLabel.frame = NSRect(x: pad,
                                     y: y + Metrics.titleHeight + Metrics.subtitleGap,
                                     width: textWidth,
                                     height: Metrics.subtitleHeight)
        toggle.frame = NSRect(x: bounds.maxX - pad - Metrics.switchWidth,
                              y: y + (Metrics.headerHeight - Metrics.switchHeight) / 2,
                              width: Metrics.switchWidth,
                              height: Metrics.switchHeight)
        y += Metrics.headerHeight

        guard showsDurations else { return }

        y += Metrics.sectionGap
        segmented.frame = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: Metrics.segmentedHeight)
        y += Metrics.segmentedHeight

        if showsCustomFields {
            y += Metrics.controlGap
            customRow.frame = NSRect(x: pad, y: y,
                                     width: bounds.width - pad * 2,
                                     height: Metrics.customFieldHeight)
            y += Metrics.customFieldHeight
        }

        if showsCountdown {
            y += Metrics.controlGap
            countdownLabel.frame = NSRect(x: pad, y: y,
                                          width: bounds.width - pad * 2,
                                          height: Metrics.countdownHeight)
        }
    }
}

// MARK: - Panel

/// Rounded on all four corners: hosted in an NSPopover, it floats clear of the menu bar rather
/// than sitting flush against it.
final class PanelView: NSView {
    weak var delegate: PanelViewDelegate? {
        didSet {
            caffeinateRow.delegate = delegate
            lidRow.delegate = delegate
        }
    }

    private let caffeinateRow = FeatureRowView(
        feature: .caffeinate,
        title: "Keep Screen Awake",
        subtitle: "Prevents display sleep for active processes"
    )
    private let lidRow = FeatureRowView(
        feature: .lid,
        title: "Keep Awake on Lid Close",
        subtitle: "Continues running with the lid closed"
    )
    private let topDivider = DividerView()
    private let bottomDivider = DividerView()
    private let quitRow = QuitRowView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 200))
        for view in [caffeinateRow, topDivider, lidRow, bottomDivider, quitRow] as [NSView] {
            addSubview(view)
        }
        quitRow.onQuit = { [weak self] in self?.delegate?.panelDidRequestQuit() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ state: PanelState) {
        caffeinateRow.apply(on: state.caffeinateOn,
                            duration: state.caffeinateDuration,
                            customHours: state.caffeinateCustomHours,
                            customMinutes: state.caffeinateCustomMinutes,
                            countdown: state.caffeinateCountdown)
        lidRow.apply(on: state.lidOn,
                     duration: state.lidDuration,
                     customHours: state.lidCustomHours,
                     customMinutes: state.lidCustomMinutes,
                     countdown: state.lidCountdown)
        needsLayout = true
        needsDisplay = true
    }

    var fittingHeight: CGFloat {
        Metrics.panelVerticalPadding * 2
            + caffeinateRow.fittingHeight
            + lidRow.fittingHeight
            + (Metrics.dividerHeight + Metrics.dividerMargin * 2) * 2
            + Metrics.quitRowHeight
    }

    override func layout() {
        super.layout()

        var y = Metrics.panelVerticalPadding
        let width = bounds.width

        func place(_ view: NSView, height: CGFloat) {
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }

        place(caffeinateRow, height: caffeinateRow.fittingHeight)

        y += Metrics.dividerMargin
        place(topDivider, height: Metrics.dividerHeight)
        y += Metrics.dividerMargin

        place(lidRow, height: lidRow.fittingHeight)

        y += Metrics.dividerMargin
        place(bottomDivider, height: Metrics.dividerHeight)
        y += Metrics.dividerMargin

        // The quit row runs to the panel's bottom edge, swallowing the closing padding so its hover
        // highlight can reach the corners.
        quitRow.bottomCornerRadius = Metrics.panelCornerRadius
        place(quitRow, height: Metrics.quitRowHeight + Metrics.panelVerticalPadding)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Palette.current
        let radius = Metrics.panelCornerRadius
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius,
                                yRadius: radius)

        palette.panelBackground.setFill()
        path.fill()
        palette.panelBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshPalette()
    }

    /// Pushes the current palette through the tree. Views that draw in `draw(_:)` just need to be
    /// redrawn; those caching colours in layers or text fields adopt `PaletteAware`.
    func refreshPalette() {
        PanelView.refreshPalette(in: self)
    }

    private static func refreshPalette(in view: NSView) {
        (view as? PaletteAware)?.applyPalette()
        view.needsDisplay = true
        view.needsLayout = true
        view.subviews.forEach { refreshPalette(in: $0) }
    }
}
