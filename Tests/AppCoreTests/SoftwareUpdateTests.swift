import Foundation
import Testing
@testable import AppCore

@Suite("Software update")
struct SoftwareUpdateTests {
    @Test func versionsCompareNumerically() throws {
        let v = { (s: String) in try #require(AppVersion(s)) }
        #expect(try v("0.1.10") > v("0.1.9"))
        #expect(try v("v1.0") == v("1.0.0"))
        #expect(try v("2.0.0") > v("1.99.99"))
        #expect(AppVersion("1.x") == nil)
        #expect(AppVersion("") == nil)
        #expect(try v("v0.2.3").description == "0.2.3")
    }

    private func release(tag: String, asset: String = "Pankapture.dmg", prerelease: Bool = false) -> Data {
        Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/Frank16UX/pankapture/releases/tag/\(tag)",
         "body":"Notes","draft":false,"prerelease":\(prerelease),
         "assets":[{"name":"\(asset)","size":1234,
                    "browser_download_url":"https://github.com/Frank16UX/pankapture/releases/download/\(tag)/\(asset)"}]}
        """.utf8)
    }

    @Test func offersOnlyNewerReleasesWithADiskImage() throws {
        let current = try #require(AppVersion("0.2.0"))
        let update = try #require(try SoftwareUpdate.update(from: release(tag: "v0.2.1"), current: current))
        #expect(update.version.description == "0.2.1")
        #expect(update.downloadURL.lastPathComponent == "Pankapture.dmg")
        #expect(update.byteCount == 1234)
        #expect(update.notes == "Notes")

        #expect(try SoftwareUpdate.update(from: release(tag: "v0.2.0"), current: current) == nil)
        #expect(try SoftwareUpdate.update(from: release(tag: "v0.1.9"), current: current) == nil)
        #expect(try SoftwareUpdate.update(from: release(tag: "v0.3.0", asset: "Other.zip"), current: current) == nil)
        #expect(try SoftwareUpdate.update(from: release(tag: "v0.3.0", prerelease: true), current: current) == nil)
    }
}
