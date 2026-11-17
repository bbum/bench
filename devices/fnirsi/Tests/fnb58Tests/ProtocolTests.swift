import Foundation
import Testing
@testable import fnb58

@Suite struct ProtocolTests {
    /// Checksums the spec gives for the three commands.
    @Test func commandChecksumsMatchTheSpec() {
        #expect(FNB58.command(0x81)[63] == 0x8E)
        #expect(FNB58.command(0x82)[63] == 0x96)
        #expect(FNB58.command(0x83)[63] == 0x9E)
    }

    @Test func commandLayout() {
        let command = FNB58.command(0x83)
        #expect(command.count == 64)
        #expect(command[0] == 0xAA && command[1] == 0x83)
        #expect(command[2..<63].allSatisfy { $0 == 0 })
        #expect(FNB58.startCommands.map { $0[1] } == [0x81, 0x82, 0x82])
        #expect(FNB58.keepalive == FNB58.command(0x83))
    }

    /// An independent bit-at-a-time CRC over the message as a bit stream.
    private func oracleCRC(_ bytes: [UInt8]) -> UInt8 {
        var register: UInt16 = 0x42
        for byte in bytes {
            for bit in (0..<8).reversed() {
                let incoming = UInt16(byte >> bit & 1)
                let top = (register >> 7) & 1
                register = ((register << 1) & 0xFF)
                if top ^ incoming == 1 { register ^= 0x39 }
            }
        }
        return UInt8(register)
    }

    @Test func crcMatchesAnOracleOnRandomInput() {
        var rng = SeededGenerator(seed: 1)
        for length in 0..<80 {
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
            #expect(FNB58.crc8(bytes) == oracleCRC(bytes), "length \(length)")
        }
    }

    /// The first 12 bytes of a real report from this unit: 5.14270 V, 0.00106 A.
    @Test func decodesARealReport() {
        var bytes = [UInt8](repeating: 0, count: 64)
        let head: [UInt8] = [0xAA, 0x04, 0xDE, 0xD8, 0x07, 0x00, 0x6A, 0x00, 0x00, 0x00, 0x4F, 0x00]
        bytes.replaceSubrange(0..<12, with: head)
        guard case .samples(let samples) = Report(bytes) else { Issue.record("not samples"); return }
        #expect(samples.count == 4)
        #expect(samples[0].voltage == 5.1427)
        #expect(samples[0].current == 0.00106)
        #expect(samples[0].dPlus == 0.079)
    }

    @Test func roundTripsFieldsAndOrder() {
        let input = [
            Sample(voltage: 20.12345, current: 5.00001, dPlus: 3.3, dMinus: 0.001, temperature: 41.7, signByte: 1),
            Sample(voltage: 0, current: 0, dPlus: 0, dMinus: 0, temperature: 0, signByte: 0),
            Sample(voltage: 9, current: 3, dPlus: 65.535, dMinus: 65.535, temperature: 6553.5, signByte: 255),
            Sample(voltage: 42949.67295, current: 42949.67295, dPlus: 1, dMinus: 2, temperature: 3, signByte: 7),
        ]
        #expect(Report(dataReport(input)) == .samples(input))
    }

    /// Byte order and offsets, field by field, with a lone 1 bit in each byte.
    @Test func eachByteLandsInItsField() {
        for slot in 0..<4 {
            for offset in 0..<15 {
                var bytes = [UInt8](repeating: 0, count: 64)
                bytes[0] = 0xAA
                bytes[1] = 0x04
                bytes[2 + slot * 15 + offset] = 1
                guard case .samples(let samples) = Report(bytes) else { Issue.record("not samples"); return }
                for (index, s) in samples.enumerated() where index != slot {
                    #expect(s == Sample(voltage: 0, current: 0, dPlus: 0, dMinus: 0, temperature: 0, signByte: 0))
                }
                let s = samples[slot]
                switch offset {
                case 0...3: #expect(s.voltage == Double(1 << (8 * offset)) / 100_000)
                case 4...7: #expect(s.current == Double(1 << (8 * (offset - 4))) / 100_000)
                case 8...9: #expect(s.dPlus == Double(1 << (8 * (offset - 8))) / 1000)
                case 10...11: #expect(s.dMinus == Double(1 << (8 * (offset - 10))) / 1000)
                case 12: #expect(s.signByte == 1)
                // Byte 12 is zero here, so the temperature reads negative.
                default: #expect(s.temperature == -Double(1 << (8 * (offset - 13))) / 10)
                }
            }
        }
    }

    @Test func byteTwelveSignsTheTemperature() {
        for sign in 0...255 {
            var bytes = dataReport([sample(5, 1), sample(5, 1), sample(5, 1), sample(5, 1)])
            bytes[2 + 12] = UInt8(sign)
            guard case .samples(let samples) = Report(bytes) else { Issue.record("not samples"); return }
            #expect(samples[0].temperature == (sign == 0 ? -25.3 : 25.3), "sign byte \(sign)")
            #expect(samples[0].signByte == UInt8(sign))
        }
    }

    @Test func deviceInfoFromThisUnitsReply() throws {
        // The reply this FNB58 sent to 0x81.
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes.replaceSubrange(0..<12, with: [0xAA, 0x03, 0x02, 0x00, 0x00, 0x00, 0x3A, 0x00, 0x76, 0x00, 0xA1, 0xAD])
        let info = try #require(DeviceInfo(bytes))
        #expect(info.model == 58)
        #expect(info.firmware == "1.18")
        #expect(info.hex.hasPrefix("02 00 00 00 3a 00 76 00 a1 ad"))
        var version = bytes
        version[8] = 0x05
        version[9] = 0x01
        #expect(DeviceInfo(version)?.firmware == "2.61")
        bytes[1] = 0x04
        #expect(DeviceInfo(bytes) == nil)
        #expect(DeviceInfo(Array(bytes.prefix(10))) == nil)
        bytes[1] = 0x03
        bytes[0] = 0
        #expect(DeviceInfo(bytes) == nil)
    }

    @Test func everyLengthButSixtyFourIsInvalid() {
        let good = dataReport([sample(5, 1), sample(5, 1), sample(5, 1), sample(5, 1)])
        for length in 0..<200 where length != 64 {
            let bytes = length <= 64 ? Array(good.prefix(length)) : good + [UInt8](repeating: 0, count: length - 64)
            guard case .invalid = Report(bytes) else { Issue.record("length \(length) accepted"); continue }
        }
    }

    @Test func everyHeaderAndTypeByte() {
        var bytes = dataReport([sample(5, 1), sample(5, 1), sample(5, 1), sample(5, 1)])
        for header in 0...255 {
            bytes[0] = UInt8(header)
            if header == 0xAA {
                if case .samples = Report(bytes) {} else { Issue.record("AA rejected") }
            } else if case .invalid = Report(bytes) {} else {
                Issue.record("header \(header) accepted")
            }
        }
        bytes[0] = 0xAA
        for type in 0...255 {
            bytes[1] = UInt8(type)
            switch Report(bytes) {
            case .samples: #expect(type == 0x04)
            case .other(let reported): #expect(reported == UInt8(type) && type != 0x04)
            case .invalid: Issue.record("type \(type) invalid")
            }
        }
    }

    /// A missing or wrong checksum does not stop decoding; raw dumps report it.
    @Test func checksumIsOptional() {
        let samples = [sample(5, 1), sample(5, 2), sample(5, 3), sample(5, 4)]
        var bytes = dataReport(samples, crc: true)
        #expect(Report.checksumMatches(bytes))
        bytes[63] ^= 0xFF
        #expect(!Report.checksumMatches(bytes))
        #expect(Report(bytes) == .samples(samples))
        #expect(!Report.checksumMatches(Array(bytes.prefix(63))))
    }

    @Test func randomBytesNeverTrap() {
        var rng = SeededGenerator(seed: 7)
        for round in 0..<20_000 {
            let length = round % 3 == 0 ? Int.random(in: 0...130, using: &rng) : 64
            var bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if length == 64, round % 2 == 0 { bytes[0] = 0xAA; bytes[1] = 0x04 }
            let report = Report(bytes)
            if case .samples(let samples) = report {
                #expect(samples.count == 4)
                #expect(samples.allSatisfy { $0.voltage.isFinite && $0.current >= 0 && $0.power.isFinite })
            }
            _ = Report.checksumMatches(bytes)
        }
    }

    @Test func chooseMeterRules() throws {
        #expect(throws: MeterError.notFound(serial: nil)) { try chooseMeter([], serial: nil) }
        #expect(throws: MeterError.notFound(serial: "X")) { try chooseMeter(["A"], serial: "X") }
        #expect(throws: MeterError.ambiguous(["A", "B"])) { try chooseMeter(["B", "A"], serial: nil) }
        #expect(try chooseMeter(["A"], serial: nil) == "A")
        #expect(try chooseMeter(["A", "B"], serial: "B") == "B")
    }

    @Test func hexFormatting() {
        #expect(hex([0x00, 0xAA, 0x0F]) == "00 aa 0f")
        #expect(hex([]) == "")
    }
}
