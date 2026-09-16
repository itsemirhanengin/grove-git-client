/// What a single line in a unified diff represents.
///
/// Stored in 3 bits, so there is room for one more case before the packing in
/// ``DiffLine`` has to change.
public enum DiffLineKind: UInt32, Sendable, CaseIterable {
    /// An unchanged line, present on both sides.
    case context = 0
    /// A `+` line — present only on the new side.
    case addition = 1
    /// A `-` line — present only on the old side.
    case deletion = 2
    /// A `diff --git` / `index` / `---` / `+++` / mode / rename header line.
    case meta = 3
    /// The literal `\ No newline at end of file` marker line.
    case noNewlineMarker = 4
    /// A `Binary files a/x and b/y differ` line, or a binary patch body.
    case binary = 5
    /// A conflict marker line (`<<<<<<<`, `|||||||`, `=======`, `>>>>>>>`).
    case conflictMarker = 6
}

/// One line of a parsed diff, as a 16-byte POD value.
///
/// `DiffLine` holds **offsets into a shared byte buffer**, never a `String`. That
/// is the whole point: 50k lines cost one 800 KB `ContiguousArray` with perfect
/// locality instead of 50k heap allocations, and nothing is decoded until a line
/// is actually drawn.
///
/// Layout of `packed`:
///
/// ```text
///  31  30  29 │ 28  │ 27   │ 26         │ 25    │ 24 ............ 0
///  └─ kind ─┘ │ CR  │ !ASCII│ noNewline │ hasTab│ └──── length ────┘
/// ```
///
/// `length` therefore tops out at 33,554,431 bytes for a single line, which is
/// far beyond anything git will hand us on one line.
public struct DiffLine: Sendable, Equatable {

    // MARK: Bit layout

    @usableFromInline static let lengthMask: UInt32 = 0x01FF_FFFF
    @usableFromInline static let hasTabBit: UInt32 = 1 << 25
    @usableFromInline static let noNewlineAfterBit: UInt32 = 1 << 26
    @usableFromInline static let nonASCIIBit: UInt32 = 1 << 27
    @usableFromInline static let hasCRBit: UInt32 = 1 << 28
    @usableFromInline static let kindShift: UInt32 = 29

    /// Largest line length representable in the packed field.
    public static let maxLength: UInt32 = lengthMask

    // MARK: Storage

    /// Byte offset of the line's **content** within the owning buffer — that is,
    /// after the leading `+`, `-` or space marker, and after any combined-diff
    /// columns.
    public var start: UInt32

    @usableFromInline var packed: UInt32

    /// 1-based line number on the old side, or `-1` when the line does not exist there.
    public var oldNumber: Int32

    /// 1-based line number on the new side, or `-1` when the line does not exist there.
    public var newNumber: Int32

    // MARK: Derived

    /// Byte length of the content, excluding the trailing newline and excluding a
    /// trailing `\r` (which stays in the buffer — see ``hasCR``).
    @inlinable public var length: UInt32 {
        get { packed & Self.lengthMask }
        set { packed = (packed & ~Self.lengthMask) | (newValue & Self.lengthMask) }
    }

    @inlinable public var kind: DiffLineKind {
        get { DiffLineKind(rawValue: packed >> Self.kindShift) ?? .context }
        set { packed = (packed & ~(0b111 << Self.kindShift)) | (newValue.rawValue << Self.kindShift) }
    }

    /// The original line ended `\r\n`. The `\r` is excluded from ``length`` but is
    /// still present in the buffer, and **must** be re-emitted when synthesising a
    /// patch or `git apply` will reject it.
    @inlinable public var hasCR: Bool {
        get { packed & Self.hasCRBit != 0 }
        set { setFlag(Self.hasCRBit, newValue) }
    }

    /// The line contains a byte >= 0x80, so it needs the Core Text path rather
    /// than the ASCII glyph fast path.
    @inlinable public var nonASCII: Bool {
        get { packed & Self.nonASCIIBit != 0 }
        set { setFlag(Self.nonASCIIBit, newValue) }
    }

    /// A `\ No newline at end of file` marker followed this line.
    ///
    /// Line-level staging treats such a line as non-splittable: turning a `-` that
    /// owns this marker into context would assert that *both* sides lack the
    /// trailing newline, which is usually false and yields a corrupt patch.
    @inlinable public var noNewlineAfter: Bool {
        get { packed & Self.noNewlineAfterBit != 0 }
        set { setFlag(Self.noNewlineAfterBit, newValue) }
    }

    /// The line contains a tab, so column arithmetic must expand tab stops.
    @inlinable public var hasTab: Bool {
        get { packed & Self.hasTabBit != 0 }
        set { setFlag(Self.hasTabBit, newValue) }
    }

    @inlinable mutating func setFlag(_ bit: UInt32, _ on: Bool) {
        if on { packed |= bit } else { packed &= ~bit }
    }

    /// `true` when the line can be drawn by the ASCII glyph fast path.
    @inlinable public var isFastPathEligible: Bool { !nonASCII }

    // MARK: Init

    @inlinable
    public init(
        start: UInt32,
        length: UInt32,
        kind: DiffLineKind,
        oldNumber: Int32 = -1,
        newNumber: Int32 = -1,
        hasCR: Bool = false,
        nonASCII: Bool = false,
        noNewlineAfter: Bool = false,
        hasTab: Bool = false
    ) {
        self.start = start
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.packed =
            (length & Self.lengthMask)
            | (kind.rawValue << Self.kindShift)
            | (hasCR ? Self.hasCRBit : 0)
            | (nonASCII ? Self.nonASCIIBit : 0)
            | (noNewlineAfter ? Self.noNewlineAfterBit : 0)
            | (hasTab ? Self.hasTabBit : 0)
    }
}
