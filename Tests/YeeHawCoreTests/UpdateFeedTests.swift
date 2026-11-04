import Foundation
import Testing
@testable import YeeHawCore

@Suite struct UpdateFeedTests {
    static let key = "OhIowqI/ExQ1WX74jC+MYxQ110xLpvzLEvdhmhW7BJ4="
    static let feed = "https://github.com/umzcio/YeeHaw/releases/latest/download/appcast.xml"

    @Test func acceptsTheReleaseFeed() throws {
        let configured = try #require(UpdateFeed(feedURL: Self.feed, publicKey: Self.key))
        #expect(configured.url.absoluteString == Self.feed)
        #expect(configured.publicKey == Self.key)
    }

    @Test func aBuildWithoutTheKeysHasNoUpdates() {
        #expect(UpdateFeed(feedURL: nil, publicKey: nil) == nil)
        #expect(UpdateFeed(feedURL: Self.feed, publicKey: nil) == nil)
        #expect(UpdateFeed(feedURL: nil, publicKey: Self.key) == nil)
        #expect(UpdateFeed(feedURL: "", publicKey: "") == nil)
    }

    @Test func refusesFeedsThatArentPlainHTTPS() {
        for feed in ["http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https:///appcast.xml",
                     "https://user:pass@example.com/appcast.xml", "https://example.com/appcast.xml#top"] {
            #expect(UpdateFeed(feedURL: feed, publicKey: Self.key) == nil, "\(feed)")
        }
    }

    @Test func refusesKeysThatArentEd25519() {
        for key in ["not base64!", "AAAA", String(Self.key.dropLast(4)), Self.key + "AAAA"] {
            #expect(UpdateFeed(feedURL: Self.feed, publicKey: key) == nil, "\(key)")
        }
    }
}
