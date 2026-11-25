struct StatusTapSequence {
    private var previousTap: Double?

    mutating func reset() { previousTap = nil }

    mutating func isDoubleTap(at time: Double, count: Int, interval: Double) -> Bool {
        // The system count can reset when status windows reorder. Both releases
        // still belong to the same icon and are compared using the system interval.
        let elapsed = previousTap.map { time - $0 }
        let isPair = count == 2 || (count == 1 && elapsed.map { $0 > 0 && $0 <= interval } == true)
        previousTap = isPair || count > 2 ? nil : time
        return isPair
    }
}
