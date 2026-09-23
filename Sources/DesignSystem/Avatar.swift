import SwiftUI

/// A commit author, as initials in a filled circle.
///
/// No network. Grove does not know which host a repository came from, half of
/// them are private, and fetching a picture per row would mean a request per
/// commit for a list that scrolls — so the identity is drawn from what git
/// already recorded.
///
/// The colour is the point. It is derived from the email, so the same person is
/// the same colour in every repository and on every launch, and a history with
/// three contributors in it becomes scannable by colour before any name is
/// read. Two initials carry far less than a photograph; a stable colour carries
/// most of the difference back.
struct Avatar: View {
    let name: String
    let email: String
    var size: CGFloat = 22

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle()
            .fill(Self.tint(for: email, colorScheme: colorScheme))
            .frame(width: size, height: size)
            .overlay {
                Text(Self.initials(name: name, email: email))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    // White rather than `.primary`: the fill is a mid-tone in
                    // both schemes, chosen so one foreground works on all of
                    // them.
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(name.isEmpty ? email : name)
    }

    // MARK: Derivation

    /// Up to two initials, from the name where there is one and from the email
    /// where there is not.
    ///
    /// Grapheme clusters rather than characters, so an emoji or an accented
    /// letter comes back whole. Names in scripts without capitals are left as
    /// they are — uppercasing is a Latin habit and `localizedUppercase` on a CJK
    /// name is a no-op at best.
    static func initials(name: String, email: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace).filter {
            $0.first?.isLetter == true || $0.first?.isNumber == true
        }

        if let first = words.first?.first {
            if words.count > 1, let last = words.last?.first {
                return String([first, last]).localizedUppercase
            }
            return String(first).localizedUppercase
        }

        guard let letter = email.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(letter).localizedUppercase
    }

    /// A stable colour for one identity.
    ///
    /// The hash is written out rather than taken from `hashValue`, which Swift
    /// seeds per process — the same author would be a different colour on every
    /// launch, which is exactly the property this is for.
    static func tint(for email: String, colorScheme: ColorScheme) -> Color {
        let hue = Double(fnv1a(email.lowercased()) % 360) / 360

        // Saturation and brightness are fixed so no hue can come out as a
        // near-black or a highlighter, and both are kept low: this is a row of
        // twenty circles down the side of a list, and at that count a saturated
        // fill stops being an identity and becomes confetti. Muted enough to sit
        // behind the text, distinct enough to tell two authors apart.
        return colorScheme == .dark
            ? Color(hue: hue, saturation: 0.28, brightness: 0.56)
            : Color(hue: hue, saturation: 0.34, brightness: 0.58)
    }

    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

#if DEBUG
#Preview("Avatars") {
    VStack(alignment: .leading, spacing: Space.md) {
        ForEach(
            [
                ("Emirhan Engin", "me@emirhanengin.com"),
                ("Berkay Beyaz", "berkay@bugece.co"),
                ("dependabot[bot]", "bot@github.com"),
                ("", "nobody@example.com"),
            ],
            id: \.1
        ) { name, email in
            HStack(spacing: Space.md) {
                Avatar(name: name, email: email)
                Text(name.isEmpty ? email : name)
                    .font(Typography.secondaryDetail)
            }
        }
    }
    .padding()
}
#endif
