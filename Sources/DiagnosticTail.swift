// Preserve the latest 32 KiB without cutting a multibyte character.
func boundedDiagnosticTail(_ text: String, maxBytes: Int = 32 * 1024) -> String {
    let bytes = text.utf8
    guard maxBytes > 0 else { return "" }
    guard bytes.count > maxBytes else { return text }
    var suffix = bytes.suffix(maxBytes)
    while let first = suffix.first, first & 0xC0 == 0x80 {
        suffix = suffix.dropFirst()
    }
    return String(decoding: suffix, as: UTF8.self)
}
