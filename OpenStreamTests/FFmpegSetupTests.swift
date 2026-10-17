import XCTest
@testable import OpenStream

final class FFmpegSetupTests: XCTestCase {
    func testStatusDoesNotCrash() {
        switch FFmpegSetup.status() {
        case .readyBundled(let path), .readySystem(let path):
            XCTAssertFalse(path.isEmpty)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
        case .missingFFmpeg:
            // Secours brew possible, ou fetch script à lancer.
            break
        case .missingHomebrew:
            XCTAssertNil(FFmpegSetup.brewURL)
        }
    }

    func testBundledBinaryPreferredWhenPresent() throws {
        // Après fetch + build, le TEST_HOST doit exposer Helpers.
        guard let bundled = FFmpegWrapper.bundledBinaryURL(named: "ffmpeg") else {
            throw XCTSkip("Helpers absents — lance ./scripts/fetch-bundled-ffmpeg.sh && rebuild")
        }
        let resolved = try XCTUnwrap(FFmpegWrapper.resolveBinary(named: "ffmpeg"))
        XCTAssertEqual(resolved.standardizedFileURL, bundled.standardizedFileURL)
        XCTAssertTrue(FFmpegWrapper.isUsingBundledBinary())
    }
}
