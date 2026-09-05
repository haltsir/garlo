import Foundation
import IOKit

/// Disks, the buses they sit behind, and the volumes mounted on them.
/// Refreshed every 30 s, not every tick. Tier 0.
public enum TopologySampler {
    public static func sample(defragStatus: Bool = true) -> Topology {
        let disks = wholeDisks()
        var volumes = mountedVolumes()
        for i in volumes.indices {
            volumes[i].diskID = physicalDisk(forVolumeBSD: volumes[i].bsdName)
            if defragStatus, volumes[i].fileSystem == "apfs",
               let disk = disks.first(where: { $0.id == volumes[i].diskID }), disk.behavesRotational {
                volumes[i].defragmentEnabled = DefragStatus.shared.status(volumeBSD: volumes[i].bsdName)
            }
        }
        return Topology(disks: disks, volumes: volumes)
    }

    // MARK: Disks

    static func wholeDisks() -> [DiskDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [DiskDevice] = []
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            guard let bsd = IORegistry.wholeDiskBSDName(under: driver) else { continue }
            out.append(describe(driver: driver, bsd: bsd))
        }
        return out.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func describe(driver: io_registry_entry_t, bsd: String) -> DiskDevice {
        var vendor = "", product = "", medium = "", interconnect = "", location = ""
        var size: UInt64 = 0
        var usbDevices: [(name: String, speed: USBSpeed, version: Int?)] = []
        var controller = ""

        // size from the whole-disk media
        var children: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(driver, kIOServicePlane, &children) == KERN_SUCCESS {
            while case let child = IOIteratorNext(children), child != 0 {
                if (IORegistry.property(child, "BSD Name") as? String) == bsd {
                    size = (IORegistry.property(child, "Size") as? NSNumber)?.uint64Value ?? 0
                }
                IOObjectRelease(child)
            }
            IOObjectRelease(children)
        }

        IORegistry.walkParents(of: driver) { entry in
            if medium.isEmpty, let dc = IORegistry.property(entry, "Device Characteristics") as? [String: Any] {
                vendor = (dc["Vendor Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? vendor
                product = (dc["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? product
                medium = dc["Medium Type"] as? String ?? ""
            }
            if interconnect.isEmpty, let pc = IORegistry.property(entry, "Protocol Characteristics") as? [String: Any] {
                interconnect = pc["Physical Interconnect"] as? String ?? ""
                location = pc["Physical Interconnect Location"] as? String ?? ""
            }
            if IORegistry.conforms(entry, to: "IOUSBHostDevice") {
                let name = IORegistry.property(entry, "USB Product Name") as? String ?? IORegistry.name(entry)
                let speed = USBSpeed(rawValue: (IORegistry.property(entry, "Device Speed") as? NSNumber)?.intValue ?? -1) ?? .high
                let version = (IORegistry.property(entry, "bcdUSB") as? NSNumber)?.intValue
                usbDevices.append((name, speed, version))
            } else if !usbDevices.isEmpty, controller.isEmpty {
                // the host controller, not one of its port entries
                let cls = IORegistry.className(entry)
                if IORegistry.conforms(entry, to: "IOUSBHostController") || (cls.contains("XHCI") && !cls.contains("Port")) {
                    controller = IORegistry.name(entry)
                    return false
                }
            }
            return true
        }

        let media: MediaKind
        switch medium {
        case "Solid State": media = .solidState
        case "Rotational": media = .rotational
        default: media = .unknown
        }
        let usb: USBLink? = usbDevices.first.map { dev in
            USBLink(productName: dev.name, speed: dev.speed, declaredVersion: dev.version,
                    hubs: usbDevices.dropFirst().map(\.name), controller: controller)
        }
        let name = [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
        return DiskDevice(
            id: bsd,
            name: name.isEmpty ? (usb?.productName ?? bsd) : name,
            sizeBytes: size,
            interconnect: interconnect,
            isInternal: location == "Internal" || interconnect == "Apple Fabric",
            media: media,
            usb: usb
        )
    }

    // MARK: Volumes

    /// Free bytes per mount point, cheap enough for every tick.
    public static func freeSpace() -> [String: UInt64] {
        Dictionary(mountedVolumes().map { ($0.mountPoint, $0.freeBytes) }, uniquingKeysWith: { a, _ in a })
    }

    static func mountedVolumes() -> [Volume] {
        var count = Darwin.getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var stats = Array<Darwin.statfs>(repeating: Darwin.statfs(), count: Int(count))
        count = Darwin.getfsstat(&stats, Int32(MemoryLayout<statfs>.stride * Int(count)), MNT_NOWAIT)
        guard count > 0 else { return [] }
        var out: [Volume] = []
        for var st in stats.prefix(Int(count)) {
            let from = withUnsafePointer(to: &st.f_mntfromname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let on = withUnsafePointer(to: &st.f_mntonname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let type = withUnsafePointer(to: &st.f_fstypename) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            guard from.hasPrefix("/dev/disk") else { continue }
            // system-internal APFS volumes are noise for the user
            if on.hasPrefix("/System/Volumes/") && on != "/System/Volumes/Data" { continue }
            if on.hasPrefix("/private/var/") || on.hasPrefix("/Library/Developer/") { continue }
            let bsd = String(from.dropFirst("/dev/".count))
            let name: String = {
                if on == "/" || on == "/System/Volumes/Data" { return "Macintosh HD" }
                return URL(fileURLWithPath: on).lastPathComponent
            }()
            out.append(Volume(
                mountPoint: on,
                name: name,
                bsdName: bsd,
                diskID: nil,
                totalBytes: UInt64(st.f_blocks) * UInt64(st.f_bsize),
                freeBytes: UInt64(st.f_bavail) * UInt64(st.f_bsize),
                fileSystem: type,
                isReadOnly: st.f_flags & UInt32(MNT_RDONLY) != 0
            ))
        }
        // "/" and "/System/Volumes/Data" are one disk; keep the Data volume
        // (where files live) and drop the sealed system volume.
        if out.contains(where: { $0.mountPoint == "/System/Volumes/Data" }) {
            out.removeAll { $0.mountPoint == "/" }
        }
        return out
    }

    /// Walk from a volume's IOMedia up to the physical whole disk. APFS
    /// volumes hang under a synthesized container whose parent chain reaches
    /// the physical store's media.
    static func physicalDisk(forVolumeBSD bsd: String) -> String? {
        guard let media = IORegistry.media(bsdName: bsd) else { return nil }
        defer { IOObjectRelease(media) }
        var found: String?
        IORegistry.walkParents(of: media) { entry in
            guard IORegistry.conforms(entry, to: "IOMedia") else { return true }
            if (IORegistry.property(entry, "Whole") as? Bool) == true,
               let name = IORegistry.property(entry, "BSD Name") as? String,
               IORegistry.conforms(entry, to: "IOMedia"),
               !isSynthesized(entry) {
                found = name
                return false
            }
            return true
        }
        return found
    }

    /// Synthesized APFS whole disks (disk5 for container of disk4s2) sit
    /// under an AppleAPFSContainerScheme; physical ones under a driver.
    private static func isSynthesized(_ media: io_registry_entry_t) -> Bool {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(media, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        return IORegistry.className(parent).contains("APFS")
    }
}

/// `diskutil apfs defragment <vol> status`, cached per volume for an hour.
/// Only asked for volumes on rotational media, where it matters.
final class DefragStatus: @unchecked Sendable {
    static let shared = DefragStatus()
    private let lock = NSLock()
    private var cache: [String: (Bool?, Date)] = [:]

    func status(volumeBSD: String) -> Bool? {
        lock.lock()
        if let hit = cache[volumeBSD], Date().timeIntervalSince(hit.1) < 3600 {
            lock.unlock()
            return hit.0
        }
        lock.unlock()
        let value = query(volumeBSD)
        lock.lock()
        cache[volumeBSD] = (value, Date())
        lock.unlock()
        return value
    }

    private func query(_ bsd: String) -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["apfs", "defragment", bsd, "status"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else { return nil }
        if text.contains("enabled") && !text.contains("not enabled") && !text.contains("disabled") { return true }
        if text.contains("disabled") || text.contains("not enabled") { return false }
        return nil
    }
}
