// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

private enum RandomValueSource {
    static let alphanumericCharacters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    static func element<T>(from values: [T]) -> T {
        precondition(values.isEmpty == false, "Cannot select a random element from an empty collection.")
        return values[Int.random(in: 0..<values.count)]
    }
}

public extension Bool {
    static func random() -> Bool {
        var generator = SystemRandomNumberGenerator()
        return Bool.random(using: &generator)
    }
}

public extension Int {
    static func random(_ lower: Int = 0, _ upper: Int = 100) -> Int {
        guard lower <= upper else {
            return lower
        }
        return Int.random(in: lower...upper)
    }
}

public extension Int32 {
    static func random(_ lower: Int = 0, _ upper: Int = 100) -> Int32 {
        guard lower <= upper else {
            return Int32(lower)
        }
        return Int32.random(in: Int32(lower)...Int32(upper))
    }
}

public extension String {
    static func random(ofLength length: Int) -> String {
        return random(minimumLength: length, maximumLength: length)
    }

    static func random(minimumLength min: Int, maximumLength max: Int) -> String {
        return random(
            withCharactersInString: String(RandomValueSource.alphanumericCharacters),
            minimumLength: min,
            maximumLength: max
        )
    }

    static func random(withCharactersInString string: String, ofLength length: Int) -> String {
        return random(
            withCharactersInString: string,
            minimumLength: length,
            maximumLength: length
        )
    }

    static func random(withCharactersInString string: String, minimumLength min: Int, maximumLength max: Int) -> String {
        let characters = Array(string)
        guard min > 0, max >= min, characters.isEmpty == false else {
            return ""
        }

        let length = min == max ? min : Int.random(in: min...max)
        return String((0..<length).map { _ in RandomValueSource.element(from: characters) })
    }
}

public extension Double {
    static func random(_ lower: Double = 0, _ upper: Double = 100) -> Double {
        guard lower <= upper else {
            return lower
        }
        return Double.random(in: lower...upper)
    }
}

public extension Float {
    static func random(_ lower: Float = 0, _ upper: Float = 100) -> Float {
        guard lower <= upper else {
            return lower
        }
        return Float.random(in: lower...upper)
    }
}

public extension URL {
    static func random() -> URL {
        let candidates = [
            "https://example.org/",
            "https://swift.org/",
            "https://developer.apple.com/",
            "https://digipomps.org/",
            "https://www.w3.org/"
        ]
        return URL(string: RandomValueSource.element(from: candidates))!
    }
}

public struct Randoms {
    public static func randomBool() -> Bool {
        return Bool.random()
    }

    public static func randomInt(_ range: Range<Int>) -> Int {
        return Int.random(in: range)
    }

    public static func randomInt(_ lower: Int = 0, _ upper: Int = 100) -> Int {
        return Int.random(lower, upper)
    }

    public static func randomInt32(_ range: Range<Int32>) -> Int32 {
        return Int32.random(in: range)
    }

    public static func randomInt32(_ lower: Int = 0, _ upper: Int = 100) -> Int32 {
        return Int32.random(lower, upper)
    }

    public static func randomString(ofLength length: Int) -> String {
        return String.random(ofLength: length)
    }

    public static func randomString(minimumLength min: Int, maximumLength max: Int) -> String {
        return String.random(minimumLength: min, maximumLength: max)
    }

    public static func randomString(withCharactersInString string: String, ofLength length: Int) -> String {
        return String.random(withCharactersInString: string, ofLength: length)
    }

    public static func randomString(withCharactersInString string: String, minimumLength min: Int, maximumLength max: Int) -> String {
        return String.random(withCharactersInString: string, minimumLength: min, maximumLength: max)
    }

    public static func randomPercentageisOver(_ percentage: Int) -> Bool {
        let threshold = min(max(percentage, 0), 100)
        return Int.random(in: 0..<100) >= threshold
    }

    public static func randomPercentageIsOver(_ percentage: Int) -> Bool {
        return randomPercentageisOver(percentage)
    }

    public static func randomDouble(_ lower: Double = 0, _ upper: Double = 100) -> Double {
        return Double.random(lower, upper)
    }

    public static func randomFloat(_ lower: Float = 0, _ upper: Float = 100) -> Float {
        return Float.random(lower, upper)
    }

    public static func randomNSURL() -> URL {
        return URL.random()
    }

    public static func randomFakeName() -> String {
        return "\(randomFakeFirstName()) \(randomFakeLastName())"
    }

    public static func randomFakeFirstName() -> String {
        return RandomValueSource.element(from: [
            "Aksel", "Mina", "Jonas", "Sara", "Leah", "Noah", "Iben",
            "Sofia", "Emil", "Nora", "Oda", "Theo", "Eira"
        ])
    }

    public static func randomFakeLastName() -> String {
        return RandomValueSource.element(from: [
            "Solheim", "Berg", "Hagen", "Moen", "Lunde", "Dahl", "Vik",
            "Lien", "Strand", "Nygard", "Haugen", "Foss", "Myhre"
        ])
    }

    public static func randomFakeGender() -> String {
        return Bool.random() ? "Female" : "Male"
    }

    public static func randomFakeConversation() -> String {
        return RandomValueSource.element(from: [
            "Can we look at this once more?",
            "I think the next version should be simpler.",
            "Let's write down what actually happened.",
            "The small detail is probably the important one.",
            "I want the system to explain itself better.",
            "Can we make this safer before we ship it?",
            "That feels like a useful boundary.",
            "The prototype is working, but the naming needs care.",
            "Let's keep the interface stable and clean up inside."
        ])
    }

    public static func randomFakeTitle() -> String {
        return RandomValueSource.element(from: [
            "Product Lead",
            "Data Steward",
            "Community Host",
            "Systems Designer",
            "Research Coordinator",
            "Privacy Engineer",
            "Service Operator",
            "Learning Facilitator",
            "Commons Maintainer"
        ])
    }

    public static func randomFakeTag() -> String {
        return RandomValueSource.element(from: [
            "draft", "review", "signal", "identity", "commons",
            "consent", "vault", "flow"
        ])
    }

    fileprivate static func randomEnglishHonorific() -> String {
        return RandomValueSource.element(from: ["Mr.", "Ms.", "Dr.", "Prof.", "Mx."])
    }

    public static func randomFakeNameAndEnglishHonorific() -> String {
        return "\(randomEnglishHonorific()) \(randomFakeName())"
    }

    public static func randomFakeCity() -> String {
        let prefixes = ["Nord", "Syd", "Vest", "Ost", "Ny", "Fjord", "Eik"]
        let suffixes = ["vik", "dal", "havn", "nes", "heim", "lund", "berg", "strand", "by"]
        return "\(RandomValueSource.element(from: prefixes))\(RandomValueSource.element(from: suffixes))"
    }

    public static func randomCurrency() -> String {
        return RandomValueSource.element(from: [
            "NOK", "SEK", "DKK", "EUR", "GBP", "USD", "CAD",
            "AUD", "JPY", "CHF", "ISK", "NZD"
        ])
    }

    public enum GravatarStyle: String {
        case Standard
        case MM
        case Identicon
        case MonsterID
        case Wavatar
        case Retro

        static let allValues = [Standard, MM, Identicon, MonsterID, Wavatar, Retro]
    }
}
