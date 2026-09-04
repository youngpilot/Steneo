import AVFoundation
import XCTest
@testable import Steneo

/// Keeping the audio of a failed recording is the difference between "it vanished"
/// and "it can be run again". Pruning deletes user data, so its rule is tested
/// rather than trusted.
@MainActor
final class RecoveryStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SteneoRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> RecoveryStore { RecoveryStore(directory: directory) }

    private func tone(seconds: Double, rate: Double = 48_000) -> [Float] {
        let count = Int(seconds * rate)
        return (0..<count).map { sinf(Float($0) * 0.05) * 0.3 }
    }

    // MARK: - Naming round trip

    func testNameCarriesTheDateAndTheReason() throws {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let name = RecoveryStore.fileName(date: date, reason: .asrError)
        let parsed = try XCTUnwrap(RecoveryStore.parse(fileName: name))
        XCTAssertEqual(parsed.reason, .asrError)
        XCTAssertEqual(parsed.date.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1.0)
    }

    func testForeignFilesAreIgnored() {
        for name in ["notes.txt", "recording.wav", "2026-09-04T18-00-00_unknown-reason.wav", ".DS_Store"] {
            XCTAssertNil(RecoveryStore.parse(fileName: name), "\(name) must not be read as a kept recording")
        }
    }

    /// Names are built so that sorting them chronologically is the same as sorting
    /// them alphabetically — pruning depends on it.
    func testNamesSortChronologically() {
        let early = RecoveryStore.fileName(date: Date(timeIntervalSince1970: 1_000_000), reason: .emptyResult)
        let late = RecoveryStore.fileName(date: Date(timeIntervalSince1970: 2_000_000), reason: .emptyResult)
        XCTAssertLessThan(early, late)
    }

    // MARK: - Pruning

    func testPruningKeepsTheNewest() {
        let names = (1...15).map {
            RecoveryStore.fileName(date: Date(timeIntervalSince1970: Double($0) * 3600), reason: .emptyResult)
        }
        let doomed = RecoveryStore.namesToPrune(names.shuffled(), keeping: 10)
        XCTAssertEqual(doomed.count, 5)
        XCTAssertEqual(Set(doomed), Set(names.prefix(5)), "the five oldest go, not five arbitrary ones")
    }

    func testPruningDoesNothingBelowTheLimit() {
        let names = (1...10).map {
            RecoveryStore.fileName(date: Date(timeIntervalSince1970: Double($0)), reason: .emptyResult)
        }
        XCTAssertEqual(RecoveryStore.namesToPrune(names, keeping: 10), [])
    }

    func testPruningNeverTouchesForeignFiles() {
        let mine = (1...12).map {
            RecoveryStore.fileName(date: Date(timeIntervalSince1970: Double($0) * 3600), reason: .emptyResult)
        }
        let doomed = RecoveryStore.namesToPrune(mine + ["important.wav", "notes.txt"], keeping: 10)
        XCTAssertEqual(doomed.count, 2)
        XCTAssertFalse(doomed.contains("important.wav"), "pruning must only ever delete its own files")
        XCTAssertFalse(doomed.contains("notes.txt"))
    }

    // MARK: - Against the disk

    func testAFailedRecordingSurvivesAsAReadableFile() throws {
        let url = try XCTUnwrap(store().save(samples: tone(seconds: 1.0), rate: 48_000, reason: .emptyResult),
                                "an empty result must leave the audio behind")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // Readable by the same machinery "Try again" runs on.
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length), 48_000, accuracy: 100)
    }

    func testNothingIsKeptWhenThereIsNothingToKeep() {
        let s = store()
        XCTAssertNil(s.save(samples: tone(seconds: 1.0), rate: 48_000, reason: .engineStart),
                     "the microphone never came up — there is no audio")
        XCTAssertNil(s.save(samples: [], rate: 48_000, reason: .emptyResult))
        XCTAssertNil(s.save(samples: tone(seconds: 1.0), rate: 0, reason: .emptyResult))
        XCTAssertTrue(s.entries.isEmpty)
    }

    func testTheStoreStaysAtItsLimit() {
        let s = store()
        for i in 0..<(RecoveryStore.keepCount + 4) {
            s.save(samples: tone(seconds: 0.05), rate: 16_000, reason: .emptyResult,
                   date: Date(timeIntervalSince1970: 1_780_000_000 + Double(i) * 60))
        }
        XCTAssertEqual(s.entries.count, RecoveryStore.keepCount)
        XCTAssertEqual(s.entries.first?.date.timeIntervalSince1970,
                       1_780_000_000 + Double(RecoveryStore.keepCount + 3) * 60,
                       "the newest recording must be the one still there")
    }

    func testEntriesComeBackNewestFirstAndCanBeDeleted() {
        let s = store()
        for i in 0..<3 {
            s.save(samples: tone(seconds: 0.05), rate: 16_000, reason: .asrError,
                   date: Date(timeIntervalSince1970: 1_780_000_000 + Double(i) * 60))
        }
        XCTAssertEqual(s.entries.count, 3)
        XCTAssertGreaterThan(s.entries[0].date, s.entries[1].date)

        s.delete(s.entries[0])
        XCTAssertEqual(s.entries.count, 2)
        s.deleteAll()
        XCTAssertTrue(s.entries.isEmpty)
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
}
