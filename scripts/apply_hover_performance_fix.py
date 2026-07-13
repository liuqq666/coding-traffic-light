#!/usr/bin/env python3
"""Apply the hover/main-thread performance fix to CodexStatusLight.swift.

This helper is intentionally strict: every replacement must match exactly once so
an upstream source change cannot produce a partial or malformed patch.
"""

from pathlib import Path

SOURCE = Path("Sources/CodexStatusLight.swift")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    text = SOURCE.read_text(encoding="utf-8")

    replacements = [
        (
            "global state/preferences caches",
            r'''var codexThreadOpenabilityCache: [String: (openable: Bool, checkedAt: TimeInterval)] = [:]
''',
            r'''var codexThreadOpenabilityCache: [String: (openable: Bool, checkedAt: TimeInterval)] = [:]
// Pointer movement and animation callbacks run at high frequency. Keep their
// state/preferences lookups in memory; pollState invalidates state caches.
var cachedStateObject: [String: Any]?
var cachedPreferences: [String: Any]?
''',
        ),
        (
            "session/quota caches",
            r'''    var detailText: String {
        "5小时额度剩余 \(percentText)，\(resetTimeText) 重刷"
    }
}

func clipped(_ text: String, limit: Int) -> String {
''',
            r'''    var detailText: String {
        "5小时额度剩余 \(percentText)，\(resetTimeText) 重刷"
    }
}

var cachedActiveSessions: [StatusSession]?
var cachedFiveHourQuota: FiveHourQuota?
var hasCachedFiveHourQuota = false

func clipped(_ text: String, limit: Int) -> String {
''',
        ),
        (
            "hover handler",
            r'''    func updateResizeHandleHover(with event: NSEvent) {
        let hovering = pointIsInResizeHandle(event)
        if hovering != isHoveringResizeHandle {
            isHoveringResizeHandle = hovering
            needsDisplay = true
        }
        if hovering {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }
''',
            r'''    func updateResizeHandleHover(with event: NSEvent) {
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
''',
        ),
        (
            "tooltip update",
            r'''    func updateTooltip() {
        if fiveHourQuotaVisible(), let quota = latestFiveHourQuota() {
            toolTip = "\(labels[state] ?? "空闲")\n\(quota.detailText)"
        } else {
            toolTip = labels[state] ?? "空闲"
        }
    }
''',
            r'''    func updateTooltip() {
        let nextTooltip: String
        if fiveHourQuotaVisible(), let quota = latestFiveHourQuota() {
            nextTooltip = "\(labels[state] ?? "空闲")\n\(quota.detailText)"
        } else {
            nextTooltip = labels[state] ?? "空闲"
        }
        guard toolTip != nextTooltip else { return }
        toolTip = nextTooltip
    }
''',
        ),
        (
            "poll cache invalidation",
            r'''        if shouldForceRecompute {
            lastForcedRecompute = now
        }
        if let command = readCommand() {
''',
            r'''        if shouldForceRecompute {
            lastForcedRecompute = now
        }
        invalidateStateCaches()
        if let command = readCommand() {
''',
        ),
        (
            "writeState cache invalidation",
            r'''func writeState(_ state: String) {
    ensureRuntime()
    let body: [String: Any] = ["state": state, "manual_state": state, "updated_at": Date().timeIntervalSince1970]
    if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]) {
        try? data.write(to: stateFile)
    }
}

func readStateObject() -> [String: Any] {
    guard let data = try? Data(contentsOf: stateFile),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return object
}
''',
            r'''func writeState(_ state: String) {
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
''',
        ),
        (
            "active session snapshot",
            r'''func activeSessions(for targetState: String? = nil) -> [StatusSession] {
    let object = readStateObject()
    guard let sessions = object["sessions"] as? [String: Any] else {
        return []
    }
    var result: [StatusSession] = []
    for (id, value) in sessions {
        guard let session = makeStatusSession(id: id, value: value) else {
            continue
        }
        if let targetState, session.state != targetState {
            continue
        }
        guard sessionIsFresh(session) else {
            continue
        }
        result.append(session)
    }
    return result.sorted { lhs, rhs in
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.id < rhs.id
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}
''',
            r'''func activeSessions(for targetState: String? = nil) -> [StatusSession] {
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
''',
        ),
        (
            "quota snapshot",
            r'''func latestFiveHourQuota() -> FiveHourQuota? {
    let object = readStateObject()
    if let quota = fiveHourQuota(from: object) {
        return quota
    }

    var seen = Set<String>()
    let sessions = attentionSessions() + activeSessions()
    for session in sessions where !seen.contains(session.id) {
        seen.insert(session.id)
        if let quota = session.fiveHourQuota {
            return quota
        }
    }

    if let rawSessions = object["sessions"] as? [String: Any] {
        let allSessions = rawSessions.compactMap { makeStatusSession(id: $0.key, value: $0.value) }
            .sorted { $0.updatedAt > $1.updatedAt }
        for session in allSessions where !seen.contains(session.id) {
            seen.insert(session.id)
            if let quota = session.fiveHourQuota {
                return quota
            }
        }
    }
    return nil
}
''',
            r'''func latestFiveHourQuota() -> FiveHourQuota? {
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
''',
        ),
        (
            "acknowledge cache invalidation",
            r'''    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: stateFile)
    }
}

func openCodexSession(_ sessionID: String) {
''',
            r'''    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: stateFile)
    }
    invalidateStateCaches()
}

func openCodexSession(_ sessionID: String) {
''',
        ),
        (
            "clear command cache invalidation",
            r'''func clearCommand() {
    var object = readStateObject()
    object.removeValue(forKey: "command")
    object["updated_at"] = Date().timeIntervalSince1970
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: stateFile)
    }
}

func readPreferences() -> [String: Any] {
''',
            r'''func clearCommand() {
    var object = readStateObject()
    object.removeValue(forKey: "command")
    object["updated_at"] = Date().timeIntervalSince1970
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: stateFile)
    }
    invalidateStateCaches()
}

func readPreferences() -> [String: Any] {
''',
        ),
        (
            "preferences snapshot",
            r'''func readPreferences() -> [String: Any] {
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
''',
            r'''func readPreferences() -> [String: Any] {
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
''',
        ),
    ]

    for label, old, new in replacements:
        text = replace_once(text, old, new, label)

    SOURCE.write_text(text, encoding="utf-8")
    print(f"Patched {SOURCE}")


if __name__ == "__main__":
    main()
