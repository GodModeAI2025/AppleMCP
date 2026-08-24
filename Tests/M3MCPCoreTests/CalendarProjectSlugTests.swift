import Foundation
import XCTest

import M3MCPCore

/// The marker is the only part of the project-slug feature that can be tested without a granted
/// Calendar permission, so it is tested thoroughly here: everything downstream assumes that whatever
/// `embed` writes, `extract` reads back unchanged.
final class CalendarProjectSlugTests: XCTestCase {
    // MARK: - Round trip

    func testEmbedThenExtractReturnsTheSameSlug() throws {
        let notes = try XCTUnwrap(CalendarProjectSlug.embed(slug: "agent-platform-mvp", in: nil))
        XCTAssertEqual(CalendarProjectSlug.extract(from: notes), "agent-platform-mvp")
    }

    func testEmbedKeepsTheSuppliedNotesBody() throws {
        let notes = try XCTUnwrap(CalendarProjectSlug.embed(slug: "pa-verify", in: "Agenda:\n- one\n- two"))
        XCTAssertEqual(notes, "Project: pa-verify\n\nAgenda:\n- one\n- two")
        XCTAssertEqual(CalendarProjectSlug.extract(from: notes), "pa-verify")
        XCTAssertEqual(CalendarProjectSlug.remove(from: notes), "Agenda:\n- one\n- two")
    }

    func testEmbedReplacesAnExistingMarkerRatherThanStackingOne() throws {
        let first = try XCTUnwrap(CalendarProjectSlug.embed(slug: "old-slug", in: "Body"))
        let second = try XCTUnwrap(CalendarProjectSlug.embed(slug: "new-slug", in: first))

        XCTAssertEqual(CalendarProjectSlug.extract(from: second), "new-slug")
        XCTAssertEqual(second.components(separatedBy: "Project:").count - 1, 1)
        XCTAssertEqual(CalendarProjectSlug.remove(from: second), "Body")
    }

    func testRemoveReturnsNilWhenOnlyTheMarkerWasThere() throws {
        let notes = try XCTUnwrap(CalendarProjectSlug.embed(slug: "solo", in: nil))
        XCTAssertNil(CalendarProjectSlug.remove(from: notes))
    }

    /// Calendar backends are not consistent about line terminators, so a marker stored with CRLF must
    /// still parse.
    func testExtractHandlesCRLFAndCR() {
        XCTAssertEqual(CalendarProjectSlug.extract(from: "Project: crlf-slug\r\n\r\nBody"), "crlf-slug")
        XCTAssertEqual(CalendarProjectSlug.extract(from: "Project: cr-slug\r\rBody"), "cr-slug")
    }

    func testExtractIsCaseInsensitiveOnTheKeyAndToleratesSpacing() {
        XCTAssertEqual(CalendarProjectSlug.extract(from: "project:   spaced-slug"), "spaced-slug")
        XCTAssertEqual(CalendarProjectSlug.extract(from: "  PROJECT : upper-key"), "upper-key")
    }

    func testExtractFindsAMarkerThatIsNotTheFirstLine() {
        XCTAssertEqual(CalendarProjectSlug.extract(from: "Some prose\nProject: later-slug\nMore"), "later-slug")
    }

    // MARK: - Absence

    func testExtractReturnsNilWithoutAMarker() {
        XCTAssertNil(CalendarProjectSlug.extract(from: nil))
        XCTAssertNil(CalendarProjectSlug.extract(from: ""))
        XCTAssertNil(CalendarProjectSlug.extract(from: "Just some notes about the meeting."))
    }

    /// A colon-bearing line that is not the marker must not be read as one.
    func testExtractIgnoresOtherKeyedLines() {
        XCTAssertNil(CalendarProjectSlug.extract(from: "Projector: booked\nRoom: 3"))
        XCTAssertNil(CalendarProjectSlug.extract(from: "Notes: Project: not-at-line-start"))
    }

    // MARK: - Validation

    func testValidSlugs() {
        for slug in ["a", "0", "pa", "agent-platform-mvp", "psg_way.of.working", "q3-2026", String(repeating: "a", count: 64)] {
            XCTAssertTrue(CalendarProjectSlug.isValid(slug), "expected '\(slug)' to be valid")
        }
    }

    func testInvalidSlugs() {
        let cases = [
            "": "empty",
            "Agent-Platform": "uppercase",
            "-leading-dash": "does not start alphanumeric",
            "_leading-underscore": "does not start alphanumeric",
            "has space": "whitespace",
            "has:colon": "colon would make the marker line ambiguous",
            "two\nlines": "newline would inject a second marker",
            "trailing\r": "carriage return",
            "ümlaut": "non-ASCII"
        ]
        for (slug, why) in cases {
            XCTAssertFalse(CalendarProjectSlug.isValid(slug), "expected '\(slug)' to be rejected: \(why)")
        }
        XCTAssertFalse(CalendarProjectSlug.isValid(String(repeating: "a", count: 65)), "expected 65 characters to be rejected")
    }

    /// The injection case, spelled out: a slug carrying a newline must not be writable, because it
    /// would let a caller plant a second marker that `extract` might return instead.
    func testEmbedRefusesAnInvalidSlugInsteadOfWritingIt() {
        XCTAssertNil(CalendarProjectSlug.embed(slug: "bad\nProject: injected", in: "Body"))
        // "HasUppercase" rather than "Has Uppercase": the space alone would reject it, so the space
        // version could not detect an implementation that allowed uppercase.
        XCTAssertNil(CalendarProjectSlug.embed(slug: "HasUppercase", in: nil))
        XCTAssertNil(CalendarProjectSlug.embed(slug: "has space", in: nil))
        XCTAssertNil(CalendarProjectSlug.embed(slug: "-leading", in: nil))
        XCTAssertNil(CalendarProjectSlug.embed(slug: "has:colon", in: nil))
        XCTAssertNil(CalendarProjectSlug.embed(slug: "", in: "Body"))
    }

    /// A marker line whose value is not a valid slug is not a slug. Returning the raw text would
    /// label an event with something no writer could have produced.
    func testExtractRejectsAnInvalidValueOnTheMarkerLine() {
        XCTAssertNil(CalendarProjectSlug.extract(from: "Project: Not A Slug"))
        XCTAssertNil(CalendarProjectSlug.extract(from: "Project:"))
        XCTAssertEqual(
            CalendarProjectSlug.extract(from: "Project: Not A Slug\nProject: real-slug"),
            "real-slug",
            "a valid marker later in the notes must still be found"
        )
    }
}
