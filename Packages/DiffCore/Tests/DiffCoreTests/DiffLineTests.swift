import Testing

@testable import DiffCore

@Suite("DiffLine bit packing")
struct DiffLineTests {

    @Test("stays 16 bytes — the whole reason for the packing")
    func size() {
        #expect(MemoryLayout<DiffLine>.size == 16)
        #expect(MemoryLayout<DiffLine>.stride == 16)
    }

    @Test("round-trips every field")
    func roundTrip() {
        let line = DiffLine(
            start: 1_234_567,
            length: 4096,
            kind: .deletion,
            oldNumber: 42,
            newNumber: -1,
            hasCR: true,
            nonASCII: true,
            noNewlineAfter: true,
            hasTab: true
        )

        #expect(line.start == 1_234_567)
        #expect(line.length == 4096)
        #expect(line.kind == .deletion)
        #expect(line.oldNumber == 42)
        #expect(line.newNumber == -1)
        #expect(line.hasCR)
        #expect(line.nonASCII)
        #expect(line.noNewlineAfter)
        #expect(line.hasTab)
        #expect(!line.isFastPathEligible)
    }

    @Test("flags default to false and do not bleed into length")
    func defaults() {
        let line = DiffLine(start: 0, length: DiffLine.maxLength, kind: .context)

        #expect(line.length == DiffLine.maxLength)
        #expect(line.kind == .context)
        #expect(!line.hasCR)
        #expect(!line.nonASCII)
        #expect(!line.noNewlineAfter)
        #expect(!line.hasTab)
        #expect(line.isFastPathEligible)
    }

    @Test("every kind survives packing at maximum length", arguments: DiffLineKind.allCases)
    func kindsAreIndependentOfLength(kind: DiffLineKind) {
        var line = DiffLine(start: 0, length: DiffLine.maxLength, kind: kind)
        #expect(line.kind == kind)
        #expect(line.length == DiffLine.maxLength)

        // Toggling a flag must not disturb kind or length.
        line.hasCR = true
        #expect(line.kind == kind)
        #expect(line.length == DiffLine.maxLength)
    }

    @Test("mutating length leaves kind and flags intact")
    func mutateLength() {
        var line = DiffLine(start: 0, length: 10, kind: .addition, hasTab: true)
        line.length = 99
        #expect(line.length == 99)
        #expect(line.kind == .addition)
        #expect(line.hasTab)
    }

    @Test("clearing a flag leaves the others alone")
    func clearFlag() {
        var line = DiffLine(
            start: 0, length: 8, kind: .meta,
            hasCR: true, nonASCII: true, noNewlineAfter: true, hasTab: true
        )
        line.nonASCII = false

        #expect(!line.nonASCII)
        #expect(line.hasCR)
        #expect(line.noNewlineAfter)
        #expect(line.hasTab)
        #expect(line.kind == .meta)
        #expect(line.length == 8)
        #expect(line.isFastPathEligible)
    }
}
