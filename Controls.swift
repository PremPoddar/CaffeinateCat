import Cocoa

// The three custom-drawn controls the panel is built from. None of them own app state: each is
// told what to show and reports clicks back through a closure.

// Each overrides `acceptsFirstMouse` — a popover's window often isn't key when it appears, and
// AppKit eats the mouse-down that makes a non-key window key unless the view opts in. Without it
// the first click on a control is swallowed and the user has to click twice. AppKit's own controls
// (NSStepper, NSTextField) already return true; these hand-rolled ones must say so themselves.

// MARK: - Toggle switch

/// A 38x22 iOS-style switch. Track and thumb are plain layers so the 0.15s slide the design asks
/// for comes free from CoreAnimation's implicit animations.
final class ToggleSwitch: NSView, PaletteAware {
    var onToggle: ((Bool) -> Void)?
    private(set) var isOn = false

    private let track = CALayer()
    private let thumb = CALayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.switchWidth, height: Metrics.switchHeight))
        wantsLayer = true

        track.frame = CGRect(x: 0, y: 0, width: Metrics.switchWidth, height: Metrics.switchHeight)
        track.cornerRadius = Metrics.switchHeight / 2
        layer?.addSublayer(track)

        thumb.frame = CGRect(x: Metrics.switchInset, y: Metrics.switchInset,
                             width: Metrics.switchThumb, height: Metrics.switchThumb)
        thumb.cornerRadius = Metrics.switchThumb / 2
        thumb.backgroundColor = NSColor.white.cgColor
        thumb.shadowColor = NSColor.black.cgColor
        thumb.shadowOpacity = 0.3
        thumb.shadowOffset = CGSize(width: 0, height: -1)
        thumb.shadowRadius = 1.5
        track.addSublayer(thumb)

        applyPalette()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.switchWidth, height: Metrics.switchHeight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Sets the visual state without firing `onToggle` — used when the app pushes state down.
    func set(_ on: Bool, animated: Bool) {
        isOn = on
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.15)
        thumb.frame.origin.x = on ? Metrics.switchOnX : Metrics.switchInset
        track.backgroundColor = (on ? Palette.current.accent : Palette.current.switchOffTrack).cgColor
        CATransaction.commit()
    }

    func applyPalette() {
        set(isOn, animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        flip()
    }

    private func flip() {
        set(!isOn, animated: true)
        onToggle?(isOn)
    }

    // MARK: Accessibility

    var accessibilityTitle = ""

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityLabel() -> String? { accessibilityTitle }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { flip(); return true }
}

// MARK: - Segmented control

/// Equal-width segments in a rounded trough; the selected one gets the accent fill.
final class SegmentedControl: NSView {
    var onSelect: ((Int) -> Void)?
    private(set) var selectedIndex = 0

    private let titles: [String]

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: Metrics.segmentedHeight))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Metrics.segmentedHeight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Selects without firing `onSelect`.
    func select(_ index: Int) {
        guard index != selectedIndex, titles.indices.contains(index) else { return }
        selectedIndex = index
        needsDisplay = true
    }

    private func segmentRect(_ index: Int) -> NSRect {
        let pad = Metrics.segmentedPadding
        let gap = Metrics.segmentGap
        let count = CGFloat(titles.count)
        let width = (bounds.width - pad * 2 - gap * (count - 1)) / count
        return NSRect(x: pad + (width + gap) * CGFloat(index),
                      y: pad,
                      width: width,
                      height: bounds.height - pad * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Palette.current

        palette.segmentBackground.setFill()
        NSBezierPath(roundedRect: bounds,
                     xRadius: Metrics.segmentedRadius,
                     yRadius: Metrics.segmentedRadius).fill()

        for (index, title) in titles.enumerated() {
            let rect = segmentRect(index)
            let selected = index == selectedIndex

            if selected {
                palette.accent.setFill()
                NSBezierPath(roundedRect: rect,
                             xRadius: Metrics.segmentRadius,
                             yRadius: Metrics.segmentRadius).fill()
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: selected ? Typography.segmentSelected : Typography.segment,
                .foregroundColor: selected ? NSColor.white : palette.subtext,
            ]
            let size = (title as NSString).size(withAttributes: attributes)
            let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            (title as NSString).draw(at: origin, withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Widen each segment by half the gap so the seams between them aren't dead zones.
        for index in titles.indices where segmentRect(index).insetBy(dx: -Metrics.segmentGap / 2, dy: 0).contains(point) {
            guard index != selectedIndex else { return }
            select(index)
            onSelect?(index)
            return
        }
    }
}

// MARK: - Custom duration fields

/// A clamped integer field. Reports changes live; `DurationFieldRow` is its delegate.
final class NumberField: NSTextField, PaletteAware {
    let maxValue: Int

    init(maxValue: Int) {
        self.maxValue = maxValue
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.customFieldWidth, height: Metrics.customFieldHeight))
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        alignment = .center
        font = Typography.customField
        wantsLayer = true
        layer?.cornerRadius = Metrics.customFieldRadius
        layer?.borderWidth = 1
        applyPalette()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyPalette() {
        let palette = Palette.current
        textColor = palette.text
        layer?.backgroundColor = palette.fieldBackground.cgColor
        layer?.borderColor = palette.fieldBorder.cgColor
    }

    var clampedValue: Int {
        max(0, min(maxValue, Int(stringValue.trimmingCharacters(in: .whitespaces)) ?? 0))
    }

    func setValue(_ value: Int) {
        let clamped = max(0, min(maxValue, value))
        // Don't stomp on what the user is mid-way through typing.
        guard currentEditor() == nil else { return }
        stringValue = String(clamped)
    }

    /// Rewrites the text to the clamped value. Only called once the user has finished typing, so
    /// half-entered numbers aren't corrected out from under them.
    func normalize() {
        stringValue = String(clampedValue)
    }
}

/// `[ 1 ]⇕ h  [ 30 ]⇕ m` — steppers and the keyboard both drive the same live update.
final class DurationFieldRow: NSView, NSTextFieldDelegate {
    var onChange: ((Int, Int) -> Void)?

    private let hoursField = NumberField(maxValue: 23)
    private let minutesField = NumberField(maxValue: 59)
    private let hoursStepper = NSStepper()
    private let minutesStepper = NSStepper()
    private let hoursUnit = Labels.make("h", font: Typography.customField)
    private let minutesUnit = Labels.make("m", font: Typography.customField)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Metrics.customFieldHeight))

        configure(hoursStepper, maxValue: hoursField.maxValue, action: #selector(hoursStepperChanged))
        configure(minutesStepper, maxValue: minutesField.maxValue, action: #selector(minutesStepperChanged))

        for field in [hoursField, minutesField] {
            field.delegate = self
        }

        for view in [hoursField, hoursStepper, hoursUnit,
                     minutesField, minutesStepper, minutesUnit] as [NSView] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ stepper: NSStepper, maxValue: Int, action: Selector) {
        stepper.minValue = 0
        stepper.maxValue = Double(maxValue)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.autorepeat = true
        stepper.controlSize = .small
        stepper.target = self
        stepper.action = action
    }

    private func report() {
        onChange?(hoursField.clampedValue, minutesField.clampedValue)
    }

    @objc private func hoursStepperChanged(_ sender: NSStepper) {
        hoursField.stringValue = String(sender.integerValue)
        report()
    }

    @objc private func minutesStepperChanged(_ sender: NSStepper) {
        minutesField.stringValue = String(sender.integerValue)
        report()
    }

    // MARK: NSTextFieldDelegate

    /// Fires on every keystroke, so typing restarts the timer immediately. The text itself isn't
    /// clamped here — only the value reported upward — so typing "90" into minutes doesn't fight
    /// the user mid-entry.
    func controlTextDidChange(_ notification: Notification) {
        syncSteppers()
        // An empty field is mid-edit, not a zero. Clearing "30" to type "45" would otherwise report
        // 0 on the way through and switch the feature off under the user. A deliberate "0" still
        // reports, and a field left blank reports 0 once editing ends and it normalises.
        guard !hasBlankField else { return }
        report()
    }

    private var hasBlankField: Bool {
        [hoursField, minutesField].contains {
            $0.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        hoursField.normalize()
        minutesField.normalize()
        syncSteppers()
        report()
    }

    private func syncSteppers() {
        hoursStepper.integerValue = hoursField.clampedValue
        minutesStepper.integerValue = minutesField.clampedValue
    }

    func set(hours: Int, minutes: Int) {
        hoursField.setValue(hours)
        minutesField.setValue(minutes)
        syncSteppers()
    }

    func applyPaletteToLabels() {
        let palette = Palette.current
        hoursUnit.textColor = palette.subtext
        minutesUnit.textColor = palette.subtext
    }

    override func layout() {
        super.layout()
        applyPaletteToLabels()

        let height = Metrics.customFieldHeight
        var x: CGFloat = 0

        // One group is: field, stepper, unit label.
        func placeGroup(field: NSView, stepper: NSStepper, unit: NSView) {
            field.frame = NSRect(x: x, y: 0, width: Metrics.customFieldWidth, height: height)
            x += Metrics.customFieldWidth + Metrics.stepperGap

            let stepperHeight = stepper.fittingSize.height
            stepper.frame = NSRect(x: x,
                                   y: (height - stepperHeight) / 2,
                                   width: Metrics.stepperWidth,
                                   height: stepperHeight)
            x += Metrics.stepperWidth + Metrics.customGap

            unit.frame = NSRect(x: x, y: 0, width: Metrics.customUnitWidth, height: height)
            x += Metrics.customUnitWidth
        }

        placeGroup(field: hoursField, stepper: hoursStepper, unit: hoursUnit)
        x += Metrics.customPairGap
        placeGroup(field: minutesField, stepper: minutesStepper, unit: minutesUnit)
    }
}

// MARK: - Divider

final class DividerView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Palette.current.divider.setFill()
        bounds.fill()
    }
}

// MARK: - Menu row

/// A full-width, hover-highlighted click target that reads as a menu item: a title on the left and a
/// shortcut, detail text or disclosure chevron on the right.
final class MenuRowView: NSView {
    enum Style {
        case accent   // solid accent highlight with white text, like an NSMenu item
        case subtle   // faint wash; for rows that open or reveal rather than act
    }

    enum Trailing {
        case none
        case text(String)
        case chevron(expanded: Bool)
    }

    var onClick: (() -> Void)?
    var title: String { didSet { needsDisplay = true } }
    var trailing: Trailing = .none { didSet { needsDisplay = true } }
    var style: Style = .accent
    var isDestructive = false

    /// The panel's corner radius, for the last row, so the highlight follows the panel's bottom
    /// curve instead of cutting square corners across it.
    var bottomCornerRadius: CGFloat = 0

    private var hovering = false

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func viewDidHide() {
        super.viewDidHide()
        setHovering(false)
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    /// Clears hover when the panel closes under the pointer, so it doesn't reopen highlighted.
    func resetHover() { setHovering(false) }

    private func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        // Only if released over the row, so dragging off it cancels like a real menu.
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Palette.current
        let solid = hovering && style == .accent

        // Full-bleed: filling the row edge to edge — and, for the last row, down into the panel's
        // bottom padding following its corner curve — reads as one solid hover target.
        if hovering {
            let radius = bottomCornerRadius
            // Flipped view, so extending upward past the top puts those corners outside the clip:
            // what remains is square at the top and rounded at the bottom.
            let extended = NSRect(x: bounds.minX, y: bounds.minY - radius,
                                  width: bounds.width, height: bounds.height + radius)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: bounds).addClip()
            (solid ? palette.accent : palette.hover).setFill()
            NSBezierPath(roundedRect: extended, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let baseColor = isDestructive ? palette.destructive : palette.text
        let titleColor = solid ? NSColor.white : baseColor
        let detailColor = solid ? NSColor.white.withAlphaComponent(0.8) : palette.subtext

        // Text aligns with the feature rows above.
        drawText(title, font: Typography.quit, color: titleColor,
                 x: Metrics.rowHorizontalPadding, alignRight: false)

        let right = bounds.maxX - Metrics.rowHorizontalPadding
        switch trailing {
        case .none:
            break
        case .text(let text):
            drawText(text, font: Typography.quitShortcut, color: detailColor, x: right, alignRight: true)
        case .chevron(let expanded):
            drawChevron(expanded: expanded, color: detailColor, right: right)
        }
    }

    private func drawText(_ string: String, font: NSFont, color: NSColor, x: CGFloat, alignRight: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attributes)
        // Centred across the whole row, including any panel padding it absorbs.
        let origin = NSPoint(x: alignRight ? x - size.width : x, y: bounds.midY - size.height / 2)
        (string as NSString).draw(at: origin, withAttributes: attributes)
    }

    /// A 5pt chevron: pointing right when collapsed, down when expanded.
    private func drawChevron(expanded: Bool, color: NSColor, right: CGFloat) {
        let half: CGFloat = 3
        let center = NSPoint(x: right - half - 1, y: bounds.midY)
        let path = NSBezierPath()
        if expanded {
            path.move(to: NSPoint(x: center.x - half * 1.4, y: center.y - half * 0.7))
            path.line(to: NSPoint(x: center.x, y: center.y + half * 0.7))
            path.line(to: NSPoint(x: center.x + half * 1.4, y: center.y - half * 0.7))
        } else {
            path.move(to: NSPoint(x: center.x - half * 0.7, y: center.y - half * 1.4))
            path.line(to: NSPoint(x: center.x + half * 0.7, y: center.y))
            path.line(to: NSPoint(x: center.x - half * 0.7, y: center.y + half * 1.4))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

// MARK: - Option row

/// A checkbox and its label; the whole row is the click target.
final class OptionRowView: NSView {
    var onToggle: ((Bool) -> Void)?
    private(set) var isOn = false
    let title: String

    private var hovering = false

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func set(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        flip()
    }

    private func flip() {
        isOn.toggle()
        needsDisplay = true
        onToggle?(isOn)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Palette.current

        if hovering {
            palette.hover.setFill()
            bounds.fill()
        }

        let size = Metrics.checkboxSize
        let box = NSRect(x: Metrics.rowHorizontalPadding, y: (bounds.height - size) / 2, width: size, height: size)
        let boxPath = NSBezierPath(roundedRect: box, xRadius: Metrics.checkboxRadius, yRadius: Metrics.checkboxRadius)
        if isOn {
            palette.accent.setFill()
            boxPath.fill()
            // Flipped view: y grows downward.
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + size * 0.25, y: box.minY + size * 0.52))
            check.line(to: NSPoint(x: box.minX + size * 0.43, y: box.minY + size * 0.70))
            check.line(to: NSPoint(x: box.minX + size * 0.76, y: box.minY + size * 0.32))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            palette.fieldBackground.setFill()
            boxPath.fill()
            palette.fieldBorder.setStroke()
            let inset = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                                     xRadius: Metrics.checkboxRadius - 0.5,
                                     yRadius: Metrics.checkboxRadius - 0.5)
            inset.lineWidth = 1
            inset.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: Typography.option, .foregroundColor: palette.text]
        let textSize = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: box.maxX + Metrics.checkboxLabelGap,
                                             y: bounds.midY - textSize.height / 2),
                                 withAttributes: attributes)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { flip(); return true }
}

// MARK: - Progress bar

/// A thin rounded bar showing how much of a timed run is left.
final class ProgressBar: NSView {
    var fraction: Double = 0 {
        didSet { if fraction != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Palette.current
        let radius = bounds.height / 2
        palette.segmentBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let clamped = max(0, min(1, fraction))
        guard clamped > 0 else { return }
        let fill = NSRect(x: bounds.minX, y: bounds.minY,
                          width: max(bounds.height, bounds.width * CGFloat(clamped)), height: bounds.height)
        palette.accent.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

// MARK: - App header

/// The app's name with a live status pill on the right: a coloured dot and one word of state.
final class AppHeaderView: NSView, PaletteAware {
    private let icon = NSImageView()
    private let titleLabel = Labels.make("CaffeinateCat", font: Typography.appTitle)
    private let statusLabel = Labels.make("", font: Typography.appStatus, alignment: .right)
    private let dot = CALayer()
    private var isAwake = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        if #available(macOS 11.0, *) {
            icon.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        }
        icon.imageScaling = .scaleProportionallyDown
        dot.cornerRadius = Metrics.statusDotSize / 2
        for view in [icon, titleLabel, statusLabel] as [NSView] { addSubview(view) }
        layer?.addSublayer(dot)
        applyPalette()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(status: String, awake: Bool) {
        statusLabel.stringValue = status
        isAwake = awake
        applyPalette()
        needsLayout = true
    }

    func applyPalette() {
        let palette = Palette.current
        icon.contentTintColor = isAwake ? palette.accent : palette.subtext
        titleLabel.textColor = palette.text
        statusLabel.textColor = palette.subtext
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = (isAwake ? palette.statusOn : palette.statusOff).cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let pad = Metrics.rowHorizontalPadding
        let iconSize = Metrics.appIconSize
        icon.frame = NSRect(x: pad, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)

        let titleHeight = titleLabel.fittingSize.height
        let titleX = icon.frame.maxX + 6
        titleLabel.frame = NSRect(x: titleX, y: (bounds.height - titleHeight) / 2,
                                  width: titleLabel.fittingSize.width, height: titleHeight)

        let statusSize = statusLabel.fittingSize
        let statusX = bounds.maxX - pad - statusSize.width
        statusLabel.frame = NSRect(x: statusX, y: (bounds.height - statusSize.height) / 2,
                                   width: statusSize.width, height: statusSize.height)

        let dotSize = Metrics.statusDotSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The layer tree isn't flipped, so centre vertically in bounds either way.
        dot.frame = CGRect(x: statusX - 6 - dotSize, y: (bounds.height - dotSize) / 2,
                           width: dotSize, height: dotSize)
        CATransaction.commit()
    }
}

// MARK: - Menu bar icon

/// The system's own cup symbol, with orange liquid filling it to the battery's level.
///
/// The outline is the SF Symbol, so it sits naturally among the other menu bar icons. The liquid is
/// clipped to the cup's enclosed interior, found once per symbol by flood-filling a high-resolution
/// render of it — no hand-measured geometry to drift when the symbol's artwork changes.
///
/// It can't be a template image (the menu bar would flatten it to one colour), so the outline is
/// tinted `labelColor` inside a drawing handler: the handler re-runs under whatever appearance the
/// menu bar is drawing with, so it follows a light or dark menu bar independently of the app's own.
enum MenuBarIcon {
    /// Levels the liquid snaps to: full, 80, 60, 40, 20, empty.
    static func step(forBattery percent: Int?) -> Int {
        guard let percent else { return 100 } // no battery: a full cup
        return Int((Double(max(0, min(100, percent))) / 20).rounded()) * 20
    }

    /// `awake` colours the liquid orange (grey when off); `steam` marks lid-close mode.
    static func image(level: Int, awake: Bool, steam: Bool) -> NSImage? {
        guard let cup = steam ? (Cup.steaming ?? Cup.plain) : Cup.plain else { return nil }
        let mask = cup.liquidMask(level: level)
        let symbol = cup.symbol
        let size = symbol.size

        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let dark: Bool
            if #available(macOS 11.0, *) {
                dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            } else {
                dark = NSAppearance.current.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            }

            if let mask {
                context.saveGState()
                context.clip(to: rect, mask: mask)
                let liquid = awake ? (dark ? Palette.dark.accent : Palette.light.accent)
                                   : NSColor.labelColor.withAlphaComponent(0.3)
                liquid.setFill()
                rect.fill()
                context.restoreGState()
            }

            // The symbol, recoloured to the menu bar's label colour.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            symbol.draw(in: rect)
            NSColor.labelColor.setFill()
            rect.fill(using: .sourceAtop)
            context.endTransparencyLayer()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A cup symbol and the interior its liquid may occupy.
    private final class Cup {
        static let plain = Cup(name: "cup.and.saucer",
                               // The drink's surface and the body below the rim.
                               seeds: [CGPoint(x: 0.45, y: 0.25), CGPoint(x: 0.45, y: 0.52)])
        static let steaming = Cup(name: "cup.and.heat.waves", // macOS 14+
                                  // Just the body: the waves break the surface into open gaps.
                                  seeds: [CGPoint(x: 0.42, y: 0.74)])

        /// Mask pixels per point; 4 keeps the edge smooth on a 2x display.
        private static let scale = 4

        let symbol: NSImage
        private let width: Int
        private let height: Int
        private let interior: [Bool]          // row 0 at the top
        private let rows: ClosedRange<Int>    // the interior's vertical extent
        private var masks: [Int: CGImage] = [:]

        /// `seeds` are points inside the interior, as fractions of the symbol's size from the top left.
        private init?(name: String, seeds: [CGPoint]) {
            guard #available(macOS 11.0, *),
                  let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
                  let symbol = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
            else { return nil }
            self.symbol = symbol
            width = Int(ceil(symbol.size.width)) * Self.scale
            height = Int(ceil(symbol.size.height)) * Self.scale

            // Render the outline and flood-fill each seed's enclosed region.
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            symbol.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()

            let (w, h) = (width, height)
            let wall = (0..<(w * h)).map { i in (rep.colorAt(x: i % w, y: i / w)?.alphaComponent ?? 0) > 0.5 }
            var region = [Bool](repeating: false, count: w * h)
            for seed in seeds {
                guard let filled = Self.flood(from: (Int(seed.x * CGFloat(w)), Int(seed.y * CGFloat(h))),
                                              walls: wall, width: w, height: h) else { continue }
                for i in filled { region[i] = true }
            }
            // Grow it under the outline's antialiased inner edge, so no hairline gap shows between
            // liquid and cup; the outline is drawn on top and covers the overlap.
            region = Self.dilate(region, by: Self.scale / 2, width: w, height: h)

            let filledRows = (0..<h).filter { y in (0..<w).contains { region[y * w + $0] } }
            guard let top = filledRows.first, let bottom = filledRows.last else { return nil }
            interior = region
            rows = top...bottom
        }

        /// The pixels reachable from `start` without crossing a wall; nil if that leaks out to the
        /// image's edge, meaning the seed wasn't inside a closed shape.
        private static func flood(from start: (Int, Int), walls: [Bool], width w: Int, height h: Int) -> [Int]? {
            guard (0..<w).contains(start.0), (0..<h).contains(start.1), !walls[start.1 * w + start.0] else { return nil }
            var seen = [Bool](repeating: false, count: w * h)
            var stack = [start.1 * w + start.0]
            var filled: [Int] = []
            seen[stack[0]] = true
            while let i = stack.popLast() {
                filled.append(i)
                let (x, y) = (i % w, i / w)
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { return nil }
                for n in [i - 1, i + 1, i - w, i + w] where !seen[n] && !walls[n] {
                    seen[n] = true
                    stack.append(n)
                }
            }
            return filled
        }

        private static func dilate(_ region: [Bool], by radius: Int, width w: Int, height h: Int) -> [Bool] {
            var out = region
            for y in 0..<h {
                for x in 0..<w where region[y * w + x] {
                    for dy in -radius...radius {
                        for dx in -radius...radius {
                            let (nx, ny) = (x + dx, y + dy)
                            if (0..<w).contains(nx), (0..<h).contains(ny) { out[ny * w + nx] = true }
                        }
                    }
                }
            }
            return out
        }

        /// The interior filled from the bottom to `level` percent of its height. nil when empty.
        func liquidMask(level: Int) -> CGImage? {
            guard level > 0 else { return nil }
            if let cached = masks[level] { return cached }
            let span = rows.count
            let surface = rows.upperBound + 1 - Int((Double(span) * Double(level) / 100).rounded())
            var pixels = [UInt8](repeating: 0, count: width * height)
            for y in max(surface, rows.lowerBound)...rows.upperBound {
                for x in 0..<width where interior[y * width + x] { pixels[y * width + x] = 255 }
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                     bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { return nil }
            masks[level] = mask
            return mask
        }
    }
}
