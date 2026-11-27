import Foundation

/// A Workshop shared preset owns settings and optional media. Its dependency owns the project entry point.
struct SharedWallpaperPreset {
    let dependencyID: String
    let values: [String: Any]
    let folder: URL

    init?(project: [String: Any], folder: URL) {
        guard let values = project["preset"] as? [String: Any],
              let raw = (project["dependency"] as? String) ?? (project["dependency"] as? NSNumber)?.stringValue,
              !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let numericID = UInt64(raw), numericID != 0,
              String(numericID) != folder.lastPathComponent else { return nil }
        self.values = values
        dependencyID = String(numericID)
        self.folder = folder
    }

    static func project(at folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Validate both the sibling template and each package-local media file independently.
    var installedTemplate: (folder: URL, project: [String: Any])? {
        let root = folder.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(dependencyID, isDirectory: true)
        let real = candidate.resolvingSymlinksInPath()
        guard real.deletingLastPathComponent().path == root.path,
              let project = Self.project(at: real),
              WallpaperType(raw: project["type"] as? String) != .unknown,
              LocalWallpaperProbe.isReady(at: real) else { return nil }
        return (real, project)
    }

    enum ResourceKind: String { case file, directory }

    private static func normalizedPath(_ text: String) -> String? {
        let path = text.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        let components = path.split(separator: "/").filter { $0 != "." }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    static func relativeAsset(_ value: Any?) -> String? {
        guard let value = value as? String, let path = normalizedPath(value),
              path == "files" || path.hasPrefix("files/") else { return nil }
        return path
    }

    static func resource(_ path: String, in folder: URL, kind: ResourceKind? = nil) -> URL? {
        guard let path = normalizedPath(path), !path.split(separator: "/").contains("..") else { return nil }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let target = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard target.pathComponents.starts(with: root.pathComponents),
              target.pathComponents.count > root.pathComponents.count,
              let attributes = try? target.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else { return nil }
        let matches = (kind != .directory && attributes.isRegularFile == true)
            || (kind != .file && attributes.isDirectory == true)
        return matches ? target : nil
    }

    static func file(_ path: String, in folder: URL) -> URL? {
        resource(path, in: folder, kind: .file)
    }

    var mediaPaths: Set<String> { Set(values.values.compactMap(Self.relativeAsset)) }

    var singleVideoURL: URL? {
        let extensions: Set<String> = ["mp4", "m4v", "mov", "webm", "ogv"]
        let videos = mediaPaths.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
        guard videos.count == 1, let path = videos.first else { return nil }
        return Self.file(path, in: folder)
    }

    func general(using template: [String: Any]) -> [String: Any] {
        var general = template["general"] as? [String: Any] ?? [:]
        var properties = general["properties"] as? [String: Any] ?? [:]
        for (key, value) in values {
            guard !(value is NSNull), var property = properties[key] as? [String: Any] else { continue }
            property["value"] = value
            if let type = property["type"] as? String, let kind = ResourceKind(rawValue: type.lowercased()) {
                var resource = URLComponents()
                resource.scheme = WebRenderer.scheme
                resource.host = "wp"
                if let path = Self.relativeAsset(value), Self.resource(path, in: folder, kind: kind) != nil {
                    resource.path = "/" + WebRenderer.presetFilesPrefix + path + (kind == .directory ? "/" : "")
                    property["value"] = resource.url?.absoluteString ?? ""
                } else {
                    property["value"] = ""
                }
            } else if property["type"] as? String == "color", let hex = value as? String,
                      hex.count == 7, hex.hasPrefix("#"), let rgb = UInt32(hex.dropFirst(), radix: 16) {
                property["value"] = [16, 8, 0].map { String(Double((rgb >> $0) & 255) / 255) }.joined(separator: " ")
            }
            properties[key] = property
        }
        general["properties"] = properties
        return general
    }
}
