import Testing
@testable import ow

@Suite("JSONValue integer conversion")
struct JSONValueIntegerTests {
    @Test("Doubles that fit become integers, truncating any fraction", arguments: [
        (1.0, 1), (1.9, 1), (-1.9, -1), (0.0, 0), (3000.0, 3000),
    ])
    func fits(value: Double, expected: Int) {
        #expect(JSONValue.double(value).intValue == expected)
    }

    @Test("Doubles that cannot be an integer give nil instead of crashing", arguments: [
        1e300, -1e300, Double.infinity, -Double.infinity, Double.nan, 9.3e18, -9.3e18,
    ])
    func outOfRange(value: Double) {
        #expect(JSONValue.double(value).intValue == nil)
    }

    @Test("A huge port falls back to the configured one")
    func hugePort() {
        let config = resolveScope(
            args: ["host": .string("127.0.0.1"), "port": .double(1e300)], default: ScopeConfig(host: "x", port: 1234))
        #expect(config?.port == 1234)
    }
}
