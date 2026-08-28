import Foundation

/// Canonicalizes the portable purpose and interest references shared by runtimes.
///
/// Keep this utility as the single source of truth. Discovery tokens are only
/// useful when every runtime derives exactly the same canonical reference.
public enum PortableReference {
    public static func slugify(_ raw: String) -> String {
        let folded = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        let slug = folded
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "unknown" : slug
    }

    public static func make(kind: String, localReference: String?, name: String?) -> String? {
        let candidate = localReference.flatMap { $0.isEmpty ? nil : $0 } ?? name ?? ""
        guard !candidate.isEmpty else { return nil }

        if let separator = candidate.range(of: "://") {
            let remainder = candidate[separator.upperBound...]
            return "\(kind)://\(slugify(String(remainder)))"
        }
        return "\(kind)://\(slugify(candidate))"
    }
}
