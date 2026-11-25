import Foundation

func menuPanelFrame(anchor: CGRect, visible: CGRect) -> CGRect {
    let safe = visible.insetBy(dx: 8, dy: 8)
    let top = max(safe.minY + 1, min(safe.maxY, anchor.minY - 6))
    let width = min(390, safe.width)
    let height = min(540, top - safe.minY)
    let x = min(max(anchor.midX - width / 2, safe.minX), safe.maxX - width)
    return CGRect(x: x, y: top - height, width: width, height: height)
}


// Keep just the short path from the icon to the top of the panel active.
func menuPanelContainsPointer(_ pointer: CGPoint, anchor: CGRect, panel: CGRect) -> Bool {
    if anchor.contains(pointer) || panel.contains(pointer) { return true }
    let gap = anchor.minY - panel.maxY
    let left = max(anchor.minX, panel.minX)
    let right = min(anchor.maxX, panel.maxX)
    guard gap > 0, right > left else { return false }
    return CGRect(x: left, y: panel.maxY, width: right - left, height: gap).contains(pointer)
}
