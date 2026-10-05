import Foundation
import XCTest
@testable import PackMeasure

final class DiagnosticReportTests: XCTestCase {
    private let reportID = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
    private var createdAt: Date {
        ISO8601DateFormatter().date(from: "2026-10-05T13:14:15Z")!
    }

    func testAttachmentCarriesDeterministicIdentityAndMetadata() {
        let report = snapshot(kind: .room, payload: "wall_count=4\n")
        let attachment = report.attachmentText(note: "The front wall is missing.")
        for marker in [
            "Report ID: \(reportID.uuidString)", "Created (UTC): 2026-10-05T13:14:15.000Z",
            "Context: Room scan", "App version: 0.2.0", "Build: 64",
            "Device: iPhone fixture", "System version: iOS fixture",
            "User note:\nThe front wall is missing."
        ] {
            XCTAssertTrue(attachment.contains(marker), marker)
        }
        XCTAssertEqual(report.id, reportID)
        XCTAssertEqual(report.createdAt, createdAt)
        XCTAssertEqual(String(data: report.attachmentData(note: "The front wall is missing."), encoding: .utf8), attachment)
        XCTAssertTrue(attachment.hasSuffix("wall_count=4\n"))
    }

    func testLargeJSONAndUnicodePayloadRemainVerbatimBeyondURLLimits() throws {
        let value = String(repeating: "📦 edge\\n雪\\\"", count: 20_000)
        let json = "{\"scan\":\"\(value)\",\"counts\":[1,2,3]}\r\n"
        let report = snapshot(kind: .interior, payload: json)
        XCTAssertGreaterThan(report.payloadData.count, 200_000)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: report.payloadData))
        let attachment = report.attachmentText(note: "Keep the full diagnostics.")
        XCTAssertTrue(attachment.hasSuffix(json))
        let suffix = try XCTUnwrap(attachment.range(of: "----- BEGIN ORIGINAL DIAGNOSTICS -----\n"))
        XCTAssertEqual(String(attachment[suffix.upperBound...]), json)
        XCTAssertEqual(report.payloadData, Data(json.utf8))
        XCTAssertEqual(String(data: report.attachmentData(note: "Keep the full diagnostics."), encoding: .utf8), attachment)
    }

    func testNotesStaySeparateAndDoNotMutateTheSnapshot() {
        let raw = "{\"raw\":\"unchanged\"}\n"
        let report = snapshot(kind: .object, payload: raw)
        let first = report.attachmentText(note: "First note\nwith another line.")
        let second = report.attachmentText(note: "A different note.")
        XCTAssertTrue(first.contains("User note:\nFirst note\nwith another line."))
        XCTAssertTrue(second.contains("User note:\nA different note."))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasSuffix(raw))
        XCTAssertTrue(second.hasSuffix(raw))
        XCTAssertEqual(report.payload, raw)
        XCTAssertEqual(report.id, reportID)
        XCTAssertEqual(report.createdAt, createdAt)
    }

    func testEveryContextHasDistinctSafeFilenamesAndUsefulEmailCopy() {
        var identifiers = Set<UUID>()
        var filenames = Set<String>()
        for kind in DiagnosticReport.Kind.allCases {
            let report = DiagnosticReport(kind: kind, payload: "raw", appVersion: "0.2.0", build: "64")
            identifiers.insert(report.id)
            filenames.insert(report.filename)
            XCTAssertTrue(report.filename.hasSuffix("-diagnostic.txt"))
            XCTAssertNotNil(report.filename.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression))
            XCTAssertFalse(report.filename.contains("/"))
            XCTAssertTrue(report.emailSubject.contains(report.id.uuidString))
            XCTAssertTrue(report.emailSubject.contains("build 64"))
            XCTAssertTrue(report.emailSubject.contains(kind.title))
            let body = report.emailBody(note: "Please inspect the outline.")
            XCTAssertTrue(body.contains("attached text file"))
            XCTAssertTrue(body.contains(report.id.uuidString))
            XCTAssertTrue(body.contains(report.filename))
            XCTAssertTrue(body.contains("User note:\nPlease inspect the outline."))
        }
        XCTAssertEqual(identifiers.count, DiagnosticReport.Kind.allCases.count)
        XCTAssertEqual(filenames.count, DiagnosticReport.Kind.allCases.count)
        let first = DiagnosticReport(kind: .room, payload: "same raw capture")
        let second = DiagnosticReport(kind: .room, payload: "same raw capture")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.filename, second.filename)
        XCTAssertEqual(SupportContact.email, "hugginsc10@gmail.com")
    }

    func testAppReportWithoutCapturePayloadDoesNotInventScanEvidence() {
        let report = snapshot(kind: .app, payload: "")
        let attachment = report.attachmentText()
        XCTAssertTrue(attachment.contains("Context: App"))
        XCTAssertTrue(attachment.contains("No active scan diagnostics were provided."))
        XCTAssertTrue(attachment.contains("No note provided."))
        XCTAssertFalse(attachment.contains("Original diagnostics are included verbatim below."))
        XCTAssertEqual(report.payload, "")
        XCTAssertTrue(report.payloadData.isEmpty)
        XCTAssertTrue(report.emailBody().contains("Context: App"))
        XCTAssertTrue(report.emailBody().contains("No active scan diagnostics were provided."))
    }

    private func snapshot(kind: DiagnosticReport.Kind, payload: String) -> DiagnosticReport {
        DiagnosticReport(kind: kind, payload: payload, id: reportID, createdAt: createdAt,
                         appVersion: "0.2.0", build: "64", deviceModel: "iPhone fixture", systemVersion: "iOS fixture")
    }
}
