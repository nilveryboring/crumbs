import Darwin

/// One directory entry as `getattrlistbulk(2)` returns it. The name pointer
/// is only valid inside the callback.
struct BulkEntry {
    var namePointer: UnsafePointer<CChar>
    var type: UInt32
    var device: Int32
    var modifiedSeconds: Int
    var fileID: UInt64
    var linkCount: UInt32
    var allocatedSize: Int64

    var name: String { String(cString: namePointer) }
    var isDirectory: Bool { type == 2 } // VDIR
    var isRegularFile: Bool { type == 1 } // VREG
    var isSymlink: Bool { type == 5 } // VLNK
}

/// Reads whole directories a buffer at a time instead of one lstat per file.
/// Several times faster than fts on APFS, which is what makes a full-disk
/// scan tolerable.
private func bits<T: BinaryInteger>(_ value: T) -> attrgroup_t { attrgroup_t(truncatingIfNeeded: value) }

enum BulkDirectory {
    private static let bufferSize = 256 * 1024

    /// Calls `body` for each entry of `path`. Returns false when the folder
    /// can't be opened (permissions, vanished, not a directory).
    @discardableResult
    static func forEach(_ path: String, _ body: (BulkEntry) -> Void) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = bits(ATTR_CMN_RETURNED_ATTRS) | bits(ATTR_CMN_ERROR) | bits(ATTR_CMN_NAME)
            | bits(ATTR_CMN_DEVID) | bits(ATTR_CMN_OBJTYPE) | bits(ATTR_CMN_MODTIME) | bits(ATTR_CMN_FILEID)
        request.fileattr = bits(ATTR_FILE_LINKCOUNT) | bits(ATTR_FILE_ALLOCSIZE)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count <= 0 { return count == 0 }
            var cursor = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                defer { cursor += length }
                var p = cursor + 4
                let returned = p.loadUnaligned(as: attribute_set_t.self)
                p += MemoryLayout<attribute_set_t>.size
                let common = returned.commonattr
                let file = returned.fileattr

                // Fields are packed in bit order, except ERROR which comes first.
                if common & bits(ATTR_CMN_ERROR) != 0 {
                    let error = p.loadUnaligned(as: UInt32.self)
                    p += 4
                    if error != 0 { continue }
                }
                guard common & bits(ATTR_CMN_NAME) != 0 else { continue }
                let nameRef = p.loadUnaligned(as: attrreference_t.self)
                let namePointer = (p + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                p += MemoryLayout<attrreference_t>.size

                var entry = BulkEntry(namePointer: namePointer, type: 0, device: 0, modifiedSeconds: 0,
                                      fileID: 0, linkCount: 1, allocatedSize: 0)
                if common & bits(ATTR_CMN_DEVID) != 0 {
                    entry.device = p.loadUnaligned(as: Int32.self)
                    p += 4
                }
                if common & bits(ATTR_CMN_OBJTYPE) != 0 {
                    entry.type = p.loadUnaligned(as: UInt32.self)
                    p += 4
                }
                if common & bits(ATTR_CMN_MODTIME) != 0 {
                    entry.modifiedSeconds = p.loadUnaligned(as: Int.self)
                    p += MemoryLayout<timespec>.size
                }
                if common & bits(ATTR_CMN_FILEID) != 0 {
                    entry.fileID = p.loadUnaligned(as: UInt64.self)
                    p += 8
                }
                if file & bits(ATTR_FILE_LINKCOUNT) != 0 {
                    entry.linkCount = p.loadUnaligned(as: UInt32.self)
                    p += 4
                }
                if file & bits(ATTR_FILE_ALLOCSIZE) != 0 {
                    entry.allocatedSize = p.loadUnaligned(as: Int64.self)
                    p += 8
                }
                body(entry)
            }
        }
    }
}
