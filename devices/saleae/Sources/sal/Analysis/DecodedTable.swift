import Foundation

/// One row of a Logic 2 analyzer data table. Empty cells are left out of `fields`.
struct DecodedRow: Encodable, Equatable, Sendable {
    var type: String
    var start: Double
    var duration: Double
    var fields: [String: String]
}

enum DecodedTableError: Error, Equatable {
    case truncated
    case unterminatedQuote
    case strayQuote(record: Int)
    case invalidHeader
    case wrongFieldCount(record: Int, expected: Int, found: Int)
    case invalidTime(record: Int)
}

private let leadingColumns = ["name", "type", "start_time", "duration"]

/// Parses the CSV Logic 2 writes. Quoted cells may hold commas, quotes and newlines,
/// because ASCII radix emits decoded control characters literally.
func parseCSV(_ bytes: Data) throws -> [[String]] {
    let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), newline = UInt8(ascii: "\n")
    let carriageReturn = UInt8(ascii: "\r")

    var records: [[String]] = []
    var record: [String] = []
    var field: [UInt8] = []
    var inQuotes = false
    var afterQuote = false

    func text() -> String { String(decoding: field, as: UTF8.self) }

    var index = bytes.startIndex
    while index < bytes.endIndex {
        let byte = bytes[index]
        let next = bytes.index(after: index)
        index = next

        if inQuotes {
            if byte != quote {
                field.append(byte)
            } else if next < bytes.endIndex, bytes[next] == quote {
                field.append(quote)
                index = bytes.index(after: next)
            } else {
                inQuotes = false
                afterQuote = true
            }
            continue
        }

        switch byte {
        case quote:
            guard field.isEmpty, !afterQuote else { throw DecodedTableError.strayQuote(record: records.count) }
            inQuotes = true
        case comma:
            record.append(text())
            field.removeAll(keepingCapacity: true)
            afterQuote = false
        case carriageReturn where next < bytes.endIndex && bytes[next] == newline:
            break
        case newline:
            record.append(text())
            records.append(record)
            record.removeAll(keepingCapacity: true)
            field.removeAll(keepingCapacity: true)
            afterQuote = false
        default:
            guard !afterQuote else { throw DecodedTableError.strayQuote(record: records.count) }
            field.append(byte)
        }
    }

    guard !inQuotes else { throw DecodedTableError.unterminatedQuote }
    // Logic 2 ends every record with a newline, so anything else was cut short.
    guard record.isEmpty, field.isEmpty, !afterQuote else { throw DecodedTableError.truncated }
    return records
}

/// Validates the table shape and converts its records. Columns after the leading four
/// vary by analyzer and by content, so they are kept by name.
func decodedRows(fromCSV bytes: Data) throws -> [DecodedRow] {
    let records = try parseCSV(bytes)
    guard let header = records.first, header.starts(with: leadingColumns),
        Set(header).count == header.count
    else {
        throw DecodedTableError.invalidHeader
    }

    return try records.indices.dropFirst().map { position in
        let record = records[position]
        guard record.count == header.count else {
            throw DecodedTableError.wrongFieldCount(record: position, expected: header.count, found: record.count)
        }
        guard let start = Double(record[2]), start.isFinite,
            let duration = Double(record[3]), duration.isFinite, duration >= 0
        else {
            throw DecodedTableError.invalidTime(record: position)
        }

        var fields: [String: String] = [:]
        for column in leadingColumns.count..<header.count where !record[column].isEmpty {
            fields[header[column]] = record[column]
        }
        return DecodedRow(type: record[1], start: start, duration: duration, fields: fields)
    }
}

/// Counts protocol faults across all rows, so paging cannot hide one. A NACK on the last
/// byte of an I2C read is how a controller ends the read, so it does not count.
func decodeIssues(_ rows: [DecodedRow]) -> [String: Int] {
    var issues: [String: Int] = [:]
    var reading = false
    for row in rows {
        if let error = row.fields["error"] { issues[error, default: 0] += 1 }
        if row.type == "address", let read = row.fields["read"] { reading = read == "true" }
        if row.fields["ack"] == "false", row.type == "address" || !reading {
            issues["nack", default: 0] += 1
        }
    }
    return issues
}

struct DecodePage: Encodable, Equatable, Sendable {
    var totalRows: Int
    var offset: Int
    var issues: [String: Int]
    var rows: [DecodedRow]
}

func decodePage(_ rows: [DecodedRow], offset: Int, limit: Int) -> DecodePage {
    DecodePage(
        totalRows: rows.count, offset: offset, issues: decodeIssues(rows),
        rows: Array(rows.dropFirst(offset).prefix(limit)))
}
