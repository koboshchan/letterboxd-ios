import XCTest
import Foundation

/// Source-level audit: Search must stay films-only (no Members scope, picker or member routing).
final class NoMemberSearchTests: XCTestCase {
    func testSearchSourceHasNoMemberSearch() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Letterboxd/BrowseSearch.swift")
        let src = try String(contentsOf: url, encoding: .utf8).lowercased()
        for banned in ["members", "searchscopes", "scope", "memberlistscreen", "networkroute", "memberroute", "searchmembers"] {
            XCTAssertFalse(src.contains(banned), "BrowseSearch.swift must not contain \(banned)")
        }
        XCTAssertTrue(src.contains("prompt: \"films\""))
    }
}
