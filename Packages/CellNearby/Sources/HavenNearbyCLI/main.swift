import Foundation
import CellNearby
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Small installed companion for sprout and other native shells. This program
/// only handles discovery. Its output is never a linked-identity receipt.
@main
struct HavenNearbyCLI {
    static let origins: Set<String> = ["https://staging.haven.digipomps.org", "https://haven.digipomps.org"]

    @MainActor static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("Nærhet mislyktes. Kontroller invitasjon, nettverkstillatelse og argumenter.\n".utf8))
            exit(2)
        }
    }

    enum Failure: Error { case arguments, unavailable, expired }

    @MainActor static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else { usage(); return }
        if command == "--help" { usage(); return }
        #if canImport(Network)
        let discovery = NetworkLinkDiscovery(trustedOrigins: origins)
        defer { discovery.stop() }
        switch command {
        case "browse":
            guard arguments.count == 1 || (arguments.count == 3 && arguments[1] == "--seconds") else { throw Failure.arguments }
            let duration = arguments.count == 3 ? Double(arguments[2]) ?? 0 : 30
            guard duration >= 1, duration <= 120 else { throw Failure.arguments }
            var emitted = Set<String>()
            discovery.onChange = { offers, _ in
                for offer in offers where emitted.insert(offer.id).inserted {
                    if let data = try? JSONEncoder().encode(offer) {
                        FileHandle.standardOutput.write(data + Data([10]))
                    }
                }
            }
            discovery.browse(duration: duration)
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if case .unavailable = discovery.state { throw Failure.unavailable }
        case "inspect", "advertise":
            guard arguments.count == 3, arguments[1] == "--offer-file" else { throw Failure.arguments }
            let file = URL(fileURLWithPath: arguments[2])
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 9999 <= 2048 else { throw Failure.arguments }
            let raw = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw) else { throw Failure.arguments }
            let offer = try NearbyLinkOffer.decodePublicationLink(url, trustedOrigins: origins)
            if command == "inspect" {
                FileHandle.standardOutput.write(try JSONEncoder().encode(offer) + Data([10]))
                return
            }
            // Invoking advertise is the CLI operator's explicit publication action.
            try discovery.advertise(offer)
            print("Invitasjon synlig til \(offer.expiresAt). Ctrl-C stopper. Dette lenker ingen identitet.")
            while Double(offer.expiresAt) > Date().timeIntervalSince1970 {
                try await Task.sleep(nanoseconds: 250_000_000)
                if case .unavailable = discovery.state { throw Failure.unavailable }
            }
        default: throw Failure.arguments
        }
        #else
        throw Failure.unavailable
        #endif
    }

    static func usage() {
        print("""
        haven-nearby browse [--seconds 1…120]
        haven-nearby inspect --offer-file <file containing haven://nearby-link URL>
        haven-nearby advertise --offer-file <file containing haven://nearby-link URL>
        Network/Bonjour on supported Apple hosts. Discovery does not prove ownership.
        """)
    }
}
