import Foundation
import Testing
@testable import OpenStream

struct PopupGuardTests {
    @Test func sameSiteAcceptsSubdomains() throws {
        let a = try #require(URL(string: "https://fs26.lol/show"))
        let b = try #require(URL(string: "https://www.fs26.lol/x"))
        #expect(PopupGuard.sameSite(current: a, target: b))
        #expect(PopupGuard.sameSite(current: b, target: a))
    }

    @Test func sameSiteRejectsCrossHost() throws {
        let page = try #require(URL(string: "https://fs26.lol/index.php?newsid=1"))
        let ad = try #require(URL(string: "https://evil-ads.example/click"))
        #expect(!PopupGuard.sameSite(current: page, target: ad))
    }

    @Test func blankInPlaceRequiresUserAndSameSite() throws {
        let page = try #require(URL(string: "https://fs26.lol/"))
        let same = try #require(URL(string: "https://fs26.lol/page"))
        let ad = try #require(URL(string: "https://popcash.net/x"))
        #expect(PopupGuard.shouldOpenBlankInPlace(currentPage: page, target: same, userActivated: true))
        #expect(!PopupGuard.shouldOpenBlankInPlace(currentPage: page, target: same, userActivated: false))
        #expect(!PopupGuard.shouldOpenBlankInPlace(currentPage: page, target: ad, userActivated: true))
    }
}
