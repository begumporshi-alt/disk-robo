import Foundation

/// Mounted volume inventory (internal + external, browsable only).
/// Network volumes are listed too — scanning them is the user's explicit choice.
public enum VolumeManager {
    public static func list() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityKey, .volumeIsBrowsableKey, .volumeUUIDStringKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                               options: [.skipHiddenVolumes]) else { return [] }
        var out: [VolumeInfo] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.volumeIsBrowsable == false { continue }
            let id = v.volumeUUIDString ?? url.path
            out.append(VolumeInfo(id: id, url: url,
                                  name: v.volumeName ?? url.lastPathComponent,
                                  isInternal: v.volumeIsInternal ?? false,
                                  totalBytes: Int64(v.volumeTotalCapacity ?? 0),
                                  availableBytes: Int64(v.volumeAvailableCapacity ?? 0)))
        }
        return out.sorted { a, b in
            if a.isInternal != b.isInternal { return a.isInternal }
            return a.totalBytes > b.totalBytes
        }
    }

    /// Volume stats for an arbitrary path's volume.
    public static func info(for url: URL) -> VolumeInfo? {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityKey, .volumeUUIDStringKey]
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let volumeURL = Self.volumeRootURL(for: url)
        return VolumeInfo(id: v.volumeUUIDString ?? volumeURL.path, url: volumeURL,
                          name: v.volumeName ?? volumeURL.lastPathComponent,
                          isInternal: v.volumeIsInternal ?? false,
                          totalBytes: Int64(v.volumeTotalCapacity ?? 0),
                          availableBytes: Int64(v.volumeAvailableCapacity ?? 0))
    }

    /// Best-effort mount-point URL for a path ("/" or "/Volumes/<name>").
    static func volumeRootURL(for url: URL) -> URL {
        let resolved = url.resolvingSymlinksInPath().path
        if resolved == "/" { return URL(fileURLWithPath: "/") }
        if resolved.hasPrefix("/Volumes/") {
            let rest = resolved.dropFirst("/Volumes/".count)
            if let slash = rest.firstIndex(of: "/"), slash != rest.startIndex {
                return URL(fileURLWithPath: "/Volumes/" + rest[..<slash])
            }
            if !rest.isEmpty { return URL(fileURLWithPath: "/Volumes/" + rest) }
        }
        return URL(fileURLWithPath: "/")
    }
}
