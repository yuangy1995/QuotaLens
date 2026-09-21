import Foundation
import XCTest
@testable import QuotaLens

final class SharedCapacityContractTests: XCTestCase {
    private struct Fixture: Decodable {
        let name: String
        let capacities: [Double]
        let expected: Double?
    }

    func testWindowsAndMacUseTheSamePredictionFixtures() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/capacity-prediction.json"))
        for fixture in try JSONDecoder().decode([Fixture].self, from: data) {
            let actual = CodexCapacityForecast.predict(capacities: fixture.capacities)
            if let expected = fixture.expected {
                XCTAssertEqual(try XCTUnwrap(actual, fixture.name).tokens, expected, accuracy: 0.000001, fixture.name)
            } else {
                XCTAssertNil(actual, fixture.name)
            }
        }
    }
}
