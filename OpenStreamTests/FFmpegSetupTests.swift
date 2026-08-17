import XCTest
@testable import OpenStream

final class FFmpegSetupTests: XCTestCase {
    func testStatusDoesNotCrash() {
        switch FFmpegSetup.status() {
        case .ready(let path):
            XCTAssertFalse(path.isEmpty)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
        case .missingFFmpeg:
            XCTAssertNotNil(FFmpegSetup.brewURL)
        case .missingHomebrew:
            XCTAssertNil(FFmpegSetup.brewURL)
        }
    }
}
