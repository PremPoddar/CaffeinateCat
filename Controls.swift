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
        set(!isOn, animated: true)
        onToggle?(isOn)
    }
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

// MARK: - Quit row

/// Full-width click target; the accent highlight is inset so it reads as a menu item.
final class QuitRowView: NSView {
    var onQuit: (() -> Void)?

    /// The panel's corner radius, so the highlight follows its bottom curve instead of cutting
    /// square corners across it.
    var bottomCornerRadius: CGFloat = 0

    private var hovering = false

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onQuit?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Palette.current

        // Full-bleed: the design insets the highlight like a menu item, which leaves a gap at every
        // edge. Filling the row edge to edge — and down into the panel's bottom padding, following
        // its corner curve — reads as one solid hover target.
        if hovering {
            let radius = bottomCornerRadius
            // Flipped view, so extending upward past the top puts those corners outside the clip:
            // what remains is square at the top and rounded at the bottom.
            let extended = NSRect(x: bounds.minX, y: bounds.minY - radius,
                                  width: bounds.width, height: bounds.height + radius)

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: bounds).addClip()
            palette.accent.setFill()
            NSBezierPath(roundedRect: extended, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let titleColor = hovering ? NSColor.white : palette.text
        let shortcutColor = hovering ? NSColor.white.withAlphaComponent(0.8) : palette.subtext

        // Text aligns with the feature rows above.
        draw("Quit", font: Typography.quit, color: titleColor,
             x: Metrics.rowHorizontalPadding, alignRight: false)
        draw("⌘Q", font: Typography.quitShortcut, color: shortcutColor,
             x: bounds.maxX - Metrics.rowHorizontalPadding, alignRight: true)
    }

    private func draw(_ string: String, font: NSFont, color: NSColor, x: CGFloat, alignRight: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attributes)
        // Centred across the whole row, including the panel padding it absorbs — centring in the
        // row proper instead left a visible band of dead space under the label.
        let origin = NSPoint(x: alignRight ? x - size.width : x, y: bounds.midY - size.height / 2)
        (string as NSString).draw(at: origin, withAttributes: attributes)
    }
}
