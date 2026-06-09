import Foundation

public enum ArchiveByteFormatter {
    public static func string(_ value: Int64?, isDirectory: Bool = false) -> String {
        if isDirectory { return "\u{2014}" }
        guard let value, value >= 0 else { return "\u{2014}" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

public enum ArchiveDateFormatter {
    public static func string(_ date: Date?) -> String {
        guard let date else { return "\u{2014}" }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0
        )
    }
}
