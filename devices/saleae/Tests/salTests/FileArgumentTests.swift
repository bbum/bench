import Foundation
import Testing
@testable import sal

@Suite("File options")
struct FileOptionTests {
    private func capture(_ arguments: [String]) throws -> CaptureCommand {
        try #require(try Sal.parseAsRoot(["capture"] + arguments) as? CaptureCommand)
    }

    private func uart(_ arguments: [String]) throws -> UARTCommand {
        try #require(try Sal.parseAsRoot(["decode", "uart", "--channel", "2", "--baud", "9600"] + arguments) as? UARTCommand)
    }

    @Test("Relative paths become absolute, since Logic 2 has its own working directory")
    func absolute() {
        let here = FileManager.default.currentDirectoryPath
        #expect(absolutePath("a/b.sal") == URL(fileURLWithPath: here).appendingPathComponent("a/b.sal").standardizedFileURL.path)
        #expect(absolutePath("/x/../y.sal") == "/y.sal")
    }

    @Test("Channels default to 0-7, or everything when loading")
    func channels() throws {
        #expect(try resolvedChannels(nil, loading: false) == Array(0...7))
        #expect(try resolvedChannels(nil, loading: true).isEmpty)
        #expect(try resolvedChannels("none", loading: false).isEmpty)
        #expect(try resolvedChannels("1,3", loading: true) == [1, 3])
        #expect(throws: (any Error).self) { try resolvedChannels("x", loading: true) }
    }

    @Test("--load makes a load request with an absolute path")
    func load() throws {
        let built = try capture(["--load", "/a/b.sal"]).capture.request(channels: [], stop: CaptureCancellation())
        guard case .load(let path) = built.mode else {
            Issue.record("not a load")
            return
        }
        #expect(path == "/a/b.sal")
        #expect(built.exportsEverything)
    }

    @Test("Named channels stop a load from exporting everything")
    func loadNamed() throws {
        let built = try capture(["--load", "/a.sal"]).capture.request(channels: [1], stop: CaptureCancellation())
        #expect(!built.exportsEverything)
    }

    @Test("A timed capture never exports everything")
    func timed() throws {
        #expect(try !capture([]).capture.request(channels: [], stop: CaptureCancellation()).exportsEverything)
    }

    @Test("--save reaches the request")
    func save() throws {
        let built = try capture(["--save", "/a/out.sal"]).capture.request(channels: [0], stop: CaptureCancellation())
        #expect(built.savePath == "/a/out.sal")
    }

    @Test("Loading refuses capture settings", arguments: [
        ["--rate", "50M"], ["--duration", "1"], ["--device", "x"], ["--manual"], ["--trim", "1"], ["--buffer-mb", "8"],
        ["--glitch", "0:1us"], ["--trigger", "1:rising"],
    ])
    func loadConflicts(arguments: [String]) {
        #expect(throws: (any Error).self) { try capture(["--load", "/a.sal"] + arguments) }
    }

    @Test("Loading accepts what does not capture", arguments: [["--save", "/b.sal"], ["--channels", "0"]])
    func loadAllowed(arguments: [String]) {
        #expect(throws: Never.self) { try capture(["--load", "/a.sal"] + arguments) }
    }

    @Test("--iso8601 on capture needs a CSV export")
    func captureISO() {
        #expect(throws: (any Error).self) { try capture(["--iso8601"]) }
        #expect(throws: Never.self) { try capture(["--iso8601", "--export-csv", "/d"]) }
    }

    @Test("Table export options reach the request")
    func table() throws {
        let export = try uart([
            "--export-table", "/t.csv", "--iso8601", "--columns", "a,b", "--filter", "0x41", "--filter-columns", "c,d",
        ]).options.tableExportRequest
        #expect(export == TableExport(path: "/t.csv", iso8601: true, columns: ["a", "b"], filterQuery: "0x41", filterColumns: ["c", "d"]))
    }

    @Test("No table export means no request")
    func noTable() throws {
        #expect(try uart([]).options.tableExportRequest == nil)
        #expect(try uart([]).options.highLevelRequest == nil)
    }

    @Test("High level options reach the request")
    func highLevel() throws {
        let request = try uart(["--hla", "T", "--hla-extension", "/e", "--hla-setting", "a=b", "--hla-setting", "n=2"]).options.highLevelRequest
        #expect(request == HighLevelRequest(
            extensionDirectory: "/e", name: "T",
            settings: [HighLevelSetting(key: "a", value: .text("b")), HighLevelSetting(key: "n", value: .number(2))]))
    }

    @Test("Mismatched file options are refused", arguments: [
        ["--hla", "T"], ["--hla-extension", "/e"], ["--hla-setting", "a=b"], ["--iso8601"], ["--columns", "a"],
        ["--filter", "x"], ["--export-table", "/t", "--filter-columns", "a"],
    ])
    func refused(arguments: [String]) {
        #expect(throws: (any Error).self) { try uart(arguments) }
    }

    @Test("High level settings parse", arguments: [
        ("a=b", HighLevelSetting(key: "a", value: .text("b"))),
        ("a=2", HighLevelSetting(key: "a", value: .number(2))),
        ("a=-1.5", HighLevelSetting(key: "a", value: .number(-1.5))),
        ("a=", HighLevelSetting(key: "a", value: .text(""))),
        ("a=b=c", HighLevelSetting(key: "a", value: .text("b=c"))),
        ("a=inf", HighLevelSetting(key: "a", value: .text("inf"))),
        ("a=nan", HighLevelSetting(key: "a", value: .text("nan"))),
    ])
    func settings(text: String, expected: HighLevelSetting) {
        #expect(HighLevelSetting(argument: text) == expected)
    }

    @Test("Settings without a key are refused", arguments: ["a", "=b", ""])
    func badSettings(text: String) {
        #expect(HighLevelSetting(argument: text) == nil)
    }

    @Test("Settings become the right wire types")
    func wire() {
        #expect(HighLevelSetting(key: "a", value: .text("b")).wireValue.stringValue == "b")
        #expect(HighLevelSetting(key: "a", value: .number(2)).wireValue.numberValue == 2)
    }
}
