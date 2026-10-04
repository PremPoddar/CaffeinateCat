import Cocoa

// The panel's contents, and the value types + delegate that connect it to the app.
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

/// The toggles in the Options section, in display order.
enum PanelOption: CaseIterable {
    case allowDisplaySleep
    case stopOnLowBattery
    case activateOnLaunch
    case launchAtLogin

    var title: String {
        switch self {
        case .allowDisplaySleep: return "Allow display to sleep"
        case .stopOnLowBattery:  return "Turn off at 20% and 10% battery"
        case .activateOnLaunch:  return "Keep awake when app opens"
        case .launchAtLogin:     return "Open at login"
        }
    }
}

struct FeatureState {
    var title = ""
    var subtitle = ""
    var on = false
    var duration: AwakeDuration = .indefinite
    var customHours = DEFAULT_CUSTOM_HOURS
    var customMinutes = DEFAULT_CUSTOM_MINUTES
    // Preformatted by AppDelegate, which owns the run's fixed-width CountdownFormat. Empty when the
    // feature is off or indefinite.
    var countdown = ""
    var endsAt = ""
    var progress: Double = 0
}

struct PanelState {
    var caffeinate = FeatureState()
    var lid = FeatureState()
    var statusText = ""
    var isAwake = false
    var options: [PanelOption: Bool] = [:]
    var optionsExpanded = false
    var lidRuleInstalled = false
    var availableUpdate: String?
    var updatesSupported = true
}

protocol PanelViewDelegate: AnyObject {
    func panelDidToggle(_ feature: Feature, on: Bool)
    func panelDidSelectDuration(_ feature: Feature, _ duration: AwakeDuration)
    func panelDidEditCustom(_ feature: Feature, hours: Int, minutes: Int)
    func panelDidSetOption(_ option: PanelOption, on: Bool)
    func panelDidToggleOptionsExpanded()
    func panelDidRequestRemoveLidRule()
    func panelDidRequestUpdateCheck()
    func panelDidRequestAbout()
    func panelDidRequestQuit()
}

// MARK: - Feature row

/// Title + subtitle + switch, with the duration controls revealed underneath when the switch is on.
final class FeatureRowView: NSView {
    weak var delegate: PanelViewDelegate?

    private static let durations: [AwakeDuration] = [.indefinite, .minutes(15), .minutes(30), .minutes(60), .custom]
    private static let durationTitles = ["Indefinite", "15m", "30m", "1h", "Custom"]

    private let feature: Feature
    private let titleLabel = Labels.make("", font: Typography.rowTitle)
    private let subtitleLabel = Labels.make("", font: Typography.rowSubtitle)
    private let toggle = ToggleSwitch()
    private let segmented = SegmentedControl(titles: FeatureRowView.durationTitles)
    private let customRow = DurationFieldRow()
    private let countdownLabel = Labels.make("", font: Typography.countdown)
    private let endsAtLabel = Labels.make("", font: Typography.endsAt, alignment: .right)
    private let progressBar = ProgressBar()

    private var isOn = false
    private var duration: AwakeDuration = .indefinite

    override var isFlipped: Bool { true }

    init(feature: Feature) {
        self.feature = feature
        super.init(frame: .zero)

        for view in [titleLabel, subtitleLabel, toggle, segmented, customRow,
                     countdownLabel, endsAtLabel, progressBar] as [NSView] {
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

    func apply(_ state: FeatureState) {
        // Only a change in which controls are showing needs a relayout; the per-second countdown
        // update just swaps label text.
        let structureChanged = state.on != isOn || state.duration != duration

        isOn = state.on
        duration = state.duration

        titleLabel.stringValue = state.title
        subtitleLabel.stringValue = state.subtitle
        toggle.accessibilityTitle = state.title
        if toggle.isOn != state.on { toggle.set(state.on, animated: true) }
        if let index = Self.durations.firstIndex(of: state.duration) {
            segmented.select(index)
        }
        customRow.set(hours: state.customHours, minutes: state.customMinutes)
        countdownLabel.stringValue = "Awake — \(state.countdown) left"
        endsAtLabel.stringValue = state.endsAt.isEmpty ? "" : "until \(state.endsAt)"
        progressBar.fraction = state.progress

        // Visibility is applied every time (it's a no-op when unchanged) — gating it on a change
        // left the controls showing at their zero frames for a row that starts, and stays, off.
        segmented.isHidden = !showsDurations
        customRow.isHidden = !showsCustomFields
        countdownLabel.isHidden = !showsCountdown
        endsAtLabel.isHidden = !showsCountdown
        progressBar.isHidden = !showsCountdown
        if structureChanged { needsLayout = true }
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
                    + Metrics.progressGap + Metrics.progressHeight
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
        endsAtLabel.textColor = palette.subtext

        let pad = Metrics.rowHorizontalPadding
        let contentWidth = bounds.width - pad * 2
        let textWidth = contentWidth - Metrics.switchWidth - Metrics.headerToggleGap
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
        segmented.frame = NSRect(x: pad, y: y, width: contentWidth, height: Metrics.segmentedHeight)
        y += Metrics.segmentedHeight

        if showsCustomFields {
            y += Metrics.controlGap
            customRow.frame = NSRect(x: pad, y: y, width: contentWidth, height: Metrics.customFieldHeight)
            y += Metrics.customFieldHeight
        }

        if showsCountdown {
            y += Metrics.controlGap
            countdownLabel.frame = NSRect(x: pad, y: y, width: contentWidth * 0.62, height: Metrics.countdownHeight)
            endsAtLabel.frame = NSRect(x: pad + contentWidth * 0.62, y: y,
                                       width: contentWidth * 0.38, height: Metrics.countdownHeight)
            y += Metrics.countdownHeight + Metrics.progressGap
            progressBar.frame = NSRect(x: pad, y: y, width: contentWidth, height: Metrics.progressHeight)
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

    private let header = AppHeaderView()
    private let caffeinateRow = FeatureRowView(feature: .caffeinate)
    private let lidRow = FeatureRowView(feature: .lid)
    private let optionsRow = MenuRowView(title: "Options")
    private let optionRows: [PanelOption: OptionRowView]
    private let removeRuleRow = MenuRowView(title: "Remove Lid-Close Permission…")
    private let updatesRow = MenuRowView(title: "Check for Updates…")
    private let aboutRow = MenuRowView(title: "About CaffeinateCat")
    private let quitRow = MenuRowView(title: "Quit")
    private let dividers = (0..<4).map { _ in DividerView() }

    private var optionsExpanded = false
    private var lidRuleInstalled = false
    private var updatesSupported = true

    override var isFlipped: Bool { true }

    init() {
        var rows: [PanelOption: OptionRowView] = [:]
        for option in PanelOption.allCases { rows[option] = OptionRowView(title: option.title) }
        optionRows = rows

        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 200))

        let allRows: [NSView] = [header, caffeinateRow, lidRow, optionsRow, removeRuleRow, updatesRow, aboutRow, quitRow]
            + PanelOption.allCases.compactMap { optionRows[$0] }
        for view in allRows + dividers { addSubview(view) }

        optionsRow.style = .subtle
        optionsRow.trailing = .chevron(expanded: false)
        optionsRow.onClick = { [weak self] in self?.delegate?.panelDidToggleOptionsExpanded() }

        for (option, row) in optionRows {
            row.isHidden = true
            row.onToggle = { [weak self] on in self?.delegate?.panelDidSetOption(option, on: on) }
        }

        removeRuleRow.isHidden = true
        removeRuleRow.style = .subtle
        removeRuleRow.isDestructive = true
        removeRuleRow.onClick = { [weak self] in self?.delegate?.panelDidRequestRemoveLidRule() }

        updatesRow.onClick = { [weak self] in self?.delegate?.panelDidRequestUpdateCheck() }
        aboutRow.onClick = { [weak self] in self?.delegate?.panelDidRequestAbout() }

        quitRow.trailing = .text("⌘Q")
        quitRow.onClick = { [weak self] in self?.delegate?.panelDidRequestQuit() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ state: PanelState) {
        header.set(status: state.statusText, awake: state.isAwake)
        caffeinateRow.apply(state.caffeinate)
        lidRow.apply(state.lid)

        for (option, row) in optionRows { row.set(state.options[option] ?? false) }

        if state.optionsExpanded != optionsExpanded || state.lidRuleInstalled != lidRuleInstalled {
            optionsExpanded = state.optionsExpanded
            lidRuleInstalled = state.lidRuleInstalled
            optionsRow.trailing = .chevron(expanded: optionsExpanded)
            for row in optionRows.values { row.isHidden = !optionsExpanded }
            removeRuleRow.isHidden = !(optionsExpanded && lidRuleInstalled)
        }
        updatesRow.title = state.availableUpdate.map { "Update to \($0)…" } ?? "Check for Updates…"
        updatesRow.isHidden = !state.updatesSupported
        updatesSupported = state.updatesSupported
        needsLayout = true
    }

    /// Clears row hover state; called when the popover closes under the pointer.
    func resetHover() {
        [optionsRow, removeRuleRow, updatesRow, aboutRow, quitRow].forEach { $0.resetHover() }
    }

    /// One list drives both layout and sizing, so the two can't disagree.
    private enum Item {
        case view(NSView, CGFloat)
        case divider(Int)
    }

    private var items: [Item] {
        var items: [Item] = [
            .view(header, Metrics.appHeaderHeight),
            .divider(0),
            .view(caffeinateRow, caffeinateRow.fittingHeight),
            .divider(1),
            .view(lidRow, lidRow.fittingHeight),
            .divider(2),
            .view(optionsRow, Metrics.menuRowHeight),
        ]
        if optionsExpanded {
            items += PanelOption.allCases.compactMap { optionRows[$0] }.map { .view($0, Metrics.optionRowHeight) }
            if lidRuleInstalled { items.append(.view(removeRuleRow, Metrics.menuRowHeight)) }
        }
        items += [
            .divider(3),
        ]
        if updatesSupported { items.append(.view(updatesRow, Metrics.menuRowHeight)) }
        items += [
            .view(aboutRow, Metrics.menuRowHeight),
            // The quit row runs to the panel's bottom edge, swallowing the closing padding so its
            // hover highlight can reach the corners.
            .view(quitRow, Metrics.menuRowHeight + Metrics.panelVerticalPadding),
        ]
        return items
    }

    private static func height(of item: Item) -> CGFloat {
        switch item {
        case .view(_, let height): return height
        case .divider:             return Metrics.dividerHeight + Metrics.dividerMargin * 2
        }
    }

    var fittingHeight: CGFloat {
        Metrics.panelVerticalPadding + items.reduce(0) { $0 + Self.height(of: $1) }
    }

    override func layout() {
        super.layout()

        var y = Metrics.panelVerticalPadding
        let width = bounds.width

        for item in items {
            switch item {
            case .view(let view, let height):
                view.frame = NSRect(x: 0, y: y, width: width, height: height)
                y += height
            case .divider(let index):
                y += Metrics.dividerMargin
                dividers[index].frame = NSRect(x: 0, y: y, width: width, height: Metrics.dividerHeight)
                y += Metrics.dividerHeight + Metrics.dividerMargin
            }
        }

        quitRow.bottomCornerRadius = Metrics.panelCornerRadius
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
