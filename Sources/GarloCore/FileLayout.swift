import Foundation
import Darwin

/// Physical layout of one file, from `fcntl(F_LOG2PHYS_EXT)`. Tier 0; the
/// file only has to be readable.
public struct FileLayout: Codable, Sendable, Hashable {
    public var path: String
    public var sizeBytes: UInt64
    public var pieces: Int
    public var medianPieceBytes: UInt64
    /// Distance between the lowest and highest physical offset touched.
    public var physicalSpanBytes: UInt64
    /// True when the walk stopped at the step budget; `pieces` is a lower bound.
    public var truncated: Bool

    public init(path: String, sizeBytes: UInt64, pieces: Int, medianPieceBytes: UInt64, physicalSpanBytes: UInt64, truncated: Bool) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.pieces = pieces
        self.medianPieceBytes = medianPieceBytes
        self.physicalSpanBytes = physicalSpanBytes
        self.truncated = truncated
    }

    /// Pieces per 8 MB of file: the sequential threshold on rotational
    /// media is 1. A file in one piece scores 0.
    public var piecesPer8MB: Double {
        guard sizeBytes > 0 else { return 0 }
        return Double(pieces) / (Double(sizeBytes) / 8_388_608)
    }

    public var isFragmented: Bool { pieces > 1 && piecesPer8MB > 1 }

    /// Walk the extent map. `maxPieces` bounds the work on pathological files.
    public static func probe(path: String, maxPieces: Int = 400_000) -> FileLayout? {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = UInt64(max(0, st.st_size))
        guard size > 0 else {
            return FileLayout(path: path, sizeBytes: 0, pieces: 0, medianPieceBytes: 0, physicalSpanBytes: 0, truncated: false)
        }

        var sizes: [UInt64] = []
        var offset: UInt64 = 0
        var minPhys = UInt64.max, maxPhys: UInt64 = 0
        var truncated = false
        while offset < size {
            var l2p = log2phys()
            l2p.l2p_flags = 0
            l2p.l2p_contigbytes = off_t(min(size - offset, UInt64(Int64.max / 2)))
            l2p.l2p_devoffset = off_t(offset)
            guard fcntl(fd, F_LOG2PHYS_EXT, &l2p) == 0, l2p.l2p_contigbytes > 0 else { break }
            let contig = UInt64(l2p.l2p_contigbytes)
            let phys = UInt64(max(0, l2p.l2p_devoffset))
            sizes.append(contig)
            minPhys = min(minPhys, phys)
            maxPhys = max(maxPhys, phys + contig)
            offset += contig
            if sizes.count >= maxPieces { truncated = offset < size; break }
        }
        guard !sizes.isEmpty else { return nil }
        let sorted = sizes.sorted()
        return FileLayout(
            path: path,
            sizeBytes: size,
            pieces: sizes.count,
            medianPieceBytes: sorted[sorted.count / 2],
            physicalSpanBytes: maxPhys > minPhys ? maxPhys - minPhys : 0,
            truncated: truncated
        )
    }
}
