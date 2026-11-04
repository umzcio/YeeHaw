import Foundation

/// Where an installed YeeHaw looks for new versions: Info.plist's `SUFeedURL` and the public half of
/// the Sparkle key that signs every update (`SUPublicEDKey`). Updates start only when both are
/// there and sane, so a build without them has no updates rather than a broken updater.
public struct UpdateFeed: Equatable, Sendable {
    public let url: URL
    public let publicKey: String

    /// Nil unless the feed is a plain https address (no login, no fragment) and the key is a
    /// base64 Ed25519 public key, 32 bytes.
    public init?(feedURL: String?, publicKey: String?) {
        guard let feedURL, let url = URL(string: feedURL), url.scheme == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil, url.fragment == nil,
              let publicKey, Data(base64Encoded: publicKey)?.count == 32 else { return nil }
        self.url = url
        self.publicKey = publicKey
    }
}
