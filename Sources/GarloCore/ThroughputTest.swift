import Foundation

/// Opt-in, short, and only run to confirm a suspected finding: download
/// from a user-chosen URL for five seconds and report the achieved rate.
public enum ThroughputTest {
    public struct Result: Sendable, Hashable {
        public var at: Date
        public var url: URL
        public var bytesPerSec: Double
        public var seconds: Double
        public var error: String?
    }

    public static let defaultURL = URL(string: "https://speed.cloudflare.com/__down?bytes=200000000")!

    public static func run(url: URL, seconds: Double = 5) async -> Result {
        let started = Date()
        var received = 0
        var failure: String?
        do {
            let (bytes, _) = try await URLSession.shared.bytes(from: url)
            for try await _ in bytes {
                received += 1
                if received % 65536 == 0, Date().timeIntervalSince(started) >= seconds { break }
            }
        } catch {
            failure = error.localizedDescription
        }
        let elapsed = max(0.001, Date().timeIntervalSince(started))
        return Result(at: Date(), url: url, bytesPerSec: Double(received) / elapsed, seconds: elapsed, error: failure)
    }
}
