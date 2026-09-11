#if canImport(Network)
import Foundation
import Network

/// Bonjour discovery only. The listener refuses every connection: protected
/// messages are sent to the independently trusted HTTPS origin by the host app.
/// Lifecycle is explicit and bounded; apps call stop on background/dismissal.
@MainActor
public final class NetworkLinkDiscovery {
    public static let serviceType = "_haven-link._tcp"
    public enum State: Equatable, Sendable {
        case stopped, starting, browsing, advertising, unavailable(String)
    }
    public private(set) var offers: [NearbyLinkOffer] = []
    public private(set) var state: State = .stopped
    public var onChange: (@MainActor @Sendable ([NearbyLinkOffer], State) -> Void)?
    private let trustedOrigins: Set<String>
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var expiryTask: Task<Void, Never>?
    private var generation = UUID()

    public init(trustedOrigins: Set<String>) { self.trustedOrigins = trustedOrigins }

    public func browse(duration: TimeInterval = 120, includePeerToPeer: Bool = true) {
        stop()
        let token = generation
        state = .starting
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = includePeerToPeer
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: "local."), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] status in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                switch status {
                case .ready: self.state = .browsing
                case .failed, .waiting:
                    self.stop()
                    self.state = .unavailable("Lokalt nettverk er ikke tilgjengelig. Bruk QR eller lenke.")
                default: break
                }
                self.publish()
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                var unique = Set<NearbyLinkOffer>()
                for result in results {
                    guard case let .bonjour(record) = result.metadata,
                          let offer = try? NearbyLinkOffer.fromDiscoveryFields(record.dictionary, trustedOrigins: self.trustedOrigins) else { continue }
                    unique.insert(offer)
                    if unique.count == 32 { break }
                }
                self.offers = unique.sorted { $0.id < $1.id }
                self.publish()
            }
        }
        browser.start(queue: .main)
        scheduleExpiry(duration: min(120, max(1, duration)), token: token)
        publish()
    }

    public func advertise(_ offer: NearbyLinkOffer, includePeerToPeer: Bool = true) throws {
        try offer.validate(trustedOrigins: trustedOrigins)
        stop()
        let token = generation
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = includePeerToPeer
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(name: "HAVEN-" + UUID().uuidString.prefix(8),
            type: Self.serviceType, domain: "local.", txtRecord: NWTXTRecord(offer.discoveryFields))
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { [weak self] status in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                switch status {
                case .ready: self.state = .advertising
                case .failed, .waiting:
                    self.stop()
                    self.state = .unavailable("Kunne ikke gjøre invitasjonen synlig. Bruk QR eller lenke.")
                default: break
                }
                self.publish()
            }
        }
        self.listener = listener
        state = .starting
        listener.start(queue: .main)
        scheduleExpiry(duration: Double(offer.expiresAt) - Date().timeIntervalSince1970, token: token)
        publish()
    }

    /// Stop browsing before HTTPS work begins to release peer-to-peer resources.
    public func select(_ offer: NearbyLinkOffer) throws -> NearbyLinkOffer {
        try offer.validate(trustedOrigins: trustedOrigins)
        guard offers.contains(offer) else { throw NearbyLinkOffer.ValidationError.invalidID }
        stop()
        return offer
    }

    public func stop() {
        generation = UUID()
        expiryTask?.cancel(); expiryTask = nil
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
        offers = []
        state = .stopped
        publish()
    }

    private func publish() { onChange?(offers, state) }

    private func scheduleExpiry(duration: TimeInterval, token: UUID) {
        let until = Date().addingTimeInterval(duration)
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                if Date() >= until { self.stop(); return }
                let fresh = self.offers.filter { (try? $0.validate(trustedOrigins: self.trustedOrigins)) != nil }
                if fresh != self.offers { self.offers = fresh; self.publish() }
            }
        }
    }

    deinit { expiryTask?.cancel(); browser?.cancel(); listener?.cancel() }
}
#endif
