import Cocoa
import Foundation

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodexStatusLight")
let stateFile = supportDir.appendingPathComponent("state.json")
let preferencesFile = supportDir.appendingPathComponent("preferences.json")

let labels: [String: String] = [
    "working": "正在干活",
    "done": "可以验收",
    "waiting": "等你回复",
    "idle": "空闲"
]

let stateOrder = ["working", "done", "waiting", "idle"]
let designWidth: CGFloat = 198
let designHeight: CGFloat = 522
let uiScale: CGFloat = readCGFloatPreference("scale") ?? 0.58
let windowWidth = designWidth * uiScale
let windowHeight = designHeight * uiScale
let doneAutoIdleSeconds: TimeInterval = readDoublePreference("done_auto_idle_seconds") ?? 10 * 60

final class SoundController {
    private let sounds: [String: NSSound?] = [
        "done": NSSound(named: NSSound.Name("Glass")),
        "waiting": NSSound(named: NSSound.Name("Basso"))
    ]
    private var redStopTimer: Timer?
    private var greenStopTimer: Timer?
    private(set) var muted = readBoolPreference("muted") ?? false

    func apply(state: String, playPrompt: Bool) {
        if muted {
            stopAll()
            return
        }
        if state != "done" {
            stopGreenSound()
        }
        if state == "waiting" {
            startRedAlert(playImmediately: playPrompt)
            return
        }
        stopRedSound()
        if playPrompt && state == "done" {
            playGreenForThreeSeconds()
        }
    }

    func setMuted(_ nextMuted: Bool) {
        muted = nextMuted
        updatePreference("muted", value: nextMuted)
        if nextMuted {
            stopAll()
        }
    }

    private func playOnce(_ state: String) {
        guard let sound = sounds[state] ?? nil else { return }
        if sound.isPlaying {
            sound.stop()
            sound.currentTime = 0
        }
        sound.play()
    }

    private func playGreenForThreeSeconds() {
        guard let sound = sounds["done"] ?? nil else { return }
        greenStopTimer?.invalidate()
        if sound.isPlaying {
            sound.stop()
            sound.currentTime = 0
        }
        sound.loops = true
        sound.play()
        greenStopTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.stopGreenSound()
        }
    }

    private func startRedAlert(playImmediately: Bool) {
        redStopTimer?.invalidate()
        if playImmediately {
            playOnce("waiting")
        }
        redStopTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.stopRedSound()
        }
    }

    func stopAll() {
        stopGreenSound()
        stopRedSound()
    }

    private func stopGreenSound() {
        greenStopTimer?.invalidate()
        greenStopTimer = nil
        if let greenSound = sounds["done"] ?? nil {
            greenSound.loops = false
            if greenSound.isPlaying {
                greenSound.stop()
                greenSound.currentTime = 0
            }
        }
    }

    private func stopRedSound() {
        redStopTimer?.invalidate()
        redStopTimer = nil
        if let redSound = sounds["waiting"] ?? nil, redSound.isPlaying {
            redSound.stop()
            redSound.currentTime = 0
        }
    }
}

final class TrafficLightView: NSView {
    var state = readState()
    var blinkOn = true
    var waitingAlertActive = false
    var isMuted = readBoolPreference("muted") ?? false
    var dragStart: NSPoint?
    var onStateCommand: ((String) -> Void)?
    var onMuteToggle: (() -> Void)?
    var onClose: (() -> Void)?
    weak var ownerWindow: NSWindow?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.scale(by: uiScale)
        transform.concat()

        let body = NSRect(x: 22, y: 18, width: 154, height: 486)
        drawRoundedGradient(body, radius: 28, top: NSColor(hex: "#363636"), bottom: NSColor(hex: "#191a19"), stroke: NSColor.white.withAlphaComponent(0.16), width: 1)
        drawRounded(body.insetBy(dx: 5, dy: 5), radius: 24, fill: NSColor.clear, stroke: NSColor.black.withAlphaComponent(0.34), width: 2)

        drawTopText("Codex", rect: NSRect(x: 0, y: 459, width: designWidth, height: 32), size: 20, weight: .medium)
        drawCloseButton()

        NSColor.white.withAlphaComponent(0.08).setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: body.minX + 18, y: 86))
        separator.line(to: NSPoint(x: body.maxX - 18, y: 86))
        separator.lineWidth = 1
        separator.stroke()

        drawLens(center: NSPoint(x: 99, y: 405), light: "red", isActive: isLightVisible("red"))
        drawLens(center: NSPoint(x: 99, y: 292), light: "yellow", isActive: isLightVisible("yellow"))
        drawLens(center: NSPoint(x: 99, y: 179), light: "green", isActive: isLightVisible("green"))

        drawBottomText(labels[state] ?? "空闲", rect: NSRect(x: 18, y: 38, width: designWidth - 36, height: 36))
        drawMuteButton()

        NSGraphicsContext.restoreGraphicsState()
    }

    func activeLight() -> String {
        switch state {
        case "working": return "yellow"
        case "done": return "green"
        case "waiting": return "red"
        default: return ""
        }
    }

    func isLightVisible(_ light: String) -> Bool {
        guard activeLight() == light else { return false }
        return state == "waiting" && waitingAlertActive ? blinkOn : true
    }

    func baseColorFor(_ light: String) -> NSColor {
        switch light {
        case "red": return NSColor(hex: "#f34a42")
        case "yellow": return NSColor(hex: "#ffd84a")
        case "green": return NSColor(hex: "#57d65a")
        default: return NSColor.white
        }
    }

    func drawRounded(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor, width: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    func drawRoundedGradient(_ rect: NSRect, radius: CGFloat, top: NSColor, bottom: NSColor, stroke: NSColor, width: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: bottom, ending: top)?.draw(in: rect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        stroke.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    func drawLens(center: NSPoint, light: String, isActive: Bool) {
        let color = baseColorFor(light)
        let isIdle = state == "idle"
        let glowAlpha: CGFloat = isIdle ? 0.03 : (isActive ? 0.34 : 0.10)
        let haloAlpha: CGFloat = isIdle ? 0.02 : (isActive ? 0.15 : 0.04)
        let fillAlpha: CGFloat = isIdle ? 0.25 : (isActive ? 1.0 : 0.50)
        let rimAlpha: CGFloat = isIdle ? 0.08 : (isActive ? 0.40 : 0.16)

        color.withAlphaComponent(glowAlpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 52, y: center.y - 52, width: 104, height: 104)).fill()
        color.withAlphaComponent(haloAlpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 59, y: center.y - 59, width: 118, height: 118)).fill()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.34)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -3)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        color.withAlphaComponent(fillAlpha).setFill()
        let bulb = NSBezierPath(ovalIn: NSRect(x: center.x - 38, y: center.y - 38, width: 76, height: 76))
        bulb.fill()
        NSGraphicsContext.restoreGraphicsState()

        let rim = NSBezierPath(ovalIn: NSRect(x: center.x - 43, y: center.y - 43, width: 86, height: 86))
        color.withAlphaComponent(rimAlpha).setStroke()
        rim.lineWidth = 7
        rim.stroke()

        NSColor.black.withAlphaComponent(0.22).setStroke()
        bulb.lineWidth = 2
        bulb.stroke()

        NSColor.white.withAlphaComponent(isActive ? 0.24 : 0.10).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 17, y: center.y + 15, width: 28, height: 11)).fill()
    }

    func drawTopText(_ text: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.44),
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .paragraphStyle: style
        ]
        text.draw(in: rect, withAttributes: attrs)
    }

    func drawBottomText(_ text: String, rect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.60),
            .font: NSFont.systemFont(ofSize: 22, weight: .regular),
            .paragraphStyle: style
        ]
        text.draw(in: rect, withAttributes: attrs)
    }

    func closeButtonRect() -> NSRect {
        NSRect(x: designWidth - 45, y: designHeight - 47, width: 20, height: 20)
    }

    func muteButtonRect() -> NSRect {
        NSRect(x: 39, y: 46, width: 15, height: 15)
    }

    func drawCloseButton() {
        let rect = closeButtonRect()
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.white.withAlphaComponent(0.34).setStroke()
        let xPath = NSBezierPath()
        xPath.move(to: NSPoint(x: rect.minX + 7, y: rect.minY + 7))
        xPath.line(to: NSPoint(x: rect.maxX - 7, y: rect.maxY - 7))
        xPath.move(to: NSPoint(x: rect.maxX - 7, y: rect.minY + 7))
        xPath.line(to: NSPoint(x: rect.minX + 7, y: rect.maxY - 7))
        xPath.lineWidth = 2
        xPath.lineCapStyle = .round
        xPath.stroke()
    }

    func drawMuteButton() {
        let rect = muteButtonRect()
        NSColor.white.withAlphaComponent(isMuted ? 0.20 : 0.08).setFill()
        NSBezierPath(ovalIn: rect).fill()
        if isMuted {
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 4, y: rect.minY + 4))
            slash.line(to: NSPoint(x: rect.maxX - 4, y: rect.maxY - 4))
            slash.lineWidth = 1.4
            slash.lineCapStyle = .round
            slash.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = designPoint(from: event.locationInWindow)
        if muteButtonRect().contains(point) {
            onMuteToggle?()
            return
        }
        if closeButtonRect().contains(point) {
            onClose?()
            return
        }
        if event.clickCount == 2 {
            cycleState()
            return
        }
        dragStart = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = ownerWindow, let start = dragStart else { return }
        let current = event.locationInWindow
        var frame = window.frame
        frame.origin.x += current.x - start.x
        frame.origin.y += current.y - start.y
        window.setFrameOrigin(frame.origin)
        updatePreference("window_x", value: Double(frame.origin.x))
        updatePreference("window_y", value: Double(frame.origin.y))
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "黄灯：正在干活", action: #selector(AppDelegate.setWorking), keyEquivalent: "")
        menu.addItem(withTitle: "绿灯：完成验收", action: #selector(AppDelegate.setDone), keyEquivalent: "")
        menu.addItem(withTitle: "红灯：等你回复", action: #selector(AppDelegate.setWaiting), keyEquivalent: "")
        menu.addItem(withTitle: "空闲：都变暗", action: #selector(AppDelegate.setIdle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: isMuted ? "取消静音" : "静音", action: #selector(AppDelegate.toggleMuteFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "退出", action: #selector(AppDelegate.quit), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func designPoint(from point: NSPoint) -> NSPoint {
        NSPoint(x: point.x / uiScale, y: point.y / uiScale)
    }

    func cycleState() {
        let index = stateOrder.firstIndex(of: state) ?? 0
        onStateCommand?(stateOrder[(index + 1) % stateOrder.count])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: TrafficLightView!
    var lastModified = Date.distantPast
    var waitingBlinkStopTimer: Timer?
    var doneAutoIdleTimer: Timer?
    let soundController = SoundController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureRuntime()
        if !FileManager.default.fileExists(atPath: stateFile.path) {
            writeState("idle")
        }
        if readState() == "quit" {
            writeState("idle")
        }

        view = TrafficLightView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        let origin = initialWindowOrigin()
        window = NSWindow(contentRect: NSRect(x: origin.x, y: origin.y, width: windowWidth, height: windowHeight), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.level = .floating
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view
        view.ownerWindow = window
        view.onStateCommand = { [weak self] state in self?.setState(state) }
        view.onMuteToggle = { [weak self] in self?.toggleMute() }
        view.onClose = { [weak self] in self?.quit() }
        window.makeKeyAndOrderFront(nil)
        soundController.apply(state: view.state, playPrompt: false)

        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollState() }
        Timer.scheduledTimer(withTimeInterval: 0.52, repeats: true) { [weak self] _ in self?.blink() }
    }

    func initialWindowOrigin() -> NSPoint {
        if let x = readDoublePreference("window_x"), let y = readDoublePreference("window_y") {
            return NSPoint(x: x, y: y)
        }
        guard let screen = NSScreen.main else {
            return NSPoint(x: 1280, y: 540)
        }
        return NSPoint(x: screen.visibleFrame.maxX - windowWidth - 28, y: screen.visibleFrame.midY - windowHeight / 2)
    }

    func pollState() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: stateFile.path)
        let modified = attrs?[.modificationDate] as? Date ?? Date.distantPast
        guard modified != lastModified else { return }
        lastModified = modified
        let next = readState()
        if next == "quit" {
            soundController.stopAll()
            NSApp.terminate(nil)
            return
        }
        if next != view.state || next == "waiting" {
            applyState(next, playPrompt: true, writeFile: false)
        }
    }

    func blink() {
        guard view.state == "waiting" && view.waitingAlertActive else {
            if !view.blinkOn {
                view.blinkOn = true
                view.needsDisplay = true
            }
            return
        }
        view.blinkOn.toggle()
        view.needsDisplay = true
    }

    @objc func setWorking() { setState("working") }
    @objc func setDone() { setState("done") }
    @objc func setWaiting() { setState("waiting") }
    @objc func setIdle() { setState("idle") }
    @objc func toggleMuteFromMenu() { toggleMute() }
    @objc func quit() {
        soundController.stopAll()
        writeState("quit")
        NSApp.terminate(nil)
    }

    func setState(_ state: String) {
        applyState(state, playPrompt: true, writeFile: true)
    }

    func applyState(_ state: String, playPrompt: Bool, writeFile: Bool) {
        if writeFile {
            writeState(state)
        }
        view.state = state
        view.blinkOn = true
        if state == "waiting" {
            startWaitingBlinkTimer()
        } else {
            stopWaitingBlinkTimer()
        }
        if state == "done" {
            startDoneAutoIdleTimer()
        } else {
            stopDoneAutoIdleTimer()
        }
        view.isMuted = soundController.muted
        view.needsDisplay = true
        soundController.apply(state: state, playPrompt: playPrompt)
    }

    func startWaitingBlinkTimer() {
        waitingBlinkStopTimer?.invalidate()
        view.waitingAlertActive = true
        waitingBlinkStopTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.view.waitingAlertActive = false
            self?.view.blinkOn = true
            self?.view.needsDisplay = true
        }
    }

    func stopWaitingBlinkTimer() {
        waitingBlinkStopTimer?.invalidate()
        waitingBlinkStopTimer = nil
        view.waitingAlertActive = false
    }

    func startDoneAutoIdleTimer() {
        doneAutoIdleTimer?.invalidate()
        doneAutoIdleTimer = Timer.scheduledTimer(withTimeInterval: doneAutoIdleSeconds, repeats: false) { [weak self] _ in
            guard let self, self.view.state == "done" else { return }
            self.applyState("idle", playPrompt: false, writeFile: true)
        }
    }

    func stopDoneAutoIdleTimer() {
        doneAutoIdleTimer?.invalidate()
        doneAutoIdleTimer = nil
    }

    func toggleMute() {
        let nextMuted = !soundController.muted
        soundController.setMuted(nextMuted)
        view.isMuted = nextMuted
        view.needsDisplay = true
        if !nextMuted {
            soundController.apply(state: view.state, playPrompt: false)
        }
    }
}

func ensureRuntime() {
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
}

func writeState(_ state: String) {
    ensureRuntime()
    let body: [String: Any] = ["state": state, "updated_at": Date().timeIntervalSince1970]
    if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]) {
        try? data.write(to: stateFile)
    }
}

func readState() -> String {
    guard let data = try? Data(contentsOf: stateFile),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let state = object["state"] as? String else {
        return "idle"
    }
    return labels.keys.contains(state) || state == "quit" ? state : "idle"
}

func readPreferences() -> [String: Any] {
    guard let data = try? Data(contentsOf: preferencesFile),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return object
}

func writePreferences(_ prefs: [String: Any]) {
    ensureRuntime()
    if let data = try? JSONSerialization.data(withJSONObject: prefs, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: preferencesFile)
    }
}

func updatePreference(_ key: String, value: Any) {
    var prefs = readPreferences()
    prefs[key] = value
    prefs["updated_at"] = Date().timeIntervalSince1970
    writePreferences(prefs)
}

func readBoolPreference(_ key: String) -> Bool? {
    readPreferences()[key] as? Bool
}

func readDoublePreference(_ key: String) -> Double? {
    if let value = readPreferences()[key] as? Double {
        return value
    }
    if let value = readPreferences()[key] as? Int {
        return Double(value)
    }
    return nil
}

func readCGFloatPreference(_ key: String) -> CGFloat? {
    guard let value = readDoublePreference(key) else { return nil }
    return CGFloat(value)
}

extension NSColor {
    convenience init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)
        let red = CGFloat((value >> 16) & 0xff) / 255
        let green = CGFloat((value >> 8) & 0xff) / 255
        let blue = CGFloat(value & 0xff) / 255
        self.init(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
