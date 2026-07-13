import Cocoa
import Darwin
import Foundation

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodexStatusLight")
let stateFile = supportDir.appendingPathComponent("state.json")
let preferencesFile = supportDir.appendingPathComponent("preferences.json")
let instanceLockFile = supportDir.appendingPathComponent("instance.lock")
let codexHomeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
let codexStateDatabase = codexHomeDir.appendingPathComponent("state_5.sqlite")
let codexSessionsDir = codexHomeDir.appendingPathComponent("sessions")
let codexArchivedSessionsDir = codexHomeDir.appendingPathComponent("archived_sessions")
var instanceLockFD: Int32 = -1
var codexThreadOpenabilityCache: [String: (openable: Bool, checkedAt: TimeInterval)] = [:]
// Pointer movement and animation callbacks run at high frequency. Keep their
// state/preferences lookups in memory; pollState invalidates state caches.
var cachedStateObject: [String: Any]?
var cachedPreferences: [String: Any]?

let labels: [String: String] = [
    "working": "正在干活",
    "done": "可以验收",
    "waiting": "等你回复",
    "idle": "空闲"
]

let stateOrder = ["working", "done", "waiting", "idle"]
let baseDesignWidth: CGFloat = 162
let baseDesignHeight: CGFloat = 384
let sidebarDesignWidth: CGFloat = 34
let sidebarDesignHeight: CGFloat = 96
let sidebarWidthInset: CGFloat = 3
let sidebarPixelBlockSize: CGFloat = 28
let sidebarPixelBlockGap: CGFloat = 1
let sidebarSnapDistance: CGFloat = 32
let sidebarPreferenceKey = "sidebar_edge"
let sidebarYPreferenceKey = "sidebar_y"
let fiveHourQuotaPanelWidth: CGFloat = 12
let fiveHourQuotaPreferenceKey = "five_hour_quota_visible"
var uiScale: CGFloat = readCGFloatPreference("scale") ?? 0.74
let minUIScale: CGFloat = 0.48
let maxUIScale: CGFloat = 1.35
let defaultSessionStaleSeconds: TimeInterval = 6 * 60 * 60
let realTrafficLightAssetPrefix = "traffic-light-real"

func currentWindowSize() -> NSSize {
    if sidebarEdgePreference() != nil {
        return windowSize(sidebar: true)
    }
    return windowSize(sidebar: false)
}

func windowSize(sidebar: Bool) -> NSSize {
    if sidebar {
        return NSSize(width: sidebarDesignWidth * uiScale, height: sidebarDesignHeight * uiScale)
    }
    return NSSize(width: currentDesignWidth() * uiScale, height: currentDesignHeight() * uiScale)
}

func currentDesignWidth() -> CGFloat {
    baseDesignWidth + (fiveHourQuotaVisible() ? fiveHourQuotaPanelWidth : 0)
}

func currentDesignHeight() -> CGFloat {
    baseDesignHeight
}

func fiveHourQuotaVisible() -> Bool {
    readBoolPreference(fiveHourQuotaPreferenceKey) ?? true
}

func sidebarEdgePreference() -> String? {
    guard let edge = readStringPreference(sidebarPreferenceKey),
          edge == "left" || edge == "right" else {
        return nil
    }
    return edge
}

func visibleScreen(for frame: NSRect) -> NSScreen? {
    NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main
}

func clampedOriginForVisibleScreen(_ origin: NSPoint, size: NSSize) -> NSPoint {
    let testFrame = NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
    guard let screen = visibleScreen(for: testFrame) else {
        return origin
    }
    let frame = screen.visibleFrame
    let x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
    let y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
    return NSPoint(x: x, y: y)
}

func sidebarOrigin(edge: String, preferredMidY: CGFloat?, size: NSSize, screen: NSScreen) -> NSPoint {
    let frame = screen.visibleFrame
    let x = edge == "left" ? frame.minX : frame.maxX - size.width
    let midY = preferredMidY ?? frame.midY
    let y = min(max(midY - size.height / 2, frame.minY + 8), frame.maxY - size.height - 8)
    return NSPoint(x: x, y: y)
}

func sidebarTargetEdge(for frame: NSRect) -> String? {
    guard let screen = visibleScreen(for: frame) else { return nil }
    let visible = screen.visibleFrame
    if frame.minX <= visible.minX + sidebarSnapDistance {
        return "left"
    }
    if frame.maxX >= visible.maxX - sidebarSnapDistance {
        return "right"
    }
    return nil
}

func blinkEnabledKey(for light: String) -> String {
    "blink_\(light)_enabled"
}

func blinkFrequencyKey(for light: String) -> String {
    "blink_\(light)_frequency"
}

func defaultBlinkEnabled(for light: String) -> Bool {
    light == "red"
}

func isBlinkEnabled(for light: String) -> Bool {
    readBoolPreference(blinkEnabledKey(for: light)) ?? defaultBlinkEnabled(for: light)
}

func blinkFrequency(for light: String) -> CGFloat {
    CGFloat(readDoublePreference(blinkFrequencyKey(for: light)) ?? 1.35)
}

func effectiveBlinkFrequency(for light: String) -> CGFloat {
    guard light == "red", readBoolPreference("smart_red_blink") ?? true,
          let waiting = latestAttentionSession(for: "waiting"),
          !waiting.isAcknowledged else {
        return blinkFrequency(for: light)
    }
    let age = Date().timeIntervalSince1970 - waiting.updatedAt
    let threshold = readDoublePreference("red_blink_escalate_after_seconds") ?? 30
    guard age >= threshold else { return blinkFrequency(for: light) }
    let fastFrequency = readDoublePreference("red_blink_fast_frequency") ?? 2.6
    return max(blinkFrequency(for: light), CGFloat(fastFrequency))
}

func sessionStaleInterval() -> TimeInterval {
    max(60, readDoublePreference("session_stale_seconds") ?? defaultSessionStaleSeconds)
}

func clickAcknowledgesSessions() -> Bool {
    readBoolPreference("click_acknowledges_sessions") ?? true
}

func stateName(for light: String) -> String {
    switch light {
    case "red": return "waiting"
    case "yellow": return "working"
    case "green": return "done"
    default: return "idle"
    }
}

func displayName(for light: String) -> String {
    switch light {
    case "red": return "红灯"
    case "yellow": return "黄灯"
    case "green": return "绿灯"
    default: return light
    }
}

struct StatusSession {
    let id: String
    let state: String
    let updatedAt: TimeInterval
    let acknowledgedAt: TimeInterval
    let title: String?
    let cwd: String?
    let preview: String?
    let sourceEvent: String?
    let toolName: String?
    let model: String?
    let transcriptPath: String?
    let rateLimitPrimaryUsedPercent: Double?
    let rateLimitPrimaryRemainingPercent: Double?
    let rateLimitPrimaryResetsAt: TimeInterval?
    let rateLimitPrimaryWindowMinutes: Double?
    let rateLimitName: String?
    let rateLimitPlanType: String?

    var isAcknowledged: Bool {
        acknowledgedAt >= updatedAt
    }

    var fiveHourQuota: FiveHourQuota? {
        guard let resetsAt = rateLimitPrimaryResetsAt else { return nil }
        let window = rateLimitPrimaryWindowMinutes ?? 300
        guard window >= 295 && window <= 305 else { return nil }
        let remaining = rateLimitPrimaryRemainingPercent ?? rateLimitPrimaryUsedPercent.map { 100 - $0 }
        guard let remaining else { return nil }
        return FiveHourQuota(
            remainingPercent: min(max(remaining, 0), 100),
            usedPercent: min(max(rateLimitPrimaryUsedPercent ?? 100 - remaining, 0), 100),
            resetsAt: resetsAt,
            limitName: rateLimitName,
            planType: rateLimitPlanType
        )
    }

    var displayTitle: String {
        for value in [title, cwd?.components(separatedBy: "/").last, preview] {
            if let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return clipped(text, limit: 42)
            }
        }
        return shortSessionID(id)
    }

    var detailTitle: String {
        let age = relativeAge(from: updatedAt)
        let ack = isAcknowledged ? "已看" : "未看"
        if let cwd, !cwd.isEmpty {
            return "\(age) · \(ack) · \(clipped(cwd, limit: 54))"
        }
        if let sourceEvent, !sourceEvent.isEmpty {
            return "\(age) · \(ack) · \(sourceEvent)"
        }
        return "\(age) · \(ack)"
    }

    var menuTitle: String {
        if let quota = fiveHourQuota {
            return "\(displayTitle)  \(detailTitle)  · 5H \(quota.percentText) \(quota.resetTimeText)"
        }
        return "\(displayTitle)  \(detailTitle)"
    }
}

struct FiveHourQuota {
    let remainingPercent: Double
    let usedPercent: Double
    let resetsAt: TimeInterval
    let limitName: String?
    let planType: String?

    var percentText: String {
        "\(Int(round(remainingPercent)))%"
    }

    var resetTimeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: resetsAt))
    }

    var detailText: String {
        "5小时额度剩余 \(percentText)，\(resetTimeText) 重刷"
    }
}

var cachedActiveSessions: [StatusSession]?
var cachedFiveHourQuota: FiveHourQuota?
var hasCachedFiveHourQuota = false

func clipped(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    let end = text.index(text.startIndex, offsetBy: max(1, limit - 1))
    return String(text[..<end]) + "…"
}

func shortSessionID(_ id: String) -> String {
    guard id.count > 8 else { return id }
    return String(id.prefix(8))
}

func relativeAge(from timestamp: TimeInterval) -> String {
    let age = max(0, Date().timeIntervalSince1970 - timestamp)
    if age < 60 {
        return "\(Int(age))秒前"
    }
    if age < 60 * 60 {
        return "\(Int(age / 60))分钟前"
    }
    return "\(Int(age / 3600))小时前"
}

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
    static let realTrafficLightImages = loadRealTrafficLightImages()

    var state = readState()
    var blinkOn = true
    var waitingAlertActive = false
    var isMuted = readBoolPreference("muted") ?? false
    var animationPhase: CGFloat = 0
    var dragStart: NSPoint?
    var didDrag = false
    var trackingArea: NSTrackingArea?
    var isHoveringResizeHandle = false
    var isResizing = false
    var resizeStartMouse = NSPoint.zero
    var resizeStartFrame = NSRect.zero
    var resizeStartScale: CGFloat = uiScale
    var openFeedbackLight: String?
    var openFeedbackUntil = Date.distantPast
    var openFeedbackTitle: String?
    var onStateCommand: ((String) -> Void)?
    var onSidebarEdgeChange: ((String?) -> Void)?
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

        if sidebarEdgePreference() != nil {
            drawSidebarTrafficLight()
        } else if Self.realTrafficLightImages["idle"] != nil {
            drawPhotoTrafficLight()
        } else {
            let body = NSRect(x: 14, y: 8, width: 134, height: 368)
            drawHousing(body)
            drawLamp(center: NSPoint(x: 81, y: 306), light: "red", intensity: intensity(for: "red"))
            drawLamp(center: NSPoint(x: 81, y: 192), light: "yellow", intensity: intensity(for: "yellow"))
            drawLamp(center: NSPoint(x: 81, y: 78), light: "green", intensity: intensity(for: "green"))
        }

        if sidebarEdgePreference() == nil {
            drawFiveHourQuotaPanel()
        }
        drawOpenFeedback()
        NSGraphicsContext.restoreGraphicsState()

        if sidebarEdgePreference() == nil && (isHoveringResizeHandle || isResizing) {
            drawResizeHandle()
        }
    }

    func activeLight() -> String {
        visibleLights().first ?? ""
    }

    func visibleLights() -> [String] {
        var lights: [String] = []
        if !attentionSessions(for: "waiting").isEmpty {
            lights.append("red")
        }
        if !activeSessions(for: "working").isEmpty {
            lights.append("yellow")
        }
        if !attentionSessions(for: "done").isEmpty {
            lights.append("green")
        }
        if !lights.isEmpty {
            return lights
        }

        switch state {
        case "waiting": return ["red"]
        case "working": return ["yellow"]
        case "done": return ["green"]
        default: return []
        }
    }

    func isLightVisible(_ light: String) -> Bool {
        visibleLights().contains(light)
    }

    func intensity(for light: String) -> CGFloat {
        guard isLightVisible(light) else { return 0.10 }
        if shouldBlink(for: light) {
            let cycle = fmod(animationPhase * effectiveBlinkFrequency(for: light), 1)
            if cycle < 0.5 {
                return 0.16 + 0.84 * easeOut(cycle / 0.5)
            }
            return 0.16 + 0.84 * easeIn(1 - ((cycle - 0.5) / 0.5))
        }
        return 1.0
    }

    func easeOut(_ x: CGFloat) -> CGFloat {
        1 - pow(1 - min(max(x, 0), 1), 3)
    }

    func easeIn(_ x: CGFloat) -> CGFloat {
        pow(min(max(x, 0), 1), 2)
    }

    func baseColorFor(_ light: String) -> NSColor {
        switch light {
        case "red": return NSColor(hex: "#d71912")
        case "yellow": return NSColor(hex: "#f2b705")
        case "green": return NSColor(hex: "#08a94f")
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

    func drawPhotoTrafficLight() {
        let imageRect = photoImageRect()
        let idleImage = Self.realTrafficLightImages["idle"]
        idleImage?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])

        for light in ["red", "yellow", "green"] where isLightVisible(light) {
            let stateImage = Self.realTrafficLightImages[stateName(for: light)]
            guard let stateImage else { continue }
            let sectionRect = photoLampSectionRect(for: light, imageRect: imageRect)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: sectionRect).addClip()
            stateImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: intensity(for: light), respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    func photoImageRect() -> NSRect {
        NSRect(x: 12, y: 5, width: 138, height: 378)
    }

    func fiveHourQuotaPanelRect() -> NSRect {
        NSRect(x: baseDesignWidth - 8, y: 24, width: 8, height: baseDesignHeight - 48)
    }

    func drawFiveHourQuotaPanel() {
        guard fiveHourQuotaVisible() else { return }

        let rect = fiveHourQuotaPanelRect()
        let quota = latestFiveHourQuota()
        let accent = quotaAccentColor(for: quota)
        let track = NSRect(x: rect.midX - 1, y: rect.minY, width: 2, height: rect.height)
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
        if let quota {
            let fillHeight = max(3, track.height * CGFloat(quota.remainingPercent / 100.0))
            let fill = NSRect(x: track.minX, y: track.minY, width: track.width, height: fillHeight)
            accent.withAlphaComponent(0.88).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
        }
    }

    func sidebarBodyRect() -> NSRect {
        let width = sidebarPixelBlockSize + 4
        let height = sidebarPixelBlockSize * 3 + sidebarPixelBlockGap * 2 + 4
        let y = (sidebarDesignHeight - height) / 2
        if sidebarEdgePreference() == "left" {
            return NSRect(x: 0, y: y, width: width, height: height)
        }
        return NSRect(x: sidebarDesignWidth - width, y: y, width: width, height: height)
    }

    func sidebarLampRect(for light: String) -> NSRect {
        let body = sidebarBodyRect()
        let index: CGFloat
        switch light {
        case "red": index = 2
        case "yellow": index = 1
        case "green": index = 0
        default: index = 1
        }
        let x = body.midX - sidebarPixelBlockSize / 2
        let y = body.minY + 2 + index * (sidebarPixelBlockSize + sidebarPixelBlockGap)
        return NSRect(x: x, y: y, width: sidebarPixelBlockSize, height: sidebarPixelBlockSize)
    }

    func drawSidebarTrafficLight() {
        let edge = sidebarEdgePreference() ?? "right"
        let body = sidebarBodyRect()
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(rect: body).fill()

        let inner = body.insetBy(dx: 1, dy: 1)
        NSColor(hex: "#111311").withAlphaComponent(0.94).setFill()
        NSBezierPath(rect: inner).fill()

        let dockWidth: CGFloat = 2
        let dockX = edge == "left" ? body.minX : body.maxX - dockWidth
        NSColor.black.withAlphaComponent(0.92).setFill()
        NSBezierPath(rect: NSRect(x: dockX, y: body.minY, width: dockWidth, height: body.height)).fill()

        for light in ["red", "yellow", "green"] {
            drawSidebarLamp(light: light, rect: sidebarLampRect(for: light), intensity: intensity(for: light))
        }
    }

    func drawSidebarLamp(light: String, rect: NSRect, intensity: CGFloat) {
        let active = isLightVisible(light) || stateName(for: light) == state
        let color = sidebarPixelColor(for: light, active: active)
        let brightness = active ? max(0.62, intensity) : 0.18
        let fill = color.blended(withFraction: active ? 0.05 : 0.78, of: NSColor.black) ?? color

        if active {
            color.withAlphaComponent(0.16 * intensity).setFill()
            NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2)).fill()
        }

        fill.withAlphaComponent(brightness).setFill()
        NSBezierPath(rect: rect).fill()

        NSColor.black.withAlphaComponent(0.70).setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.stroke()

        let topLeft = NSRect(x: rect.minX + 3, y: rect.maxY - 8, width: rect.width - 7, height: 4)
        NSColor.white.withAlphaComponent(active ? 0.26 * brightness : 0.035).setFill()
        NSBezierPath(rect: topLeft).fill()

        let rightShade = NSRect(x: rect.maxX - 5, y: rect.minY + 4, width: 2, height: rect.height - 8)
        NSColor.black.withAlphaComponent(active ? 0.22 : 0.52).setFill()
        NSBezierPath(rect: rightShade).fill()
    }

    func sidebarPixelColor(for light: String, active: Bool) -> NSColor {
        guard active else { return baseColorFor(light) }
        switch light {
        case "red": return NSColor(hex: "#ff3026")
        case "yellow": return NSColor(hex: "#ffd11a")
        case "green": return NSColor(hex: "#22e66c")
        default: return baseColorFor(light)
        }
    }

    func quotaAccentColor(for quota: FiveHourQuota?) -> NSColor {
        guard quota != nil else {
            return NSColor(hex: "#8c9494")
        }
        return NSColor(hex: "#2fe078")
    }

    func shouldBlink(for light: String) -> Bool {
        guard isBlinkEnabled(for: light) else { return false }
        return lightNeedsAttention(light)
    }

    func lightNeedsAttention(_ light: String) -> Bool {
        !attentionSessions(for: stateName(for: light)).isEmpty
    }

    func hasOpenFeedback() -> Bool {
        openFeedbackLight != nil && Date() < openFeedbackUntil
    }

    func showOpenFeedback(light: String, session: StatusSession) {
        openFeedbackLight = light
        openFeedbackTitle = session.displayTitle
        openFeedbackUntil = Date().addingTimeInterval(0.7)
        toolTip = "已打开：\(session.displayTitle)"
        needsDisplay = true
    }

    func drawOpenFeedback() {
        guard hasOpenFeedback(), let light = openFeedbackLight else { return }
        let rect: NSRect
        if sidebarEdgePreference() != nil {
            rect = sidebarLampRect(for: light).insetBy(dx: -5, dy: -5)
        } else {
            let imageRect = photoImageRect()
            rect = photoLampRect(for: light, imageRect: imageRect).insetBy(dx: -5, dy: -5)
        }
        let progress = CGFloat(max(0, min(1, openFeedbackUntil.timeIntervalSinceNow / 0.7)))
        let alpha = 0.18 + 0.36 * progress

        NSColor.white.withAlphaComponent(alpha).setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -2 + 5 * (1 - progress), dy: -2 + 5 * (1 - progress)))
        ring.lineWidth = 2.2
        ring.stroke()

        let check = NSBezierPath()
        let center = NSPoint(x: rect.midX, y: rect.midY)
        check.move(to: NSPoint(x: center.x - 13, y: center.y - 1))
        check.line(to: NSPoint(x: center.x - 4, y: center.y - 10))
        check.line(to: NSPoint(x: center.x + 15, y: center.y + 12))
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.lineWidth = 3.0
        NSColor.white.withAlphaComponent(alpha).setStroke()
        check.stroke()
    }

    func photoLampRect(for light: String, imageRect: NSRect) -> NSRect {
        let normalizedY: CGFloat
        switch light {
        case "red": normalizedY = 0.834
        case "yellow": normalizedY = 0.528
        case "green": normalizedY = 0.183
        default: normalizedY = 0.5
        }
        let center = NSPoint(x: imageRect.midX, y: imageRect.minY + imageRect.height * normalizedY)
        let radius = imageRect.height * 0.114
        return NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    func photoLampSectionRect(for light: String, imageRect: NSRect) -> NSRect {
        switch light {
        case "red":
            return NSRect(x: imageRect.minX, y: imageRect.minY + imageRect.height * 0.665, width: imageRect.width, height: imageRect.height * 0.335)
        case "yellow":
            return NSRect(x: imageRect.minX, y: imageRect.minY + imageRect.height * 0.335, width: imageRect.width, height: imageRect.height * 0.335)
        case "green":
            return NSRect(x: imageRect.minX, y: imageRect.minY, width: imageRect.width, height: imageRect.height * 0.36)
        default:
            return imageRect
        }
    }

    func drawPhotoLampBreath(in rect: NSRect, color: NSColor, intensity: CGFloat) {
        let normalized = min(max((intensity - 0.82) / 0.165, 0), 1)
        let lens = NSBezierPath(ovalIn: rect)
        let center = NSPoint(x: rect.midX, y: rect.midY)

        NSGraphicsContext.saveGraphicsState()
        lens.addClip()
        NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.10 + 0.12 * normalized),
            color.withAlphaComponent(0.08 + 0.10 * normalized),
            NSColor.clear
        ])?.draw(in: lens, relativeCenterPosition: NSPoint(x: -0.08, y: -0.05))
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.18 + 0.18 * normalized).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)).fill()
        color.withAlphaComponent(0.08 + 0.08 * normalized).setStroke()
        let glint = NSBezierPath()
        glint.move(to: NSPoint(x: center.x - 12, y: center.y))
        glint.line(to: NSPoint(x: center.x + 12, y: center.y))
        glint.move(to: NSPoint(x: center.x, y: center.y - 12))
        glint.line(to: NSPoint(x: center.x, y: center.y + 12))
        glint.lineWidth = 0.7
        glint.stroke()
    }

    func drawHousing(_ rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: NSColor(hex: "#20211f"), ending: NSColor(hex: "#050605"))?.draw(in: rect, angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.78).setStroke()
        path.lineWidth = 3
        path.stroke()

        NSColor.white.withAlphaComponent(0.08).setStroke()
        let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4)
        inner.lineWidth = 1
        inner.stroke()

        NSColor.black.withAlphaComponent(0.48).setStroke()
        for y in [rect.minY + 123, rect.minY + 245] {
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: rect.minX + 2, y: y))
            divider.line(to: NSPoint(x: rect.maxX - 2, y: y))
            divider.lineWidth = 2
            divider.stroke()
            NSColor.white.withAlphaComponent(0.045).setStroke()
            let highlight = NSBezierPath()
            highlight.move(to: NSPoint(x: rect.minX + 4, y: y + 1.5))
            highlight.line(to: NSPoint(x: rect.maxX - 4, y: y + 1.5))
            highlight.lineWidth = 1
            highlight.stroke()
            NSColor.black.withAlphaComponent(0.48).setStroke()
        }

        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.maxX - 8, y: rect.minY + 10, width: 2, height: rect.height - 20), xRadius: 1, yRadius: 1).fill()

        NSColor.black.withAlphaComponent(0.42).setFill()
        for y in [rect.minY + 62, rect.minY + 184, rect.minY + 306] {
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 8, y: y, width: 5, height: 5)).fill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 13, y: y, width: 5, height: 5)).fill()
        }

        NSColor.white.withAlphaComponent(0.035).setStroke()
        for x in stride(from: rect.minX + 18, through: rect.maxX - 18, by: 13) {
            let grain = NSBezierPath()
            grain.move(to: NSPoint(x: x, y: rect.minY + 14))
            grain.line(to: NSPoint(x: x + 8, y: rect.maxY - 14))
            grain.lineWidth = 0.35
            grain.stroke()
        }
    }

    func drawLamp(center: NSPoint, light: String, intensity: CGFloat) {
        let color = baseColorFor(light)
        let active = intensity > 0.25
        let lensRadius: CGFloat = 42
        let lensRect = NSRect(x: center.x - lensRadius, y: center.y - lensRadius, width: lensRadius * 2, height: lensRadius * 2)
        let outerRingRect = lensRect.insetBy(dx: -9, dy: -9)
        let innerCavityRect = lensRect.insetBy(dx: -3, dy: -3)

        drawVisor(center: center, color: color, active: active, intensity: intensity)

        drawOuterBezel(in: outerRingRect, color: color, active: active, intensity: intensity)
        drawInnerCavity(in: innerCavityRect)
        drawGlassLens(in: lensRect, color: color, active: active, intensity: intensity)
        drawLensFasteners(around: lensRect)
        drawGlassReflection(in: lensRect, intensity: intensity)
    }

    func drawVisor(center: NSPoint, color: NSColor, active: Bool, intensity: CGFloat) {
        let castShadow = NSShadow()
        castShadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
        castShadow.shadowBlurRadius = 7
        castShadow.shadowOffset = NSSize(width: 0, height: -2)

        NSGraphicsContext.saveGraphicsState()
        castShadow.set()
        NSColor.black.withAlphaComponent(0.86).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 55, y: center.y - 48, width: 110, height: 100)).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(hex: "#11120f").setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 51, y: center.y - 44, width: 102, height: 94)).fill()

        color.withAlphaComponent(active ? 0.20 * intensity : 0.035).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 49, y: center.y - 42, width: 98, height: 90)).fill()

        NSColor.black.withAlphaComponent(0.60).setFill()
        let shade = NSBezierPath()
        shade.appendArc(withCenter: NSPoint(x: center.x, y: center.y + 2), radius: 54, startAngle: 0, endAngle: 180, clockwise: false)
        shade.line(to: NSPoint(x: center.x - 54, y: center.y + 2))
        shade.close()
        shade.fill()

        NSColor.white.withAlphaComponent(0.11).setStroke()
        let lip = NSBezierPath()
        lip.appendArc(withCenter: NSPoint(x: center.x, y: center.y + 1), radius: 53, startAngle: 20, endAngle: 160, clockwise: false)
        lip.lineWidth = 2
        lip.stroke()

        NSColor.black.withAlphaComponent(0.65).setFill()
        let hood = NSBezierPath()
        hood.appendArc(withCenter: NSPoint(x: center.x, y: center.y + 10), radius: 56, startAngle: 12, endAngle: 168, clockwise: false)
        hood.line(to: NSPoint(x: center.x - 45, y: center.y + 26))
        hood.curve(to: NSPoint(x: center.x + 45, y: center.y + 26),
                   controlPoint1: NSPoint(x: center.x - 20, y: center.y + 50),
                   controlPoint2: NSPoint(x: center.x + 20, y: center.y + 50))
        hood.close()
        hood.fill()

        NSColor.white.withAlphaComponent(0.10).setStroke()
        let hoodLip = NSBezierPath()
        hoodLip.appendArc(withCenter: NSPoint(x: center.x, y: center.y + 10), radius: 55, startAngle: 25, endAngle: 155, clockwise: false)
        hoodLip.lineWidth = 1
        hoodLip.stroke()
    }

    func drawLensFasteners(around rect: NSRect) {
        let points = [
            NSPoint(x: rect.minX + 12, y: rect.midY),
            NSPoint(x: rect.maxX - 12, y: rect.midY),
            NSPoint(x: rect.midX, y: rect.minY + 12),
            NSPoint(x: rect.midX, y: rect.maxY - 12)
        ]
        for point in points {
            NSColor.black.withAlphaComponent(0.36).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 2.2, y: point.y - 2.2, width: 4.4, height: 4.4)).fill()
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 0.8, y: point.y + 0.2, width: 1.6, height: 1.2)).fill()
        }
    }

    func drawOuterBezel(in rect: NSRect, color: NSColor, active: Bool, intensity: CGFloat) {
        let castShadow = NSShadow()
        castShadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
        castShadow.shadowBlurRadius = 7
        castShadow.shadowOffset = NSSize(width: 0, height: -3)

        let ring = NSBezierPath(ovalIn: rect)
        NSGraphicsContext.saveGraphicsState()
        castShadow.set()
        ring.addClip()
        NSGradient(colors: [
            NSColor(hex: "#2c2f2c"),
            NSColor(hex: "#050605"),
            NSColor(hex: "#151614")
        ])?.draw(in: rect, angle: 125)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.86).setStroke()
        ring.lineWidth = 5
        ring.stroke()

        NSColor.white.withAlphaComponent(0.10).setStroke()
        let topLip = NSBezierPath()
        topLip.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2 - 3, startAngle: 28, endAngle: 152, clockwise: false)
        topLip.lineWidth = 1.4
        topLip.stroke()

        color.withAlphaComponent(active ? 0.12 * intensity : 0.018).setStroke()
        let colorCatch = NSBezierPath()
        colorCatch.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2 - 7, startAngle: 195, endAngle: 345, clockwise: false)
        colorCatch.lineWidth = 2
        colorCatch.stroke()
    }

    func drawInnerCavity(in rect: NSRect) {
        let cavity = NSBezierPath(ovalIn: rect)
        NSGraphicsContext.saveGraphicsState()
        cavity.addClip()
        NSGradient(colors: [
            NSColor.black.withAlphaComponent(0.96),
            NSColor(hex: "#10110f"),
            NSColor.black.withAlphaComponent(0.88)
        ])?.draw(in: rect, angle: -55)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.78).setStroke()
        cavity.lineWidth = 4
        cavity.stroke()
    }

    func drawFresnelPattern(in rect: NSRect, color: NSColor, intensity: CGFloat) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        for radius in stride(from: CGFloat(8), through: CGFloat(38), by: CGFloat(5.2)) {
            NSColor.white.withAlphaComponent(0.030 + 0.075 * intensity).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            ring.lineWidth = 0.7
            ring.stroke()
        }

        for y in stride(from: rect.minY + 11, through: rect.maxY - 11, by: 7) {
            let rowOffset: CGFloat = Int((y - rect.minY) / 7).isMultiple(of: 2) ? 0 : 3.5
            for x in stride(from: rect.minX + 11 + rowOffset, through: rect.maxX - 11, by: 7) {
                let dx = x - center.x
                let dy = y - center.y
                let distance = hypot(dx, dy)
                guard distance < rect.width / 2 - 5 else { continue }
                let alpha = 0.045 + 0.10 * intensity * max(0, 1 - distance / 44)
                NSColor.white.withAlphaComponent(alpha).setStroke()
                let cell = NSBezierPath(ovalIn: NSRect(x: x - 2.0, y: y - 2.0, width: 4.0, height: 4.0))
                cell.lineWidth = 0.55
                cell.stroke()
                color.withAlphaComponent(0.035 + 0.055 * intensity).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)).fill()
            }
        }

        NSColor.black.withAlphaComponent(0.09).setStroke()
        for offset in stride(from: CGFloat(-34), through: CGFloat(34), by: CGFloat(8.5)) {
            let prism = NSBezierPath()
            prism.move(to: NSPoint(x: center.x + offset - 20, y: rect.minY + 9))
            prism.line(to: NSPoint(x: center.x + offset + 19, y: rect.maxY - 9))
            prism.lineWidth = 0.45
            prism.stroke()
        }
    }

    func drawGlassLens(in rect: NSRect, color: NSColor, active: Bool, intensity: CGFloat) {
        let lens = NSBezierPath(ovalIn: rect)
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(active ? 0.22 * intensity : 0.025)
        glow.shadowBlurRadius = active ? 9 * intensity : 2
        glow.shadowOffset = NSSize(width: 0, height: 0)

        let centerShift = NSPoint(x: -0.12, y: -0.08)
        let edgeColor = color.blended(withFraction: active ? 0.50 : 0.76, of: NSColor.black) ?? color
        let midColor = color.blended(withFraction: active ? 0.08 : 0.38, of: NSColor.black) ?? color
        let coreColor = color.blended(withFraction: active ? 0.08 : 0.03, of: NSColor.white) ?? color

        NSGraphicsContext.saveGraphicsState()
        glow.set()
        lens.addClip()
        NSGradient(colors: [
            coreColor.withAlphaComponent(active ? 0.98 : 0.44),
            midColor.withAlphaComponent(active ? 0.92 : 0.36),
            edgeColor.withAlphaComponent(active ? 0.88 : 0.48),
            NSColor.black.withAlphaComponent(active ? 0.36 : 0.58)
        ])?.draw(in: lens, relativeCenterPosition: centerShift)
        drawFresnelPattern(in: rect, color: color, intensity: intensity)
        drawEdgeVignette(in: rect, active: active)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.82).setStroke()
        lens.lineWidth = 2.2
        lens.stroke()

        color.blended(withFraction: 0.25, of: NSColor.white)?.withAlphaComponent(active ? 0.26 : 0.11).setStroke()
        let raisedLip = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
        raisedLip.lineWidth = 1.1
        raisedLip.stroke()

        drawHotspot(center: NSPoint(x: rect.midX, y: rect.midY), color: color, intensity: active ? intensity : 0.20)
    }

    func drawEdgeVignette(in rect: NSRect, active: Bool) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        for index in 0..<8 {
            let inset = CGFloat(index) * 1.2
            let alpha = (active ? 0.030 : 0.050) + CGFloat(index) * 0.010
            NSColor.black.withAlphaComponent(alpha).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: rect.minX + inset, y: rect.minY + inset, width: rect.width - inset * 2, height: rect.height - inset * 2))
            ring.lineWidth = 1.4
            ring.stroke()
        }

        NSColor.black.withAlphaComponent(active ? 0.16 : 0.26).setFill()
        let bottomShade = NSBezierPath()
        bottomShade.appendArc(withCenter: NSPoint(x: center.x, y: center.y - 2), radius: rect.width / 2 - 2, startAngle: 200, endAngle: 340, clockwise: false)
        bottomShade.curve(to: NSPoint(x: center.x - 28, y: center.y - 22),
                          controlPoint1: NSPoint(x: center.x + 20, y: center.y - 42),
                          controlPoint2: NSPoint(x: center.x - 20, y: center.y - 42))
        bottomShade.close()
        bottomShade.fill()
    }

    func drawGlassReflection(in rect: NSRect, intensity: CGFloat) {
        let alpha = 0.16 + 0.16 * min(max(intensity, 0), 1)

        NSColor.white.withAlphaComponent(alpha).setFill()
        let sideFlash = NSBezierPath()
        sideFlash.move(to: NSPoint(x: rect.midX + 23, y: rect.midY - 18))
        sideFlash.curve(to: NSPoint(x: rect.midX + 33, y: rect.midY - 3),
                         controlPoint1: NSPoint(x: rect.midX + 30, y: rect.midY - 15),
                         controlPoint2: NSPoint(x: rect.midX + 35, y: rect.midY - 10))
        sideFlash.curve(to: NSPoint(x: rect.midX + 27, y: rect.midY + 15),
                         controlPoint1: NSPoint(x: rect.midX + 33, y: rect.midY + 6),
                         controlPoint2: NSPoint(x: rect.midX + 32, y: rect.midY + 12))
        sideFlash.curve(to: NSPoint(x: rect.midX + 17, y: rect.midY + 5),
                         controlPoint1: NSPoint(x: rect.midX + 22, y: rect.midY + 14),
                         controlPoint2: NSPoint(x: rect.midX + 18, y: rect.midY + 10))
        sideFlash.curve(to: NSPoint(x: rect.midX + 23, y: rect.midY - 18),
                         controlPoint1: NSPoint(x: rect.midX + 19, y: rect.midY - 5),
                         controlPoint2: NSPoint(x: rect.midX + 20, y: rect.midY - 12))
        sideFlash.fill()

        NSColor.white.withAlphaComponent(0.10 + 0.08 * intensity).setFill()
        let smallFlash = NSBezierPath()
        smallFlash.move(to: NSPoint(x: rect.midX + 29, y: rect.midY - 29))
        smallFlash.curve(to: NSPoint(x: rect.midX + 35, y: rect.midY - 20),
                         controlPoint1: NSPoint(x: rect.midX + 34, y: rect.midY - 28),
                         controlPoint2: NSPoint(x: rect.midX + 36, y: rect.midY - 24))
        smallFlash.curve(to: NSPoint(x: rect.midX + 25, y: rect.midY - 21),
                         controlPoint1: NSPoint(x: rect.midX + 32, y: rect.midY - 18),
                         controlPoint2: NSPoint(x: rect.midX + 28, y: rect.midY - 18))
        smallFlash.close()
        smallFlash.fill()

        NSColor.white.withAlphaComponent(0.09 + 0.06 * intensity).setStroke()
        let topReflection = NSBezierPath()
        topReflection.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2 - 8, startAngle: 72, endAngle: 126, clockwise: false)
        topReflection.lineWidth = 2
        topReflection.stroke()
    }

    func drawHotspot(center: NSPoint, color: NSColor, intensity: CGFloat) {
        let clamped = min(max(intensity, 0), 1)
        color.blended(withFraction: 0.34, of: NSColor.white)?.withAlphaComponent(0.30 * clamped).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30)).fill()
        NSColor.white.withAlphaComponent(0.58 * clamped).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)).fill()
        NSColor.white.withAlphaComponent(0.30 * clamped).setStroke()
        let glint = NSBezierPath()
        glint.move(to: NSPoint(x: center.x - 10, y: center.y))
        glint.line(to: NSPoint(x: center.x + 10, y: center.y))
        glint.move(to: NSPoint(x: center.x, y: center.y - 10))
        glint.line(to: NSPoint(x: center.x, y: center.y + 10))
        glint.lineWidth = 0.8
        glint.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let nextTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
    }

    func resizeHandleRect() -> NSRect {
        if sidebarEdgePreference() != nil {
            return .zero
        }
        let side = min(max(bounds.width * 0.18, 22), 36)
        return NSRect(x: bounds.minX, y: bounds.minY, width: side, height: side)
    }

    func pointIsInResizeHandle(_ event: NSEvent) -> Bool {
        guard sidebarEdgePreference() == nil else { return false }
        return resizeHandleRect().contains(convert(event.locationInWindow, from: nil))
    }

    func updateResizeHandleHover(with event: NSEvent) {
        let hovering = pointIsInResizeHandle(event)
        guard hovering != isHoveringResizeHandle else { return }
        isHoveringResizeHandle = hovering
        if hovering {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        updateResizeHandleHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isResizing else { return }
        isHoveringResizeHandle = false
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        if pointIsInResizeHandle(event) {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    func drawResizeHandle() {
        let rect = resizeHandleRect().insetBy(dx: 4, dy: 4)
        NSColor.black.withAlphaComponent(0.34).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()

        NSColor.white.withAlphaComponent(isResizing ? 0.72 : 0.48).setStroke()
        for offset in stride(from: CGFloat(6), through: rect.width - 6, by: 6) {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX + offset, y: rect.minY + 3))
            line.line(to: NSPoint(x: rect.minX + 3, y: rect.minY + offset))
            line.lineWidth = 1.4
            line.lineCapStyle = .round
            line.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        if pointIsInResizeHandle(event), let window = ownerWindow {
            isResizing = true
            isHoveringResizeHandle = true
            resizeStartMouse = NSEvent.mouseLocation
            resizeStartFrame = window.frame
            resizeStartScale = uiScale
            didDrag = true
            needsDisplay = true
            return
        }
        if event.clickCount == 2 {
            cycleState()
            return
        }
        dragStart = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        if isResizing {
            isResizing = false
            updateResizeHandleHover(with: event)
            return
        }
        if didDrag {
            finishWindowDrag()
            return
        }
        guard !didDrag, event.clickCount == 1 else { return }
        if openClickedLampSession(with: event) {
            return
        }
        showStatusMenu(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isResizing {
            resizeWindow(to: NSEvent.mouseLocation)
            return
        }
        guard let window = ownerWindow, let start = dragStart else { return }
        let current = event.locationInWindow
        if hypot(current.x - start.x, current.y - start.y) > 3 {
            didDrag = true
        }
        var frame = window.frame
        frame.origin.x += current.x - start.x
        frame.origin.y += current.y - start.y
        window.setFrameOrigin(frame.origin)
        updatePreference("window_x", value: Double(frame.origin.x))
        updatePreference("window_y", value: Double(frame.origin.y))
    }

    func finishWindowDrag() {
        guard let window = ownerWindow else { return }
        let currentEdge = sidebarEdgePreference()
        let targetEdge = sidebarTargetEdge(for: window.frame)
        if let targetEdge {
            onSidebarEdgeChange?(targetEdge)
            return
        }
        if currentEdge != nil {
            onSidebarEdgeChange?(nil)
            return
        }
        let origin = clampedOriginForVisibleScreen(window.frame.origin, size: window.frame.size)
        if origin != window.frame.origin {
            window.setFrameOrigin(origin)
        }
        updatePreference("window_x", value: Double(origin.x))
        updatePreference("window_y", value: Double(origin.y))
    }

    func resizeWindow(to mouseLocation: NSPoint) {
        guard let window = ownerWindow else { return }

        let dx = mouseLocation.x - resizeStartMouse.x
        let dy = mouseLocation.y - resizeStartMouse.y
        let scaleDelta = ((-dx / currentDesignWidth()) + (-dy / currentDesignHeight())) / 2
        let nextScale = min(max(resizeStartScale + scaleDelta, minUIScale), maxUIScale)
        let size = NSSize(width: currentDesignWidth() * nextScale, height: currentDesignHeight() * nextScale)
        let origin = NSPoint(x: resizeStartFrame.maxX - size.width, y: resizeStartFrame.maxY - size.height)
        let clampedOrigin = clampedOriginForVisibleScreen(origin, size: size)

        uiScale = nextScale
        let nextFrame = NSRect(origin: clampedOrigin, size: size)
        frame = NSRect(origin: .zero, size: size)
        window.setFrame(nextFrame, display: true, animate: false)
        updatePreference("scale", value: Double(nextScale))
        updatePreference("window_x", value: Double(nextFrame.origin.x))
        updatePreference("window_y", value: Double(nextFrame.origin.y))
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if let light = lampAtEvent(event) {
            showLampSessionMenu(with: event, light: light)
            return
        }
        showStatusMenu(with: event)
    }

    func showStatusMenu(with event: NSEvent) {
        let menu = NSMenu()
        let current = NSMenuItem(title: "当前：\(labels[state] ?? "空闲")", action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)
        menu.addItem(.separator())
        menu.addItem(withTitle: "黄灯：正在干活", action: #selector(AppDelegate.setWorking), keyEquivalent: "")
        menu.addItem(withTitle: "绿灯：完成验收", action: #selector(AppDelegate.setDone), keyEquivalent: "")
        menu.addItem(withTitle: "红灯：等你回复", action: #selector(AppDelegate.setWaiting), keyEquivalent: "")
        menu.addItem(withTitle: "空闲：都变暗", action: #selector(AppDelegate.setIdle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "放大", action: #selector(AppDelegate.increaseScale), keyEquivalent: "+")
        menu.addItem(withTitle: "缩小", action: #selector(AppDelegate.decreaseScale), keyEquivalent: "-")
        menu.addItem(withTitle: "重置大小", action: #selector(AppDelegate.resetScale), keyEquivalent: "0")
        menu.addItem(.separator())
        if sidebarEdgePreference() != nil {
            menu.addItem(withTitle: "展开完整灯", action: #selector(AppDelegate.exitSidebarMode), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "吸附到左侧", action: #selector(AppDelegate.snapToLeftSidebar), keyEquivalent: "")
            menu.addItem(withTitle: "吸附到右侧", action: #selector(AppDelegate.snapToRightSidebar), keyEquivalent: "")
        }
        menu.addItem(.separator())
        addBlinkSettingsMenu(to: menu)
        menu.addItem(.separator())
        let quotaItem = NSMenuItem(title: "显示额度条", action: #selector(AppDelegate.toggleFiveHourQuota), keyEquivalent: "")
        quotaItem.target = NSApp.delegate as? AppDelegate
        quotaItem.state = fiveHourQuotaVisible() ? .on : .off
        menu.addItem(quotaItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置...", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: isMuted ? "取消静音" : "静音", action: #selector(AppDelegate.toggleMuteFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "退出", action: #selector(AppDelegate.quit), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func openClickedLampSession(with event: NSEvent) -> Bool {
        guard let light = lampAtEvent(event) else { return false }
        let targetState = stateName(for: light)
        guard let session = latestAttentionSession(for: targetState) ?? latestSession(for: targetState) else {
            NSSound.beep()
            return true
        }
        if clickAcknowledgesSessions() {
            acknowledgeSession(session.id)
        }
        showOpenFeedback(light: light, session: session)
        openCodexSession(session.id)
        return true
    }

    func lampAtEvent(_ event: NSEvent) -> String? {
        let point = convert(event.locationInWindow, from: nil)
        let designPoint = designPoint(from: point)
        if sidebarEdgePreference() != nil {
            for light in ["red", "yellow", "green"] {
                if sidebarLampRect(for: light).insetBy(dx: -10, dy: -10).contains(designPoint) {
                    return light
                }
            }
            return nil
        }
        let imageRect = photoImageRect()
        for light in ["red", "yellow", "green"] {
            let hitRect = photoLampRect(for: light, imageRect: imageRect).insetBy(dx: -12, dy: -12)
            if hitRect.contains(designPoint) {
                return light
            }
        }
        return nil
    }

    func showLampSessionMenu(with event: NSEvent, light: String) {
        let targetState = stateName(for: light)
        let sessions = activeSessions(for: targetState)
        let unreadCount = attentionSessions(for: targetState).count
        let menu = NSMenu()
        let header = NSMenuItem(title: "\(displayName(for: light))：\(unreadCount) 未查看 / \(sessions.count) 活跃", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if sessions.isEmpty {
            let empty = NSMenuItem(title: "没有对应会话", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let latest = attentionSessions(for: targetState).first ?? sessions[0]
            addSessionMenuItem(to: menu, title: "打开最新：\(latest.displayTitle)", session: latest, light: light)
            let acknowledgeAll = NSMenuItem(title: "全部标记已查看", action: #selector(acknowledgeSessionsFromMenu(_:)), keyEquivalent: "")
            acknowledgeAll.target = self
            acknowledgeAll.representedObject = targetState
            menu.addItem(acknowledgeAll)
            menu.addItem(.separator())
            for session in sessions.prefix(10) {
                addSessionMenuItem(to: menu, title: session.menuTitle, session: session, light: light)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "闪烁设置", action: nil, keyEquivalent: "").submenu = blinkOnlyMenu(for: light)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func addSessionMenuItem(to menu: NSMenu, title: String, session: StatusSession, light: String) {
        let item = NSMenuItem(title: title, action: #selector(openSessionFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = "\(light)|\(session.id)"
        if let preview = session.preview, !preview.isEmpty {
            item.toolTip = preview
        }
        item.state = session.isAcknowledged ? .off : .on
        menu.addItem(item)
    }

    func blinkOnlyMenu(for light: String) -> NSMenu {
        let menu = NSMenu(title: "闪烁设置")
        switch light {
        case "red":
            addBlinkItems(for: light, toggle: #selector(AppDelegate.toggleRedBlink), slow: #selector(AppDelegate.setRedBlinkSlow), medium: #selector(AppDelegate.setRedBlinkMedium), fast: #selector(AppDelegate.setRedBlinkFast), to: menu)
        case "yellow":
            addBlinkItems(for: light, toggle: #selector(AppDelegate.toggleYellowBlink), slow: #selector(AppDelegate.setYellowBlinkSlow), medium: #selector(AppDelegate.setYellowBlinkMedium), fast: #selector(AppDelegate.setYellowBlinkFast), to: menu)
        case "green":
            addBlinkItems(for: light, toggle: #selector(AppDelegate.toggleGreenBlink), slow: #selector(AppDelegate.setGreenBlinkSlow), medium: #selector(AppDelegate.setGreenBlinkMedium), fast: #selector(AppDelegate.setGreenBlinkFast), to: menu)
        default:
            break
        }
        return menu
    }

    @objc func openSessionFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String,
              let separator = payload.firstIndex(of: "|") else {
            return
        }
        let light = String(payload[..<separator])
        let id = String(payload[payload.index(after: separator)...])
        if clickAcknowledgesSessions() {
            acknowledgeSession(id)
        }
        if let session = sessionByID(id) {
            showOpenFeedback(light: light, session: session)
        }
        openCodexSession(id)
    }

    @objc func acknowledgeSessionsFromMenu(_ sender: NSMenuItem) {
        guard let targetState = sender.representedObject as? String else { return }
        for session in activeSessions(for: targetState) {
            acknowledgeSession(session.id)
        }
        needsDisplay = true
    }

    func addBlinkSettingsMenu(to menu: NSMenu) {
        let parent = NSMenuItem(title: "闪烁设置", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "闪烁设置")
        addBlinkItems(for: "red", toggle: #selector(AppDelegate.toggleRedBlink), slow: #selector(AppDelegate.setRedBlinkSlow), medium: #selector(AppDelegate.setRedBlinkMedium), fast: #selector(AppDelegate.setRedBlinkFast), to: submenu)
        submenu.addItem(.separator())
        addBlinkItems(for: "yellow", toggle: #selector(AppDelegate.toggleYellowBlink), slow: #selector(AppDelegate.setYellowBlinkSlow), medium: #selector(AppDelegate.setYellowBlinkMedium), fast: #selector(AppDelegate.setYellowBlinkFast), to: submenu)
        submenu.addItem(.separator())
        addBlinkItems(for: "green", toggle: #selector(AppDelegate.toggleGreenBlink), slow: #selector(AppDelegate.setGreenBlinkSlow), medium: #selector(AppDelegate.setGreenBlinkMedium), fast: #selector(AppDelegate.setGreenBlinkFast), to: submenu)
        parent.submenu = submenu
        menu.addItem(parent)
    }

    func addBlinkItems(for light: String, toggle: Selector, slow: Selector, medium: Selector, fast: Selector, to menu: NSMenu) {
        let toggleItem = NSMenuItem(title: "\(displayName(for: light))闪烁", action: toggle, keyEquivalent: "")
        toggleItem.state = isBlinkEnabled(for: light) ? .on : .off
        menu.addItem(toggleItem)

        let speedParent = NSMenuItem(title: "\(displayName(for: light))频率", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu(title: "\(displayName(for: light))频率")
        addBlinkSpeedItem(title: "慢", frequency: 0.85, action: slow, light: light, to: speedMenu)
        addBlinkSpeedItem(title: "中", frequency: 1.35, action: medium, light: light, to: speedMenu)
        addBlinkSpeedItem(title: "快", frequency: 2.05, action: fast, light: light, to: speedMenu)
        speedParent.submenu = speedMenu
        menu.addItem(speedParent)
    }

    func addBlinkSpeedItem(title: String, frequency: Double, action: Selector, light: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        let current = Double(blinkFrequency(for: light))
        item.state = abs(current - frequency) < 0.01 ? .on : .off
        menu.addItem(item)
    }

    func designPoint(from point: NSPoint) -> NSPoint {
        NSPoint(x: point.x / uiScale, y: point.y / uiScale)
    }

    func cycleState() {
        let index = stateOrder.firstIndex(of: state) ?? 0
        onStateCommand?(stateOrder[(index + 1) % stateOrder.count])
    }

    func updateTooltip() {
        let nextTooltip: String
        if fiveHourQuotaVisible(), let quota = latestFiveHourQuota() {
            nextTooltip = "\(labels[state] ?? "空闲")\n\(quota.detailText)"
        } else {
            nextTooltip = labels[state] ?? "空闲"
        }
        guard toolTip != nextTooltip else { return }
        toolTip = nextTooltip
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: TrafficLightView!
    var lastModified = Date.distantPast
    var lastForcedRecompute = Date.distantPast
    var waitingBlinkStopTimer: Timer?
    var settingsWindowController: SettingsWindowController?
    let soundController = SoundController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureRuntime()
        if !FileManager.default.fileExists(atPath: stateFile.path) {
            writeState("idle")
        }
        if readState() == "quit" {
            writeState("idle")
        }

        let size = currentWindowSize()
        view = TrafficLightView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        let origin = sidebarEdgePreference() == nil ? clampedWindowOrigin(initialWindowOrigin()) : initialWindowOrigin()
        window = NSWindow(contentRect: NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.level = .floating
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view
        view.ownerWindow = window
        view.onStateCommand = { [weak self] state in self?.setState(state) }
        view.onSidebarEdgeChange = { [weak self] edge in self?.setSidebarEdge(edge) }
        view.updateTooltip()
        window.makeKeyAndOrderFront(nil)
        soundController.apply(state: view.state, playPrompt: false)

        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollState() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.animateLights() }
    }

    func initialWindowOrigin() -> NSPoint {
        if let edge = sidebarEdgePreference(), let screen = NSScreen.main {
            let preferredY = readDoublePreference(sidebarYPreferenceKey).map { CGFloat($0) }
            return sidebarOrigin(edge: edge, preferredMidY: preferredY, size: windowSize(sidebar: true), screen: screen)
        }
        if let x = readDoublePreference("window_x"), let y = readDoublePreference("window_y") {
            return NSPoint(x: x, y: y)
        }
        guard let screen = NSScreen.main else {
            return NSPoint(x: 1280, y: 540)
        }
        let size = currentWindowSize()
        return NSPoint(x: screen.visibleFrame.maxX - size.width - 28, y: screen.visibleFrame.midY - size.height / 2)
    }

    func clampedWindowOrigin(_ origin: NSPoint) -> NSPoint {
        clampedOriginForVisibleScreen(origin, size: currentWindowSize())
    }

    func bringWindowBack() {
        if let edge = sidebarEdgePreference() {
            let anchorY = readDoublePreference(sidebarYPreferenceKey).map { CGFloat($0) } ?? window?.frame.midY
            setSidebarEdge(edge, anchorMidY: anchorY, animate: false)
            window.level = .floating
            window.orderFrontRegardless()
            return
        }
        let origin = clampedWindowOrigin(initialWindowOrigin())
        window.setFrameOrigin(origin)
        window.level = .floating
        window.orderFrontRegardless()
        updatePreference("window_x", value: Double(origin.x))
        updatePreference("window_y", value: Double(origin.y))
    }

    func pollState() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: stateFile.path)
        let modified = attrs?[.modificationDate] as? Date ?? Date.distantPast
        let now = Date()
        let fileChanged = modified != lastModified
        let shouldForceRecompute = now.timeIntervalSince(lastForcedRecompute) >= 1.0
        guard fileChanged || shouldForceRecompute else { return }
        if fileChanged {
            lastModified = modified
            codexThreadOpenabilityCache.removeAll()
        }
        if shouldForceRecompute {
            lastForcedRecompute = now
        }
        invalidateStateCaches()
        if let command = readCommand() {
            applyCommand(command)
        }
        let next = readState()
        if next == "quit" {
            soundController.stopAll()
            NSApp.terminate(nil)
            return
        }
        if next != view.state || next == "waiting" {
            applyState(next, playPrompt: true, writeFile: false)
        } else {
            view.updateTooltip()
            view.needsDisplay = true
        }
    }

    func applyCommand(_ command: String) {
        switch command {
        case "show", "reset-position":
            bringWindowBack()
        case "settings":
            bringWindowBack()
            showSettings()
        case "clear-sessions":
            applyState(readState(), playPrompt: false, writeFile: false)
        default:
            break
        }
        clearCommand()
    }

    func animateLights() {
        var shouldRedraw = false
        if view.visibleLights().contains(where: { view.shouldBlink(for: $0) }) {
            view.animationPhase += 1.0 / 30.0
            if view.animationPhase > 3600 {
                view.animationPhase = 0
            }
            shouldRedraw = true
        }
        if view.hasOpenFeedback() {
            shouldRedraw = true
        } else if view.openFeedbackLight != nil {
            view.openFeedbackLight = nil
            shouldRedraw = true
        }
        if shouldRedraw {
            view.needsDisplay = true
        }
    }

    @objc func setWorking() { setState("working") }
    @objc func setDone() { setState("done") }
    @objc func setWaiting() { setState("waiting") }
    @objc func setIdle() { setState("idle") }
    @objc func toggleMuteFromMenu() { toggleMute() }
    @objc func toggleFiveHourQuota() {
        updatePreference(fiveHourQuotaPreferenceKey, value: !fiveHourQuotaVisible())
        resizeForCurrentPreferences()
    }
    @objc func increaseScale() { applyScale(uiScale + 0.08) }
    @objc func decreaseScale() { applyScale(uiScale - 0.08) }
    @objc func resetScale() { applyScale(0.74) }
    @objc func snapToLeftSidebar() { setSidebarEdge("left") }
    @objc func snapToRightSidebar() { setSidebarEdge("right") }
    @objc func exitSidebarMode() { setSidebarEdge(nil) }
    @objc func toggleRedBlink() { toggleBlink(for: "red") }
    @objc func toggleYellowBlink() { toggleBlink(for: "yellow") }
    @objc func toggleGreenBlink() { toggleBlink(for: "green") }
    @objc func setRedBlinkSlow() { setBlinkFrequency(for: "red", frequency: 0.85) }
    @objc func setRedBlinkMedium() { setBlinkFrequency(for: "red", frequency: 1.35) }
    @objc func setRedBlinkFast() { setBlinkFrequency(for: "red", frequency: 2.05) }
    @objc func setYellowBlinkSlow() { setBlinkFrequency(for: "yellow", frequency: 0.85) }
    @objc func setYellowBlinkMedium() { setBlinkFrequency(for: "yellow", frequency: 1.35) }
    @objc func setYellowBlinkFast() { setBlinkFrequency(for: "yellow", frequency: 2.05) }
    @objc func setGreenBlinkSlow() { setBlinkFrequency(for: "green", frequency: 0.85) }
    @objc func setGreenBlinkMedium() { setBlinkFrequency(for: "green", frequency: 1.35) }
    @objc func setGreenBlinkFast() { setBlinkFrequency(for: "green", frequency: 2.05) }
    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(appDelegate: self)
        }
        settingsWindowController?.refresh()
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func quit() {
        soundController.stopAll()
        writeState("quit")
        NSApp.terminate(nil)
    }

    func toggleBlink(for light: String) {
        updatePreference(blinkEnabledKey(for: light), value: !isBlinkEnabled(for: light))
        view.animationPhase = 0
        view.needsDisplay = true
    }

    func setBlinkFrequency(for light: String, frequency: Double) {
        updatePreference(blinkFrequencyKey(for: light), value: frequency)
        view.animationPhase = 0
        view.needsDisplay = true
    }

    func applyScale(_ nextScale: CGFloat) {
        let clampedScale = min(max(nextScale, minUIScale), maxUIScale)
        guard abs(clampedScale - uiScale) > 0.001 else { return }

        let oldFrame = window.frame
        uiScale = clampedScale
        updatePreference("scale", value: Double(clampedScale))

        if let edge = sidebarEdgePreference() {
            setSidebarEdge(edge, anchorMidY: oldFrame.midY)
            return
        }

        let size = currentWindowSize()
        let centeredOrigin = NSPoint(x: oldFrame.midX - size.width / 2, y: oldFrame.midY - size.height / 2)
        let origin = clampedWindowOrigin(centeredOrigin)
        let nextFrame = NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height)

        view.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        window.setFrame(nextFrame, display: true, animate: true)
        updatePreference("window_x", value: Double(origin.x))
        updatePreference("window_y", value: Double(origin.y))
        view.needsDisplay = true
    }

    func resizeForCurrentPreferences() {
        guard let window, let view else { return }
        if let edge = sidebarEdgePreference() {
            setSidebarEdge(edge, anchorMidY: window.frame.midY, animate: false)
            return
        }
        let oldFrame = window.frame
        let nextSize = currentWindowSize()
        let origin = clampedOriginForVisibleScreen(
            NSPoint(x: oldFrame.maxX - nextSize.width, y: oldFrame.maxY - nextSize.height),
            size: nextSize
        )
        let nextFrame = NSRect(origin: origin, size: nextSize)
        view.frame = NSRect(origin: .zero, size: nextSize)
        window.setFrame(nextFrame, display: true, animate: false)
        updatePreference("window_x", value: Double(nextFrame.origin.x))
        updatePreference("window_y", value: Double(nextFrame.origin.y))
        view.updateTooltip()
        view.needsDisplay = true
        settingsWindowController?.refresh()
    }

    func setSidebarEdge(_ edge: String?, anchorMidY: CGFloat? = nil, animate: Bool = true) {
        guard let window, let view else { return }
        let oldFrame = window.frame
        let screen = visibleScreen(for: oldFrame) ?? NSScreen.main

        if let edge, let screen {
            let nextSize = windowSize(sidebar: true)
            let origin = sidebarOrigin(edge: edge, preferredMidY: anchorMidY ?? oldFrame.midY, size: nextSize, screen: screen)
            let nextFrame = NSRect(origin: origin, size: nextSize)
            updatePreference(sidebarPreferenceKey, value: edge)
            updatePreference(sidebarYPreferenceKey, value: Double(nextFrame.midY))
            view.frame = NSRect(origin: .zero, size: nextSize)
            window.setFrame(nextFrame, display: true, animate: animate)
            view.updateTooltip()
            view.needsDisplay = true
            settingsWindowController?.refresh()
            return
        }

        updatePreference(sidebarPreferenceKey, value: "none")
        let nextSize = windowSize(sidebar: false)
        let centeredOrigin = NSPoint(x: oldFrame.midX - nextSize.width / 2, y: oldFrame.midY - nextSize.height / 2)
        let origin = clampedOriginForVisibleScreen(centeredOrigin, size: nextSize)
        let nextFrame = NSRect(origin: origin, size: nextSize)
        view.frame = NSRect(origin: .zero, size: nextSize)
        window.setFrame(nextFrame, display: true, animate: animate)
        updatePreference("window_x", value: Double(nextFrame.origin.x))
        updatePreference("window_y", value: Double(nextFrame.origin.y))
        view.updateTooltip()
        view.needsDisplay = true
        settingsWindowController?.refresh()
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
        view.updateTooltip()
        if state == "waiting" {
            startWaitingBlinkTimer()
        } else {
            stopWaitingBlinkTimer()
        }
        view.isMuted = soundController.muted
        view.needsDisplay = true
        soundController.apply(state: state, playPrompt: playPrompt)
    }

    func startWaitingBlinkTimer() {
        waitingBlinkStopTimer?.invalidate()
        view.waitingAlertActive = true
        view.animationPhase = 0
        view.needsDisplay = true
    }

    func stopWaitingBlinkTimer() {
        waitingBlinkStopTimer?.invalidate()
        waitingBlinkStopTimer = nil
        view.waitingAlertActive = false
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

final class SettingsWindowController: NSWindowController {
    weak var appDelegate: AppDelegate?
    let scaleSlider = NSSlider(value: Double(uiScale), minValue: Double(minUIScale), maxValue: Double(maxUIScale), target: nil, action: nil)
    let scaleValueLabel = NSTextField(labelWithString: "")
    let clickAckButton = NSButton(checkboxWithTitle: "点击会话后停止闪烁", target: nil, action: nil)
    let smartRedButton = NSButton(checkboxWithTitle: "红灯未处理自动加快", target: nil, action: nil)
    let muteButton = NSButton(checkboxWithTitle: "静音", target: nil, action: nil)
    let fiveHourQuotaButton = NSButton(checkboxWithTitle: "显示额度条", target: nil, action: nil)
    let staleHoursField = NSTextField(string: "")
    let redEscalateField = NSTextField(string: "")

    init(appDelegate: AppDelegate) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex 状态灯设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        self.appDelegate = appDelegate
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func buildContent() {
        guard let contentView = window?.contentView else { return }
        let width: CGFloat = 390
        let left: CGFloat = 24
        let fieldX: CGFloat = 236
        var y: CGFloat = 342

        addLabel("大小", x: left, y: y, width: 80, to: contentView)
        scaleSlider.frame = NSRect(x: 86, y: y - 4, width: 190, height: 24)
        scaleSlider.target = self
        scaleSlider.action = #selector(scaleChanged(_:))
        contentView.addSubview(scaleSlider)
        scaleValueLabel.frame = NSRect(x: 286, y: y, width: 64, height: 20)
        contentView.addSubview(scaleValueLabel)

        y -= 42
        configureCheckbox(clickAckButton, y: y, in: contentView, action: #selector(clickAckChanged(_:)))
        y -= 30
        configureCheckbox(smartRedButton, y: y, in: contentView, action: #selector(smartRedChanged(_:)))
        y -= 30
        configureCheckbox(muteButton, y: y, in: contentView, action: #selector(muteChanged(_:)))
        y -= 30
        configureCheckbox(fiveHourQuotaButton, y: y, in: contentView, action: #selector(fiveHourQuotaChanged(_:)))

        y -= 42
        addLabel("红灯加快阈值（秒）", x: left, y: y, width: 180, to: contentView)
        configureField(redEscalateField, x: fieldX, y: y, in: contentView)
        y -= 34
        addLabel("会话过期（小时）", x: left, y: y, width: 180, to: contentView)
        configureField(staleHoursField, x: fieldX, y: y, in: contentView)

        let applyButton = NSButton(title: "应用", target: self, action: #selector(applyNumberSettings))
        applyButton.frame = NSRect(x: width - 102, y: 74, width: 78, height: 30)
        contentView.addSubview(applyButton)

        let resetButton = NSButton(title: "找回浮窗", target: self, action: #selector(resetPosition))
        resetButton.frame = NSRect(x: left, y: 28, width: 96, height: 30)
        contentView.addSubview(resetButton)

        let clearButton = NSButton(title: "清空会话", target: self, action: #selector(clearSessions))
        clearButton.frame = NSRect(x: left + 112, y: 28, width: 96, height: 30)
        contentView.addSubview(clearButton)

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeSettings))
        closeButton.frame = NSRect(x: width - 102, y: 28, width: 78, height: 30)
        contentView.addSubview(closeButton)
    }

    func addLabel(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat, to view: NSView) {
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: x, y: y, width: width, height: 20)
        view.addSubview(label)
    }

    func configureCheckbox(_ button: NSButton, y: CGFloat, in view: NSView, action: Selector) {
        button.frame = NSRect(x: 24, y: y, width: 250, height: 24)
        button.target = self
        button.action = action
        view.addSubview(button)
    }

    func configureField(_ field: NSTextField, x: CGFloat, y: CGFloat, in view: NSView) {
        field.frame = NSRect(x: x, y: y - 4, width: 78, height: 24)
        field.alignment = .right
        field.target = self
        field.action = #selector(applyNumberSettings)
        view.addSubview(field)
    }

    func refresh() {
        scaleSlider.doubleValue = Double(uiScale)
        scaleValueLabel.stringValue = "\(Int(round(uiScale * 100)))%"
        clickAckButton.state = clickAcknowledgesSessions() ? .on : .off
        smartRedButton.state = (readBoolPreference("smart_red_blink") ?? true) ? .on : .off
        muteButton.state = (readBoolPreference("muted") ?? false) ? .on : .off
        fiveHourQuotaButton.state = fiveHourQuotaVisible() ? .on : .off
        redEscalateField.stringValue = "\(Int(readDoublePreference("red_blink_escalate_after_seconds") ?? 30))"
        staleHoursField.stringValue = String(format: "%.1f", sessionStaleInterval() / 3600)
    }

    @objc func scaleChanged(_ sender: NSSlider) {
        appDelegate?.applyScale(CGFloat(sender.doubleValue))
        scaleValueLabel.stringValue = "\(Int(round(sender.doubleValue * 100)))%"
    }

    @objc func clickAckChanged(_ sender: NSButton) {
        updatePreference("click_acknowledges_sessions", value: sender.state == .on)
    }

    @objc func smartRedChanged(_ sender: NSButton) {
        updatePreference("smart_red_blink", value: sender.state == .on)
        appDelegate?.view.needsDisplay = true
    }

    @objc func muteChanged(_ sender: NSButton) {
        let wantsMuted = sender.state == .on
        if appDelegate?.soundController.muted != wantsMuted {
            appDelegate?.toggleMute()
        }
    }

    @objc func fiveHourQuotaChanged(_ sender: NSButton) {
        updatePreference(fiveHourQuotaPreferenceKey, value: sender.state == .on)
        appDelegate?.resizeForCurrentPreferences()
    }

    @objc func applyNumberSettings() {
        let redSeconds = max(5, redEscalateField.doubleValue)
        let staleSeconds = max(0.25, staleHoursField.doubleValue) * 3600
        updatePreference("red_blink_escalate_after_seconds", value: redSeconds)
        updatePreference("session_stale_seconds", value: staleSeconds)
        appDelegate?.view.needsDisplay = true
        refresh()
    }

    @objc func resetPosition() {
        appDelegate?.bringWindowBack()
    }

    @objc func clearSessions() {
        writeState("idle")
        appDelegate?.applyState("idle", playPrompt: false, writeFile: false)
        refresh()
    }

    @objc func closeSettings() {
        close()
    }
}

func ensureRuntime() {
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
}

func acquireSingleInstanceLock() -> Bool {
    ensureRuntime()
    let fd = open(instanceLockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    guard fd >= 0 else {
        return true
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        requestExistingInstanceToShow()
        return false
    }

    instanceLockFD = fd
    let pidText = "\(ProcessInfo.processInfo.processIdentifier)\n"
    _ = ftruncate(fd, 0)
    _ = pidText.withCString { pointer in
        write(fd, pointer, strlen(pointer))
    }
    return true
}

func requestExistingInstanceToShow() {
    ensureRuntime()
    var object = readStateObject()
    if object["state"] == nil {
        object["state"] = "idle"
    }
    object["command"] = "show"
    object["updated_at"] = Date().timeIntervalSince1970
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: stateFile)
    }
}

func writeState(_ state: String) {
    ensureRuntime()
    let body: [String: Any] = ["state": state, "manual_state": state, "updated_at": Date().timeIntervalSince1970]
    if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]) {
        try? data.write(to: stateFile)
    }
    invalidateStateCaches()
}

func invalidateStateCaches() {
    cachedStateObject = nil
    cachedActiveSessions = nil
    cachedFiveHourQuota = nil
    hasCachedFiveHourQuota = false
}

func readStateObject() -> [String: Any] {
    if let cachedStateObject {
        return cachedStateObject
    }
    guard let data = try? Data(contentsOf: stateFile),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    cachedStateObject = object
    return object
}

func readState() -> String {
    let object = readStateObject()
    if let state = object["state"] as? String, state == "quit" {
        return state
    }

    var candidates: [(String, Int)] = []
    let sessions = object["sessions"] as? [String: Any]
    if let state = object["manual_state"] as? String, let priority = statePriority(state) {
        candidates.append((state, priority))
    } else if sessions == nil, let state = object["state"] as? String, let priority = statePriority(state) {
        candidates.append((state, priority))
    }

    if sessions != nil {
        for session in aggregateCandidateSessions() {
            if let priority = statePriority(session.state) {
                candidates.append((session.state, priority))
            }
        }
    }

    return candidates.max(by: { $0.1 < $1.1 })?.0 ?? "idle"
}

func statePriority(_ state: String) -> Int? {
    switch state {
    case "waiting": return 3
    case "done": return 2
    case "working": return 1
    case "idle": return 0
    default: return nil
    }
}

func latestSessionID(for targetState: String) -> String? {
    latestSession(for: targetState)?.id
}

func latestSession(for targetState: String) -> StatusSession? {
    activeSessions(for: targetState).first
}

func latestAttentionSession(for targetState: String) -> StatusSession? {
    attentionSessions(for: targetState).first
}

func sessionByID(_ sessionID: String) -> StatusSession? {
    let object = readStateObject()
    guard let sessions = object["sessions"] as? [String: Any] else {
        return nil
    }
    guard let session = makeStatusSession(id: sessionID, value: sessions[sessionID]),
          sessionIsFresh(session) else {
        return nil
    }
    return session
}

func activeSessions(for targetState: String? = nil) -> [StatusSession] {
    let sessions = activeSessionSnapshot()
    guard let targetState else { return sessions }
    return sessions.filter { $0.state == targetState }
}

func activeSessionSnapshot() -> [StatusSession] {
    if let cachedActiveSessions {
        return cachedActiveSessions
    }
    let object = readStateObject()
    guard let sessions = object["sessions"] as? [String: Any] else {
        cachedActiveSessions = []
        return []
    }
    var result: [StatusSession] = []
    for (id, value) in sessions {
        guard let session = makeStatusSession(id: id, value: value),
              sessionIsFresh(session) else {
            continue
        }
        result.append(session)
    }
    let sorted = result.sorted { lhs, rhs in
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.id < rhs.id
        }
        return lhs.updatedAt > rhs.updatedAt
    }
    cachedActiveSessions = sorted
    return sorted
}

func attentionSessions(for targetState: String? = nil) -> [StatusSession] {
    activeSessions(for: targetState).filter { !$0.isAcknowledged }
}

func aggregateCandidateSessions() -> [StatusSession] {
    activeSessions().filter { session in
        if session.state == "working" {
            return true
        }
        return !session.isAcknowledged
    }
}

func makeStatusSession(id: String, value: Any?) -> StatusSession? {
    guard let session = value as? [String: Any],
          let state = session["state"] as? String,
          statePriority(state) != nil else {
        return nil
    }
    return StatusSession(
        id: id,
        state: state,
        updatedAt: timeIntervalValue(session["updated_at"]),
        acknowledgedAt: timeIntervalValue(session["acknowledged_at"]),
        title: stringValue(session["title"]),
        cwd: stringValue(session["cwd"]),
        preview: stringValue(session["preview"]),
        sourceEvent: stringValue(session["source_event"]),
        toolName: stringValue(session["tool_name"]),
        model: stringValue(session["model"]),
        transcriptPath: stringValue(session["transcript_path"]),
        rateLimitPrimaryUsedPercent: optionalDoubleValue(session["rate_limit_primary_used_percent"]),
        rateLimitPrimaryRemainingPercent: optionalDoubleValue(session["rate_limit_primary_remaining_percent"]),
        rateLimitPrimaryResetsAt: optionalDoubleValue(session["rate_limit_primary_resets_at"]),
        rateLimitPrimaryWindowMinutes: optionalDoubleValue(session["rate_limit_primary_window_minutes"]),
        rateLimitName: stringValue(session["rate_limit_name"]),
        rateLimitPlanType: stringValue(session["rate_limit_plan_type"])
    )
}

func sessionIsFresh(_ session: StatusSession) -> Bool {
    guard sessionIsOpenable(session) else {
        return false
    }
    let age = Date().timeIntervalSince1970 - session.updatedAt
    if session.state == "working" && age > sessionStaleInterval() {
        return false
    }
    return true
}

func sessionIsOpenable(_ session: StatusSession) -> Bool {
    guard isUUIDString(session.id) else {
        return false
    }
    let now = Date().timeIntervalSince1970
    if let cached = codexThreadOpenabilityCache[session.id] {
        let ttl: TimeInterval = cached.openable ? 5.0 : 0.75
        if now - cached.checkedAt < ttl {
            return cached.openable
        }
    }

    let openable = queryCodexThreadOpenability(session)
    codexThreadOpenabilityCache[session.id] = (openable, now)
    return openable
}

func queryCodexThreadOpenability(_ session: StatusSession) -> Bool {
    if archivedRolloutExists(for: session.id) {
        return false
    }
    if let archived = sqliteThreadArchived(session.id) {
        return !archived
    }
    if activeRolloutExists(for: session) {
        return true
    }
    return false
}

func sqliteThreadArchived(_ sessionID: String) -> Bool? {
    guard FileManager.default.fileExists(atPath: codexStateDatabase.path) else {
        return nil
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    let escapedID = sessionID.replacingOccurrences(of: "'", with: "''")
    process.arguments = ["-readonly", codexStateDatabase.path, "SELECT archived FROM threads WHERE id = '\(escapedID)' LIMIT 1;"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0 else {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if output == "1" {
        return true
    }
    if output == "0" {
        return false
    }
    return nil
}

func activeRolloutExists(for session: StatusSession) -> Bool {
    if let transcriptPath = session.transcriptPath,
       transcriptPath.contains("/.codex/sessions/"),
       FileManager.default.fileExists(atPath: transcriptPath) {
        return true
    }
    return directoryContainsSessionID(codexSessionsDir, sessionID: session.id)
}

func archivedRolloutExists(for sessionID: String) -> Bool {
    directoryContainsSessionID(codexArchivedSessionsDir, sessionID: sessionID)
}

func directoryContainsSessionID(_ directory: URL, sessionID: String) -> Bool {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
        return false
    }
    return entries.contains { $0.contains(sessionID) }
}

func isUUIDString(_ value: String) -> Bool {
    guard value.count == 36 else { return false }
    let hyphenOffsets = Set([8, 13, 18, 23])
    for (index, char) in value.enumerated() {
        if hyphenOffsets.contains(index) {
            if char != "-" { return false }
        } else if !char.isHexDigit {
            return false
        }
    }
    return true
}

func timeIntervalValue(_ value: Any?) -> TimeInterval {
    if let value = value as? TimeInterval {
        return value
    }
    if let value = value as? Int {
        return TimeInterval(value)
    }
    if let value = value as? String, let number = Double(value) {
        return number
    }
    return 0
}

func optionalDoubleValue(_ value: Any?) -> Double? {
    if let value = value as? Double {
        return value
    }
    if let value = value as? Int {
        return Double(value)
    }
    if let value = value as? String, let number = Double(value) {
        return number
    }
    return nil
}

func stringValue(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let string = value as? String {
        return string
    }
    return String(describing: value)
}

func latestFiveHourQuota() -> FiveHourQuota? {
    if hasCachedFiveHourQuota {
        return cachedFiveHourQuota
    }

    let object = readStateObject()
    var result = fiveHourQuota(from: object)
    if result == nil {
        var seen = Set<String>()
        let sessions = attentionSessions() + activeSessions()
        for session in sessions where !seen.contains(session.id) {
            seen.insert(session.id)
            if let quota = session.fiveHourQuota {
                result = quota
                break
            }
        }

        if result == nil, let rawSessions = object["sessions"] as? [String: Any] {
            let allSessions = rawSessions.compactMap { makeStatusSession(id: $0.key, value: $0.value) }
                .sorted { $0.updatedAt > $1.updatedAt }
            for session in allSessions where !seen.contains(session.id) {
                seen.insert(session.id)
                if let quota = session.fiveHourQuota {
                    result = quota
                    break
                }
            }
        }
    }

    cachedFiveHourQuota = result
    hasCachedFiveHourQuota = true
    return result
}

func fiveHourQuota(from object: [String: Any]) -> FiveHourQuota? {
    guard let resetsAt = optionalDoubleValue(object["rate_limit_primary_resets_at"]) else {
        return nil
    }
    let window = optionalDoubleValue(object["rate_limit_primary_window_minutes"]) ?? 300
    guard window >= 295 && window <= 305 else { return nil }
    let used = optionalDoubleValue(object["rate_limit_primary_used_percent"])
    let remaining = optionalDoubleValue(object["rate_limit_primary_remaining_percent"]) ?? used.map { 100 - $0 }
    guard let remaining else { return nil }
    return FiveHourQuota(
        remainingPercent: min(max(remaining, 0), 100),
        usedPercent: min(max(used ?? 100 - remaining, 0), 100),
        resetsAt: resetsAt,
        limitName: stringValue(object["rate_limit_name"]),
        planType: stringValue(object["rate_limit_plan_type"])
    )
}

func latestSessionIsAcknowledged(for targetState: String) -> Bool {
    guard let session = latestSession(for: targetState) else {
        return false
    }
    return session.acknowledgedAt >= session.updatedAt
}

func acknowledgeSession(_ sessionID: String) {
    var object = readStateObject()
    guard var sessions = object["sessions"] as? [String: Any],
          var session = sessions[sessionID] as? [String: Any] else {
        return
    }
    session["acknowledged_at"] = Date().timeIntervalSince1970
    sessions[sessionID] = session
    object["sessions"] = sessions
    object["updated_at"] = Date().timeIntervalSince1970
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: stateFile)
    }
    invalidateStateCaches()
}

func openCodexSession(_ sessionID: String) {
    guard let url = URL(string: "codex://threads/\(sessionID)") else {
        NSSound.beep()
        return
    }
    NSWorkspace.shared.open(url)
}

func readCommand() -> String? {
    readStateObject()["command"] as? String
}

func clearCommand() {
    var object = readStateObject()
    object.removeValue(forKey: "command")
    object["updated_at"] = Date().timeIntervalSince1970
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: stateFile)
    }
    invalidateStateCaches()
}

func readPreferences() -> [String: Any] {
    if let cachedPreferences {
        return cachedPreferences
    }
    guard let data = try? Data(contentsOf: preferencesFile),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        cachedPreferences = [:]
        return [:]
    }
    cachedPreferences = object
    return object
}

func writePreferences(_ prefs: [String: Any]) {
    ensureRuntime()
    cachedPreferences = prefs
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

func readStringPreference(_ key: String) -> String? {
    readPreferences()[key] as? String
}

func readCGFloatPreference(_ key: String) -> CGFloat? {
    guard let value = readDoublePreference(key) else { return nil }
    return CGFloat(value)
}

func loadRealTrafficLightImages() -> [String: NSImage] {
    var images: [String: NSImage] = [:]
    for state in stateOrder {
        if let image = loadRealTrafficLightImage(named: "\(realTrafficLightAssetPrefix)-\(state).png") {
            images[state] = image
        }
    }
    return images
}

func loadRealTrafficLightImage(named assetName: String) -> NSImage? {
    let executableDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let candidates = [
        executableDir.appendingPathComponent("Assets").appendingPathComponent(assetName),
        currentDir.appendingPathComponent("Assets").appendingPathComponent(assetName),
        supportDir.appendingPathComponent("Assets").appendingPathComponent(assetName)
    ]

    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
        return NSImage(contentsOf: url)
    }
    return nil
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

guard acquireSingleInstanceLock() else {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
