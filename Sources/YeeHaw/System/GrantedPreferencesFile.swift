import Foundation
import YeeHawCore

/// One protected preference file, read and written through `CFPreferences` with the file's
/// absolute path minus `.plist` as the domain (spec Technique 2). Every access goes through the
/// file's security-scoped grant.
struct GrantedPreferencesFile: PreferencesFile {
    let file: GrantedFile
    let grants: FileGrantStore

    private var domain: CFString {
        file.url.deletingPathExtension().path as CFString
    }

    /// The key always exists in the real files, so a nil read means access was refused.
    func read(_ key: String) throws -> Any? {
        try withAccess {
            CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            guard let value = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            else { throw GrantError.needsGrant(file) }
            return value
        }
    }

    func write(_ key: String, _ value: Any) throws {
        try withAccess {
            CFPreferencesSetValue(key as CFString, value as CFPropertyList, domain,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
                throw GrantError.needsGrant(file)
            }
        }
    }

    private func withAccess<T>(_ body: () throws -> T) throws -> T {
        guard let url = grants.url(for: file) else { throw GrantError.needsGrant(file) }
        defer { url.stopAccessingSecurityScopedResource() }
        return try body()
    }
}
