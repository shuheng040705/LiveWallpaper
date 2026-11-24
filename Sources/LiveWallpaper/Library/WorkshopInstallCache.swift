import Foundation

/// A worker owns both its Steam manifest and the files listed in it. Steam can reuse
/// those files when constructing another item's update, even during a single-item command.
enum WorkshopInstallCache {
    static func copyToLibrary(from source: String, to destination: URL) throws {
        // APFS clones file contents on the same volume. Other filesystems use a normal copy.
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW)
        guard copyfile(source, destination.path, nil, flags) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Only called before starting this worker. Previous versions moved its committed
    /// files out of Steam's content directory but left their manifest records installed.
    static func repairManifest(in root: URL, appID: String) throws {
        let fm = FileManager.default
        let workshop = root.appendingPathComponent("steamapps/workshop")
        let manifest = workshop.appendingPathComponent("appworkshop_\(appID).acf")
        guard fm.fileExists(atPath: manifest.path) else { return }
        var text = try String(contentsOf: manifest, encoding: .utf8)
        guard let installed = CrossOverSteamClient.namedBlock("WorkshopItemsInstalled", in: text) else { return }

        // Only match Valve-generated numeric item records. Unknown structures/fields
        // remain byte-for-byte intact. Never remove uninstalled in-progress items.
        let item = try NSRegularExpression(pattern: #"(?m)^\h*"([0-9]+)"\s*\{[^{}]*\}\h*(?:\r?\n|$)"#)
        var missing = Set<String>()
        for match in item.matches(in: installed, range: NSRange(installed.startIndex..., in: installed)) {
            guard let range = Range(match.range(at: 1), in: installed) else { continue }
            let id = String(installed[range])
            let folder = workshop.appendingPathComponent("content/\(appID)/\(id)")
            if !fm.fileExists(atPath: folder.path) { missing.insert(id) }
        }
        guard !missing.isEmpty else { return }

        for section in ["WorkshopItemsInstalled", "WorkshopItemDetails"] {
            guard let token = text.range(of: "\"" + section + "\""),
                  let body = CrossOverSteamClient.namedBlock(section, in: text), !body.isEmpty,
                  let bodyRange = text.range(of: body, range: token.upperBound..<text.endIndex) else { continue }
            let edited = NSMutableString(string: body)
            for match in item.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed() {
                if let range = Range(match.range(at: 1), in: body), missing.contains(String(body[range])) {
                    edited.deleteCharacters(in: match.range)
                }
            }
            text.replaceSubrange(bodyRange, with: edited as String)
        }
        try text.write(to: manifest, atomically: true, encoding: .utf8)
        Log.write("WorkshopDownloader: repaired \(missing.count) missing private Steam cache records")
    }
}
