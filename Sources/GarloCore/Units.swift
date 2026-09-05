import Foundation

/// Number formatting for findings: real units, rounded to what matters.
public enum Units {
    /// "12.7 MB/s", "8.0 MB/s", "312 KB/s". One decimal for MB and above.
    public static func rate(_ bytesPerSec: Double) -> String {
        bytes(bytesPerSec, perSecond: true)
    }

    /// "50.6 GB", "128 KB", "12 TB".
    public static func bytes(_ bytes: Double, perSecond: Bool = false) -> String {
        let suffix = perSecond ? "/s" : ""
        let abs = Swift.abs(bytes)
        if abs >= 1e12 { return String(format: "%.1f TB%@", bytes / 1e12, suffix) }
        if abs >= 1e9 { return String(format: "%.1f GB%@", bytes / 1e9, suffix) }
        if abs >= 1e6 { return String(format: "%.1f MB%@", bytes / 1e6, suffix) }
        if abs >= 1e3 { return String(format: "%.0f KB%@", bytes / 1e3, suffix) }
        return String(format: "%.0f B%@", bytes, suffix)
    }

    /// Binary size for request sizes and pieces: "128 KiB", "32 MiB".
    public static func binaryBytes(_ bytes: Double) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.1f GiB", bytes / 1_073_741_824) }
        if bytes >= 1_048_576 { return String(format: "%.0f MiB", bytes / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.0f KiB", bytes / 1024) }
        return String(format: "%.0f B", bytes)
    }

    public static func ops(_ opsPerSec: Double) -> String {
        String(format: "%.0f ops/s", opsPerSec)
    }

    public static func ms(_ ms: Double) -> String {
        ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms)
    }

    public static func percent(_ fraction: Double) -> String {
        String(format: "%.0f percent", fraction * 100)
    }

    public static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// "about 35 min", "about 2 h 10 min", "under a minute".
    public static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "under a minute" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "about \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "about \(h) h" : "about \(h) h \(m) min"
    }

    /// Clock time, no ticking: "13:50".
    public static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
