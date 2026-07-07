#!/bin/zsh
set -e

cd "$(dirname "$0")/.."
SOURCE="Sources/CodexStatusLight.swift"

perl -0pi -e 's/let defaultDoneAutoIdleSeconds: TimeInterval = 10 \* 60\n//; s/\nfunc doneAutoIdleInterval\(\) -> TimeInterval \{\n    max\(10, readDoublePreference\("done_auto_idle_seconds"\) \?\? defaultDoneAutoIdleSeconds\)\n\}\n//;' "$SOURCE"
perl -0pi -e 's!\Q    func lightNeedsAttention(_ light: String) -> Bool {
        !attentionSessions(for: stateName(for: light)).isEmpty
    }
\E!    func lightNeedsAttention(_ light: String) -> Bool {
        let targetState = stateName(for: light)
        switch targetState {
        case "working":
            return !activeSessions(for: targetState).isEmpty
        case "done", "waiting":
            return !attentionSessions(for: targetState).isEmpty
        default:
            return false
        }
    }
!s' "$SOURCE"
perl -0pi -e 's!\Q        guard let session = latestAttentionSession(for: targetState) else {
\E!        guard let session = latestAttentionSession(for: targetState) ?? latestSession(for: targetState) else {
!s' "$SOURCE"
perl -0pi -e 's!\Q    var lastModified = Date.distantPast
    var waitingBlinkStopTimer: Timer?
    var doneAutoIdleTimer: Timer?
\E!    var lastModified = Date.distantPast
    var lastForcedPoll = Date.distantPast
    var waitingBlinkStopTimer: Timer?
!s' "$SOURCE"
perl -0pi -e 's!\Q        guard modified != lastModified else { return }
        lastModified = modified
\E!        let now = Date()
        let fileChanged = modified != lastModified
        let forceRefresh = now.timeIntervalSince(lastForcedPoll) >= 1.0
        guard fileChanged || forceRefresh else { return }
        if fileChanged {
            lastModified = modified
            codexThreadOpenabilityCache.removeAll()
        }
        if forceRefresh {
            lastForcedPoll = now
        }
!s' "$SOURCE"
perl -0pi -e 's!\Q        if state == "done" {
            startDoneAutoIdleTimer()
        } else {
            stopDoneAutoIdleTimer()
        }
\E!!s; s!\Q
    func startDoneAutoIdleTimer() {
        doneAutoIdleTimer?.invalidate()
        doneAutoIdleTimer = Timer.scheduledTimer(withTimeInterval: doneAutoIdleInterval(), repeats: false) { [weak self] _ in
            guard let self, self.view.state == "done" else { return }
            self.applyState("idle", playPrompt: false, writeFile: true)
        }
    }

    func stopDoneAutoIdleTimer() {
        doneAutoIdleTimer?.invalidate()
        doneAutoIdleTimer = nil
    }
\E!!s' "$SOURCE"
perl -0pi -e 's/    let doneMinutesField = NSTextField\(string: ""\)\n//; s!\Q        addLabel("绿灯自动变暗（分钟）", x: left, y: y, width: 190, to: contentView)
        configureField(doneMinutesField, x: fieldX, y: y, in: contentView)
        y -= 34
\E!!s; s/        doneMinutesField\.stringValue = String\(format: "%.1f", doneAutoIdleInterval\(\) \/ 60\)\n//;' "$SOURCE"
perl -0pi -e 's!\Q        let doneSeconds = max(0.5, doneMinutesField.doubleValue) * 60
\E!!s; s!\Q        updatePreference("done_auto_idle_seconds", value: doneSeconds)
\E!!s; s!\Q        if appDelegate?.view.state == "done" {
            appDelegate?.startDoneAutoIdleTimer()
        }
\E!!s' "$SOURCE"
perl -0pi -e 's!\Q    let body: [String: Any] = ["state": state, "manual_state": state, "updated_at": Date().timeIntervalSince1970]
\E!    let body: [String: Any] = ["state": state, "manual_state": state, "sessions": [:], "updated_at": Date().timeIntervalSince1970]
!s; s/for session in attentionSessions\(\) \{/for session in stateCandidateSessions() {/;' "$SOURCE"
perl -0pi -e 's!\Qfunc statePriority(_ state: String) -> Int? {
    switch state {
    case "waiting": return 3
    case "working": return 2
    case "done": return 1
    case "idle": return 0
    default: return nil
    }
}
\E!func statePriority(_ state: String) -> Int? {
    switch state {
    case "waiting": return 3
    case "done": return 2
    case "working": return 1
    case "idle": return 0
    default: return nil
    }
}
!s' "$SOURCE"
perl -0pi -e 's!\Qfunc attentionSessions(for targetState: String? = nil) -> [StatusSession] {
    activeSessions(for: targetState).filter { !$0.isAcknowledged }
}
\E!func attentionSessions(for targetState: String? = nil) -> [StatusSession] {
    activeSessions(for: targetState).filter { !$0.isAcknowledged }
}

func stateCandidateSessions() -> [StatusSession] {
    activeSessions().filter { session in
        switch session.state {
        case "working":
            return true
        case "done", "waiting":
            return !session.isAcknowledged
        default:
            return false
        }
    }
}
!s' "$SOURCE"
perl -0pi -e 's!\Qfunc sessionIsFresh(_ session: StatusSession) -> Bool {
    guard sessionIsOpenable(session) else {
        return false
    }
    let age = Date().timeIntervalSince1970 - session.updatedAt
    if session.state == "done" && age > doneAutoIdleInterval() {
        return false
    }
    if (session.state == "working" || session.state == "waiting") && age > sessionStaleInterval() {
        return false
    }
    return true
}
\E!func sessionIsFresh(_ session: StatusSession) -> Bool {
    guard sessionIsOpenable(session) else {
        return false
    }
    if session.state == "working" {
        let age = Date().timeIntervalSince1970 - session.updatedAt
        return age <= sessionStaleInterval()
    }
    return true
}
!s' "$SOURCE"
perl -0pi -e 's!\Qfunc sessionIsOpenable(_ session: StatusSession) -> Bool {
    guard isUUIDString(session.id) else {
        return true
    }
    let now = Date().timeIntervalSince1970
    if let cached = codexThreadOpenabilityCache[session.id], now - cached.checkedAt < 5 {
        return cached.openable
    }

    let openable = queryCodexThreadOpenability(session)
    codexThreadOpenabilityCache[session.id] = (openable, now)
    return openable
}
\E!func sessionIsOpenable(_ session: StatusSession) -> Bool {
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
!s' "$SOURCE"

if grep -E "doneAutoIdleInterval|done_auto_idle_seconds|doneAutoIdleTimer|startDoneAutoIdleTimer|stopDoneAutoIdleTimer|doneMinutesField|绿灯自动变暗" "$SOURCE" >/dev/null; then
  echo "Swift status rule patch did not fully apply" >&2
  exit 1
fi

mkdir -p build
swiftc -framework Cocoa "$SOURCE" -o build/CodexStatusLight
echo "Built build/CodexStatusLight"
