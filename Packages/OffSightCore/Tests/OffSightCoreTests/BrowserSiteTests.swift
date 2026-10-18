import XCTest
@testable import OffSightCore

final class BrowserSiteTests: XCTestCase {
    func testHostOnly() {
        XCTAssertEqual(BrowserSite.host(fromURL: "https://meet.google.com/abc-defg-hij?authuser=0"), "meet.google.com")
        XCTAssertEqual(BrowserSite.host(fromURL: "https://teams.microsoft.com/l/meetup-join/19%3a…"), "teams.microsoft.com")
        XCTAssertEqual(BrowserSite.host(fromURL: "https://www.example.com/x"), "example.com")
        XCTAssertEqual(BrowserSite.host(fromURL: "HTTPS://Zoom.US/j/123"), "zoom.us")
        XCTAssertEqual(BrowserSite.host(fromURL: "  https://app.zoom.us/wc/123/join  "), "app.zoom.us")
    }

    func testNonWebURLsHaveNoSite() {
        XCTAssertNil(BrowserSite.host(fromURL: "chrome://newtab/"))
        XCTAssertNil(BrowserSite.host(fromURL: "about:blank"))
        XCTAssertNil(BrowserSite.host(fromURL: "file:///Users/me/a.html"))
        XCTAssertNil(BrowserSite.host(fromURL: ""))
        XCTAssertNil(BrowserSite.host(fromURL: "missing value"))
    }

    func testLabel() {
        XCTAssertEqual(BrowserSite.label(browser: "Google Chrome", host: "meet.google.com"), "Google Chrome — meet.google.com")
        XCTAssertEqual(BrowserSite.label(browser: "Safari", host: nil), "Safari")
        XCTAssertEqual(BrowserSite.label(browser: "Safari", host: ""), "Safari")
    }
}
