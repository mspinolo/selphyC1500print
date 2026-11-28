import Foundation

extension URL {
    /// Runs `body` with sandbox access to this URL (a file the user chose, or one resolved from a
    /// security-scoped bookmark) and gives the access back when `body` returns or throws.
    /// Harmless for a URL that needs no access; nested calls are counted by the system.
    func withSecurityScope<T>(_ body: (URL) throws -> T) rethrows -> T {
        let granted = startAccessingSecurityScopedResource()
        defer { if granted { stopAccessingSecurityScopedResource() } }
        return try body(self)
    }
}
