import Foundation

/// Saves corrected copies to a folder chosen by the user.
///
/// The generated copies live in a temporary folder that is cleaned after 24 hours. Saving copies
/// them to a place that is never cleaned. It only ever adds files: an existing file is never
/// overwritten or removed, and the source photos are never touched.
enum ExportService {
    enum ExportError: LocalizedError {
        case notAFolder(URL)
        case copyFailed(URL, String)

        var errorDescription: String? {
            switch self {
            case .notAFolder(let url):
                return trf("The destination is not a usable folder: %@", url.lastPathComponent)
            case .copyFailed(let url, let detail):
                return trf("Unable to save %@: %@", url.lastPathComponent, detail)
            }
        }
    }

    /// First URL in `folder` that does not exist yet: `name.ext`, then `name 2.ext`, `name 3.ext`...
    static func uniqueURL(in folder: URL, baseName: String, pathExtension: String) -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(pathExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(counter)").appendingPathExtension(pathExtension)
            counter += 1
        }
        return candidate
    }

    /// Copies `copies` into `folder` and returns the new files. If one copy fails, the copies made
    /// by this call are removed again (they are ours) and the error is thrown.
    static func save(copies: [URL], to folder: URL) throws -> [URL] {
        let hasAccess = folder.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { folder.stopAccessingSecurityScopedResource() }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ExportError.notAFolder(folder)
        }

        var saved: [URL] = []
        for copy in copies {
            let target = uniqueURL(
                in: folder,
                baseName: copy.deletingPathExtension().lastPathComponent,
                pathExtension: copy.pathExtension
            )
            do {
                try FileManager.default.copyItem(at: copy, to: target)
                saved.append(target)
            } catch {
                for created in saved { try? FileManager.default.removeItem(at: created) }
                throw ExportError.copyFailed(copy, error.localizedDescription)
            }
        }
        return saved
    }
}
