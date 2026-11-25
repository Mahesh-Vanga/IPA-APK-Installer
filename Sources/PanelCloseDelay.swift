enum PanelCloseDelay: Int, CaseIterable {
    case immediate = 0
    case quarterSecond = 250
    case halfSecond = 500
    case oneSecond = 1_000
    case twoSeconds = 2_000
    case threeSeconds = 3_000
    case fourSeconds = 4_000
    case fiveSeconds = 5_000
    case sixSeconds = 6_000
    case sevenSeconds = 7_000
    case eightSeconds = 8_000
    case nineSeconds = 9_000
    case tenSeconds = 10_000

    var label: String {
        switch self {
        case .immediate: return "Immediately"
        case .quarterSecond: return "0.25 seconds"
        case .halfSecond: return "0.5 seconds"
        case .oneSecond: return "1 second"
        default: return "\(rawValue / 1_000) seconds"
        }
    }
}

struct PanelCloseCountdown {
    var delay: Double = 0
    private var exitedAt: Double?

    init(delay: Double = 0) { self.delay = delay }

    mutating func reset() { exitedAt = nil }

    mutating func shouldClose(pointerInside: Bool, now: Double) -> Bool {
        if pointerInside { reset(); return false }
        if delay == 0 { return true }
        if let exitedAt { return now - exitedAt >= delay }
        exitedAt = now
        return false
    }
}
