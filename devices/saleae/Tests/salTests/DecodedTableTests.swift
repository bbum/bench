import Foundation
import Testing
@testable import sal

private let fixtures = ["uart-framing", "uart-parity", "uart-ascii", "uart-mdb", "i2c-nack", "spi"]

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureDirectory.deletingLastPathComponent()
        .appendingPathComponent("decode/\(name).csv"))
}

private func table(_ text: String) -> Data { Data(text.utf8) }
private let header = "name,type,start_time,duration,\"data\"\n"

/// Written separately from the parser, so the two have to agree.
private func writeCSV(_ records: [[String]], quoteAll: Bool, crlf: Bool) -> Data {
    let lines = records.map { record in
        record.map { cell -> String in
            guard quoteAll || cell.utf8.contains(where: { "\",\n\r".utf8.contains($0) }) else { return cell }
            return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",")
    }
    let end = crlf ? "\r\n" : "\n"
    return Data(lines.map { $0 + end }.joined().utf8)
}

@Suite("Decoded table")
struct DecodedTableTests {
    @Test("Every recorded table parses", arguments: fixtures)
    func recorded(name: String) throws {
        #expect(try !decodedRows(fromCSV: fixture(name)).isEmpty)
    }

    @Test("Recorded faults are read and counted")
    func recordedFaults() throws {
        let framing = try decodedRows(fromCSV: fixture("uart-framing"))
        #expect(framing[1] == DecodedRow(
            type: "data", start: 0.0163621, duration: 0.00008246, fields: ["error": "framing", "data": "0x42"]))
        #expect(framing[0].fields == ["data": "0x41"])
        #expect(decodeIssues(framing) == ["framing": framing.count { $0.fields["data"] == "0x42" }])

        let parity = try decodedRows(fromCSV: fixture("uart-parity"))
        #expect(decodeIssues(parity) == ["parity": parity.count { $0.fields["data"] == "0x45" }])

        let nacks = try decodedRows(fromCSV: fixture("i2c-nack"))
        #expect(decodeIssues(nacks) == ["nack": nacks.count { $0.fields["ack"] == "false" }])
    }

    @Test("A newline decoded in ASCII radix stays inside its cell")
    func embeddedNewline() throws {
        let rows = try decodedRows(fromCSV: fixture("uart-ascii"))
        #expect(rows.contains { $0.fields["data"] == "\n" })
    }

    @Test("Doubled quotes, commas and CRLF are handled")
    func quoting() throws {
        let parsed = try parseCSV(table("a,\"b\"\"c\",\"d,e\"\r\n\"\",f\r\n"))
        #expect(parsed == [["a", "b\"c", "d,e"], ["", "f"]])
    }

    @Test("A carriage return not before a newline is data")
    func bareCarriageReturn() throws {
        #expect(try parseCSV(table("a\rb\n")) == [["a\rb"]])
    }

    @Test("Blank cells are left out and a header-only table has no rows")
    func emptyCells() throws {
        #expect(try decodedRows(fromCSV: table(header)).isEmpty)
        let rows = try decodedRows(fromCSV: table(header + "a,data,1,0,\n"))
        #expect(rows[0].fields.isEmpty)
    }

    @Test("Negative start times are kept, for captures with a trigger")
    func negativeStart() throws {
        #expect(try decodedRows(fromCSV: table(header + "a,data,-1.5,0,x\n"))[0].start == -1.5)
    }

    @Test("Zero duration is the boundary of what is valid")
    func durationBoundary() throws {
        #expect(try decodedRows(fromCSV: table(header + "a,data,1,0,x\n"))[0].duration == 0)
        #expect(throws: DecodedTableError.invalidTime(record: 1)) {
            try decodedRows(fromCSV: table(header + "a,data,1,-0.1,x\n"))
        }
    }

    @Test("Malformed tables are rejected with the right error", arguments: [
        ("", DecodedTableError.invalidHeader),
        ("x\n", .invalidHeader),
        ("name,type,start_time\n", .invalidHeader),
        ("type,name,start_time,duration\n", .invalidHeader),
        ("name,type,start_time,duration,a,a\n", .invalidHeader),
        ("name,type,start_time,duration", .truncated),
        (header + "a,data,1,0,x", .truncated),
        (header + "a,data,1,0,\"x\"", .truncated),
        (header + "a,data,1,0,\"x\n", .unterminatedQuote),
        (header + "a,data,1,0,\"x\"y\n", .strayQuote(record: 1)),
        (header + "a,data,1,0,x\"\n", .strayQuote(record: 1)),
        (header + "a,data,1,0\n", .wrongFieldCount(record: 1, expected: 5, found: 4)),
        (header + "a,data,1,0,x,y\n", .wrongFieldCount(record: 1, expected: 5, found: 6)),
        (header + "a,data,oops,0,x\n", .invalidTime(record: 1)),
        (header + "a,data,1,oops,x\n", .invalidTime(record: 1)),
        (header + "a,data,nan,0,x\n", .invalidTime(record: 1)),
        (header + "a,data,1,inf,x\n", .invalidTime(record: 1)),
    ] as [(String, DecodedTableError)])
    func malformed(text: String, expected: DecodedTableError) {
        #expect(throws: expected) { try decodedRows(fromCSV: table(text)) }
    }

    @Test("Every truncation is rejected or yields only whole records", arguments: fixtures)
    func truncations(name: String) throws {
        let bytes = try fixture(name)
        let total = try decodedRows(fromCSV: bytes).count
        for length in 0..<bytes.count {
            let prefix = bytes.prefix(length)
            guard let rows = try? decodedRows(fromCSV: prefix) else { continue }
            #expect(rows.count <= total)
            #expect(prefix.last == UInt8(ascii: "\n"), "length \(length)")
        }
    }

    @Test("Hostile bytes at every position never trap", arguments: fixtures)
    func hostileBytes(name: String) throws {
        let bytes = try fixture(name)
        let hostile = [UInt8(ascii: "\""), UInt8(ascii: ","), UInt8(ascii: "\n"), 0, 0xFF]
        for position in bytes.indices {
            for value in hostile {
                var mutated = bytes
                mutated[position] = value
                _ = try? decodedRows(fromCSV: mutated)
            }
        }
    }

    @Test("Seeded random corruption never traps")
    func randomCorruption() throws {
        let bytes = try fixture("i2c-nack")
        var generator = SplitMix64(state: 0x5A1)
        for _ in 0..<5_000 {
            var mutated = bytes
            for _ in 0..<Int.random(in: 1...16, using: &generator) {
                mutated[Int.random(in: mutated.indices, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = try? decodedRows(fromCSV: mutated)
        }
    }

    @Test("An independently written table reads back exactly")
    func oracle() throws {
        let alphabet = Array("ab,\"\n\r 0x")
        var generator = SplitMix64(state: 0xC5F)
        for iteration in 0..<3_000 {
            let columns = Int.random(in: 1...6, using: &generator)
            let records = (0..<Int.random(in: 1...8, using: &generator)).map { _ in
                (0..<columns).map { _ in
                    String((0..<Int.random(in: 0...6, using: &generator)).map { _ in
                        alphabet.randomElement(using: &generator)!
                    })
                }
            }
            let bytes = writeCSV(records, quoteAll: iteration.isMultiple(of: 2), crlf: iteration.isMultiple(of: 3))
            #expect(try parseCSV(bytes) == records)
        }
    }
}

@Suite("Decode issues and paging")
struct DecodePagingTests {
    private func row(_ type: String, _ fields: [String: String]) -> DecodedRow {
        DecodedRow(type: type, start: 0, duration: 0, fields: fields)
    }

    @Test("The NACK ending a read is normal, and every other NACK counts")
    func nacks() {
        let readEnd = [row("address", ["read": "true", "ack": "true"]), row("data", ["ack": "false"])]
        #expect(decodeIssues(readEnd).isEmpty)

        let write = [row("address", ["read": "false", "ack": "true"]), row("data", ["ack": "false"])]
        #expect(decodeIssues(write) == ["nack": 1])

        let unanswered = [row("address", ["read": "true", "ack": "false"])]
        #expect(decodeIssues(unanswered) == ["nack": 1])

        #expect(decodeIssues(readEnd + write) == ["nack": 1])
    }

    private let rows = (0..<5).map { DecodedRow(type: "t\($0)", start: 0, duration: 0, fields: $0 == 4 ? ["error": "framing"] : [:]) }

    @Test("Pages slice the rows, and issues cover rows outside the page")
    func paging() {
        let page = decodePage(rows, offset: 1, limit: 2)
        #expect(page.rows.map(\.type) == ["t1", "t2"])
        #expect(page.totalRows == 5)
        #expect(page.offset == 1)
        #expect(page.issues == ["framing": 1])
    }

    @Test("Paging at and past the ends is safe", arguments: [
        (0, 5, 5), (0, 6, 5), (4, 1, 1), (5, 1, 0), (6, 1, 0), (Int.max, Int.max, 0), (0, Int.max, 5),
    ])
    func boundaries(offset: Int, limit: Int, expected: Int) {
        #expect(decodePage(rows, offset: offset, limit: limit).rows.count == expected)
    }

    @Test("The footer reports position and issues")
    func footer() {
        #expect(pageFooter(decodePage(rows, offset: 1, limit: 2)) == "Rows 2-3 of 5, issues: framing: 1")
        #expect(pageFooter(decodePage(Array(rows.prefix(2)), offset: 0, limit: 9)) == "Rows 1-2 of 2, no issues")
        #expect(pageFooter(decodePage(rows, offset: 9, limit: 2)) == "No rows shown of 5, issues: framing: 1")
    }

    @Test("A row prints time, type, then sorted fields with escapes visible")
    func describeRow() {
        let row = DecodedRow(type: "data", start: 0.5, duration: 0, fields: ["z": "\n", "a": "1"])
        #expect(describe(row) == #"0.50000000  data  a="1"  z="\n""#)
    }
}
