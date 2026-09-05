import Foundation
import IOKit

/// Reads the cumulative `Statistics` of every IOBlockStorageDriver in one
/// registry traversal. Tier 0: no privileges needed.
public enum DiskStatsSampler {
    /// Sample every attached whole disk. Disks without a BSD name (not yet
    /// probed, or virtual) are skipped.
    public static func sample() -> [DiskSample] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var out: [DiskSample] = []
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            guard let stats = IORegistry.property(driver, "Statistics") as? [String: Any],
                  let bsd = IORegistry.wholeDiskBSDName(under: driver) else { continue }
            func n(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
            out.append(DiskSample(
                id: bsd,
                bytesRead: n("Bytes (Read)"),
                bytesWritten: n("Bytes (Write)"),
                opsRead: n("Operations (Read)"),
                opsWritten: n("Operations (Write)"),
                timeReadNs: n("Total Time (Read)"),
                timeWriteNs: n("Total Time (Write)")
            ))
        }
        return out.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}

/// Small IORegistry helpers shared by the storage samplers.
enum IORegistry {
    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func name(_ entry: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buf) == KERN_SUCCESS else { return "" }
        return String(cString: buf)
    }

    static func className(_ entry: io_registry_entry_t) -> String {
        guard let cls = IOObjectCopyClass(entry)?.takeRetainedValue() else { return "" }
        return cls as String
    }

    static func conforms(_ entry: io_registry_entry_t, to cls: String) -> Bool {
        IOObjectConformsTo(entry, cls) != 0
    }

    /// The whole-disk IOMedia directly below a block storage driver.
    static func wholeDiskBSDName(under driver: io_registry_entry_t) -> String? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            guard conforms(child, to: "IOMedia") else { continue }
            if (property(child, "Whole") as? Bool) == true, let bsd = property(child, "BSD Name") as? String {
                return bsd
            }
        }
        return nil
    }

    /// The IOMedia entry with a given BSD name, retained; caller releases.
    static func media(bsdName: String) -> io_registry_entry_t? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        return entry == 0 ? nil : entry
    }

    /// Walk parents in the service plane, calling `visit` for each until it
    /// returns false. Releases every intermediate entry.
    static func walkParents(of entry: io_registry_entry_t, _ visit: (io_registry_entry_t) -> Bool) {
        var current = entry
        IOObjectRetain(current)
        while true {
            var parent: io_registry_entry_t = 0
            let ok = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS
            IOObjectRelease(current)
            guard ok, parent != 0 else { return }
            current = parent
            if !visit(current) {
                IOObjectRelease(current)
                return
            }
        }
    }
}
