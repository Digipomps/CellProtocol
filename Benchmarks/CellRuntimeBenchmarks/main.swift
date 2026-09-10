// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import CellBase
import CellVapor
import Darwin
import Foundation

/// A deliberately bounded local benchmark runner. It is not a load generator
/// and must only be used with synthetic, process-local data.
@main
struct CellRuntimeBenchmarks {
    static func main() async {
        do {
            let configuration = try BenchmarkConfiguration(arguments: Array(CommandLine.arguments.dropFirst()))
            let output = try await BenchmarkRunner(configuration: configuration).run()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(output), as: UTF8.self))
        } catch {
            fputs("CellRuntimeBenchmarks failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

private enum BenchmarkFailure: LocalizedError {
    case invalidArgument(String)
    case missingStorageDirectory
    case persistencePathPreflightFailed(String)
    case persistenceWriteFailed(String)
    case persistenceLoadFailed(String)
    case flowDeliveryTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message): return message
        case .missingStorageDirectory: return "persistence workload requires --storage-dir"
        case .persistencePathPreflightFailed(let error): return "persistence path-policy preflight failed: \(error)"
        case .persistenceWriteFailed(let error): return "could not store synthetic GeneralCell: \(error)"
        case .persistenceLoadFailed(let error): return "stored synthetic GeneralCell could not be loaded: \(error)"
        case .flowDeliveryTimedOut(let identifier): return "flow element was not delivered before the bounded wait: \(identifier)"
        }
    }
}

private enum Workload: String, Codable, CaseIterable {
    case idle
    case cell
    case resolver
    case flow
    case flowOverflow = "flow-overflow"
    case persistence
}

private struct BenchmarkConfiguration: Codable {
    let workload: Workload
    let operations: Int
    let concurrency: Int
    let idleSeconds: Double
    let flowHandlerDelayMilliseconds: UInt64
    let overflowSettleSeconds: Double
    let storageDirectory: String?
    let revision: String

    init(arguments: [String]) throws {
        var workload: Workload = .cell
        var operations = 1_000
        var concurrency = 1
        var idleSeconds = 10.0
        var flowHandlerDelayMilliseconds: UInt64 = 5
        var overflowSettleSeconds = 3.0
        var storageDirectory: String?
        var revision = "unknown"

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func nextValue() throws -> String {
                let nextIndex = index + 1
                guard nextIndex < arguments.count else {
                    throw BenchmarkFailure.invalidArgument("Missing value after \(argument)")
                }
                index = nextIndex
                return arguments[nextIndex]
            }

            switch argument {
            case "--workload":
                guard let value = Workload(rawValue: try nextValue()) else {
                    throw BenchmarkFailure.invalidArgument("--workload must be one of: \(Workload.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                workload = value
            case "--operations":
                guard let value = Int(try nextValue()) else {
                    throw BenchmarkFailure.invalidArgument("--operations must be an integer")
                }
                operations = value
            case "--concurrency":
                guard let value = Int(try nextValue()) else {
                    throw BenchmarkFailure.invalidArgument("--concurrency must be an integer")
                }
                concurrency = value
            case "--idle-seconds":
                guard let value = Double(try nextValue()) else {
                    throw BenchmarkFailure.invalidArgument("--idle-seconds must be a number")
                }
                idleSeconds = value
            case "--flow-handler-delay-ms":
                guard let value = UInt64(try nextValue()) else {
                    throw BenchmarkFailure.invalidArgument("--flow-handler-delay-ms must be an integer")
                }
                flowHandlerDelayMilliseconds = value
            case "--overflow-settle-seconds":
                guard let value = Double(try nextValue()) else {
                    throw BenchmarkFailure.invalidArgument("--overflow-settle-seconds must be a number")
                }
                overflowSettleSeconds = value
            case "--storage-dir":
                storageDirectory = try nextValue()
            case "--revision":
                revision = try nextValue()
            case "--help", "-h":
                throw BenchmarkFailure.invalidArgument(Self.usage)
            default:
                throw BenchmarkFailure.invalidArgument("Unknown argument: \(argument)\n\n\(Self.usage)")
            }
            index += 1
        }

        guard (1...20_000).contains(operations) else {
            throw BenchmarkFailure.invalidArgument("--operations must be between 1 and 20000")
        }
        guard (1...32).contains(concurrency) else {
            throw BenchmarkFailure.invalidArgument("--concurrency must be between 1 and 32")
        }
        guard (0.1...60).contains(idleSeconds) else {
            throw BenchmarkFailure.invalidArgument("--idle-seconds must be between 0.1 and 60")
        }
        guard (0.1...30).contains(overflowSettleSeconds) else {
            throw BenchmarkFailure.invalidArgument("--overflow-settle-seconds must be between 0.1 and 30")
        }

        self.workload = workload
        self.operations = operations
        self.concurrency = concurrency
        self.idleSeconds = idleSeconds
        self.flowHandlerDelayMilliseconds = flowHandlerDelayMilliseconds
        self.overflowSettleSeconds = overflowSettleSeconds
        self.storageDirectory = storageDirectory
        self.revision = revision
    }

    private static let usage = """
    Usage: CellRuntimeBenchmarks --workload <idle|cell|resolver|flow|flow-overflow|persistence> [options]

      --operations <1...20000>              Operations (default 1000)
      --concurrency <1...32>                Worker Swift tasks (default 1)
      --idle-seconds <0.1...60>             Idle baseline duration (default 10)
      --storage-dir <absolute path>          Required for persistence; synthetic data only
      --flow-handler-delay-ms <integer>      Slow-consumer delay for flow-overflow (default 5)
      --overflow-settle-seconds <0.1...30>   Wait for the bounded flow queue to settle (default 3)
      --revision <git revision>              Recorded only; supplied by the wrapper script
    """
}

private struct BenchmarkOutput: Codable {
    let formatVersion: Int
    let timestampUTC: String
    let revision: String
    let platform: PlatformDescription
    let configuration: BenchmarkConfiguration
    let setupSeconds: Double
    let resourceBeforeMeasurement: ResourceUsage
    let resourceAfterMeasurement: ResourceUsage
    let resourceDelta: ResourceUsageDelta
    let summary: WorkloadSummary
}

private struct PlatformDescription: Codable {
    let operatingSystem: String
    let activeProcessorCount: Int
    let physicalMemoryBytes: UInt64
}

private struct ResourceUsage: Codable {
    let userCPUSeconds: Double
    let systemCPUSeconds: Double
    let maximumResidentBytes: Int64
    let voluntaryContextSwitches: Int64
    let involuntaryContextSwitches: Int64
    let blockInputOperations: Int64
    let blockOutputOperations: Int64
    let pageReclaims: Int64
    let pageFaults: Int64
}

private struct ResourceUsageDelta: Codable {
    let userCPUSeconds: Double
    let systemCPUSeconds: Double
    let totalCPUSeconds: Double
    let cpuCapacityPercent: Double
    let maximumResidentBytesAtStart: Int64
    let maximumResidentBytesAtEnd: Int64
    let voluntaryContextSwitches: Int64
    let involuntaryContextSwitches: Int64
    let blockInputOperations: Int64
    let blockOutputOperations: Int64
    let pageReclaims: Int64
    let pageFaults: Int64
}

private struct WorkloadSummary: Codable {
    let successfulOperations: Int
    let workerTasksCreated: Int
    let peakConfiguredInFlightTasks: Int
    let wallSeconds: Double
    let throughputOperationsPerSecond: Double
    let latencyNanoseconds: LatencyDistribution?
    let queueObservation: QueueObservation?
    let notes: [String]
}

private struct LatencyDistribution: Codable {
    let samples: Int
    let minimum: UInt64
    let p50: UInt64
    let p95: UInt64
    let p99: UInt64
    let maximum: UInt64
}

private struct QueueObservation: Codable {
    let queueName: String
    let configuredCapacity: Int
    let submittedElements: Int
    let deliveredElementsAfterSettle: Int
    let slowConsumerDelayMilliseconds: UInt64
    let interpretation: String
}

private final class BenchmarkRunner {
    private let configuration: BenchmarkConfiguration

    init(configuration: BenchmarkConfiguration) {
        self.configuration = configuration
    }

    func run() async throws -> BenchmarkOutput {
        let setupStarted = MonotonicClock.now()
        let vault = EphemeralIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = CellResolver.sharedInstance
        CellBase.enabledDiagnosticLogDomains = []
        CellBase.persistedCellMasterKey = Data(repeating: 0xA5, count: 32)
        guard let owner = await vault.identity(for: "runtime-capacity-benchmark", makeNewIfNotFound: true) else {
            throw BenchmarkFailure.invalidArgument("Could not create the synthetic benchmark identity")
        }

        let prepared = try await prepare(owner: owner)
        let setupSeconds = MonotonicClock.elapsedSeconds(since: setupStarted)
        let resourcesBefore = currentResourceUsage()
        let measuredStarted = MonotonicClock.now()
        let summary = try await execute(prepared: prepared)
        let measuredWallSeconds = MonotonicClock.elapsedSeconds(since: measuredStarted)
        let resourcesAfter = currentResourceUsage()

        let adjustedSummary = WorkloadSummary(
            successfulOperations: summary.successfulOperations,
            workerTasksCreated: summary.workerTasksCreated,
            peakConfiguredInFlightTasks: summary.peakConfiguredInFlightTasks,
            wallSeconds: measuredWallSeconds,
            throughputOperationsPerSecond: measuredWallSeconds > 0
                ? Double(summary.successfulOperations) / measuredWallSeconds
                : 0,
            latencyNanoseconds: summary.latencyNanoseconds,
            queueObservation: summary.queueObservation,
            notes: summary.notes
        )

        return BenchmarkOutput(
            formatVersion: 1,
            timestampUTC: ISO8601DateFormatter().string(from: Date()),
            revision: configuration.revision,
            platform: PlatformDescription(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
            ),
            configuration: configuration,
            setupSeconds: setupSeconds,
            resourceBeforeMeasurement: resourcesBefore,
            resourceAfterMeasurement: resourcesAfter,
            resourceDelta: resourceDelta(
                before: resourcesBefore,
                after: resourcesAfter,
                wallSeconds: measuredWallSeconds
            ),
            summary: adjustedSummary
        )
    }

    private enum PreparedWorkload {
        case idle
        case cell(CounterCell, Identity)
        case resolver(CounterCell, CellResolver, URL, String, Identity)
        case flow(FlowElementPusherCell, GeneralCell, ReceiptLedger, LockedFlowPusher, Identity)
        case flowOverflow(FlowElementPusherCell, GeneralCell, ReceiptLedger, Identity)
        case persistence(PersistenceDriver, Identity)
    }

    private func prepare(owner: Identity) async throws -> PreparedWorkload {
        switch configuration.workload {
        case .idle:
            let cell = await GeneralCell(owner: owner)
            try await CellResolver.sharedInstance.registerNamedEmitCell(
                name: "RuntimeCapacityIdle-\(UUID().uuidString)",
                emitCell: cell,
                scope: .scaffoldUnique,
                identity: owner
            )
            return .idle
        case .cell:
            return .cell(try await makeCounterCell(owner: owner), owner)
        case .resolver:
            let cell = try await makeCounterCell(owner: owner)
            let name = "RuntimeCapacityResolver-\(UUID().uuidString)"
            let resolver = CellResolver.sharedInstance
            try await resolver.registerNamedEmitCell(
                name: name,
                emitCell: cell,
                scope: .scaffoldUnique,
                identity: owner
            )
            guard let url = URL(string: "cell:///\(name)/value") else {
                throw BenchmarkFailure.invalidArgument("Could not construct synthetic resolver URL")
            }
            return .resolver(cell, resolver, url, name, owner)
        case .flow:
            let producer = FlowElementPusherCell(owner: owner)
            let consumer = await GeneralCell(owner: owner)
            let receipts = ReceiptLedger()
            await consumer.addIntercept(requester: owner) { element, _ in
                await receipts.record(element.id)
                return element
            }
            _ = try await consumer.attach(emitter: producer, label: "benchmark", requester: owner)
            try await consumer.absorbFlow(label: "benchmark", requester: owner)
            return .flow(producer, consumer, receipts, LockedFlowPusher(producer: producer, requester: owner), owner)
        case .flowOverflow:
            let producer = FlowElementPusherCell(owner: owner)
            let consumer = await GeneralCell(owner: owner)
            let receipts = ReceiptLedger()
            let delayNanoseconds = configuration.flowHandlerDelayMilliseconds * 1_000_000
            await consumer.addIntercept(requester: owner) { element, _ in
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
                await receipts.record(element.id)
                return element
            }
            _ = try await consumer.attach(emitter: producer, label: "benchmark-overflow", requester: owner)
            try await consumer.absorbFlow(label: "benchmark-overflow", requester: owner)
            return .flowOverflow(producer, consumer, receipts, owner)
        case .persistence:
            guard let storageDirectory = configuration.storageDirectory else {
                throw BenchmarkFailure.missingStorageDirectory
            }
            // Create the supplied directory before resolving aliases.  On this macOS
            // host `/private/tmp` aliases `/tmp`; resolving a *nonexistent* leaf
            // does not canonicalize that prefix, while the storage root later does.
            // Creating it first keeps the benchmark root and its generated children
            // in the same canonical namespace for the path-confinement policy.
            let requestedDirectoryURL = URL(fileURLWithPath: storageDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: requestedDirectoryURL, withIntermediateDirectories: true)
            let directoryURL = requestedDirectoryURL.resolvingSymlinksInPath()
            CellBase.documentRootPath = directoryURL.path
            return .persistence(try PersistenceDriver(), owner)
        }
    }

    private func makeCounterCell(owner: Identity) async throws -> CounterCell {
        let cell = await CounterCell(owner: owner)
        try await cell.ensureRuntimeReady()
        return cell
    }

    private func execute(prepared: PreparedWorkload) async throws -> WorkloadSummary {
        switch prepared {
        case .idle:
            try await Task.sleep(nanoseconds: UInt64(configuration.idleSeconds * 1_000_000_000))
            return WorkloadSummary(
                successfulOperations: 0,
                workerTasksCreated: 0,
                peakConfiguredInFlightTasks: 0,
                wallSeconds: 0,
                throughputOperationsPerSecond: 0,
                latencyNanoseconds: nil,
                queueObservation: nil,
                notes: ["Idle baseline holds a configured GeneralCell/resolver registration without application operations."]
            )
        case let .cell(cell, owner):
            let latencies = try await runWorkers(operationCount: configuration.operations, concurrency: configuration.concurrency) { index in
                let started = MonotonicClock.now()
                _ = try await cell.set(keypath: "value", value: .string("\(index)"), requester: owner)
                _ = try await cell.get(keypath: "value", requester: owner)
                return MonotonicClock.elapsedNanoseconds(since: started)
            }
            return operationSummary(latencies: latencies, notes: [
                "One operation is one authorized GeneralCell set followed by get through registered intercepts.",
                "workerTasksCreated counts only benchmark worker tasks; it is not a runtime-wide Swift task count."
            ])
        case let .resolver(cell, resolver, url, _, owner):
            let latencies = try await runWorkers(operationCount: configuration.operations, concurrency: configuration.concurrency) { index in
                let started = MonotonicClock.now()
                _ = try await resolver.set(value: .string("\(index)"), into: url, requester: owner)
                _ = try await resolver.get(from: url, requester: owner)
                return MonotonicClock.elapsedNanoseconds(since: started)
            }
            await resolver.unregisterEmitCell(uuid: cell.uuid)
            return operationSummary(latencies: latencies, notes: [
                "One operation is resolver URL split, endpoint resolution, authorization and GeneralCell set/get.",
                "The benchmark uses the synthetic owner, so it does not measure signature-verification or remote bridge cost."
            ])
        case let .flow(_, consumer, receipts, pusher, owner):
            let latencies = try await runWorkers(operationCount: configuration.operations, concurrency: configuration.concurrency) { index in
                let identifier = "flow-\(index)"
                let started = MonotonicClock.now()
                pusher.push(FlowElement(
                    id: identifier,
                    title: "runtime-capacity",
                    content: .string("synthetic"),
                    properties: .init(type: .event, contentType: .string)
                ))
                let arrived = await receipts.wait(for: identifier, timeoutNanoseconds: 2_000_000_000)
                guard arrived else { throw BenchmarkFailure.flowDeliveryTimedOut(identifier) }
                return MonotonicClock.elapsedNanoseconds(since: started)
            }
            await consumer.detachAndWait(label: "benchmark", requester: owner)
            return operationSummary(latencies: latencies, notes: [
                "One operation is a locally produced FlowElement delivered through GeneralCell.attach/absorbFlow and its AsyncStream queue.",
                "Producer calls are lock-serialized because this benchmark does not assume multi-writer safety for PassthroughSubject; the consumer path remains asynchronous."
            ])
        case let .flowOverflow(producer, consumer, receipts, owner):
            for index in 0..<configuration.operations {
                producer.pushFlowElement(
                    FlowElement(
                        id: "overflow-\(index)",
                        title: "runtime-capacity-overflow",
                        content: .string("synthetic"),
                        properties: .init(type: .event, contentType: .string)
                    ),
                    requester: owner
                )
            }
            try await Task.sleep(nanoseconds: UInt64(configuration.overflowSettleSeconds * 1_000_000_000))
            let delivered = await receipts.count()
            await consumer.detachAndWait(label: "benchmark-overflow", requester: owner)
            return WorkloadSummary(
                successfulOperations: delivered,
                workerTasksCreated: 1,
                peakConfiguredInFlightTasks: 1,
                wallSeconds: 0,
                throughputOperationsPerSecond: 0,
                latencyNanoseconds: nil,
                queueObservation: QueueObservation(
                    queueName: "GeneralCell.absorbFlow AsyncStream",
                    configuredCapacity: 256,
                    submittedElements: configuration.operations,
                    deliveredElementsAfterSettle: delivered,
                    slowConsumerDelayMilliseconds: configuration.flowHandlerDelayMilliseconds,
                    interpretation: "The runtime's bufferingOldest(256) queue fail-closes the subscription when its continuation reports a dropped element. This is an overflow guard, not producer-propagated backpressure."
                ),
                notes: [
                    "The consumer intentionally delays every element. A delivered count below submitted count is expected once overflow is induced; investigate if it is not repeatable.",
                    "This workload intentionally tests the documented bounded-queue failure behavior and is not a throughput score."
                ]
            )
        case let .persistence(driver, owner):
            let latencies = try await runWorkers(operationCount: configuration.operations, concurrency: configuration.concurrency) { index in
                let started = MonotonicClock.now()
                try await driver.persistAndReload(index: index, owner: owner)
                return MonotonicClock.elapsedNanoseconds(since: started)
            }
            return operationSummary(latencies: latencies, notes: [
                "One operation creates a synthetic persistent GeneralCell, encrypts and atomically writes it, reloads it through TypedCellUtility, and checks its runtime surface.",
                "PersistenceDriver is actor-serialized because TypedCellUtility does not publish a concurrent-use contract; concurrent callers therefore expose queueing and storage latency without asserting unproven multiwriter safety.",
                "Data.write(.atomic) is not an fsync or power-loss-durability measurement."
            ])
        }
    }

    private func operationSummary(latencies: [UInt64], notes: [String]) -> WorkloadSummary {
        WorkloadSummary(
            successfulOperations: latencies.count,
            workerTasksCreated: min(configuration.concurrency, configuration.operations),
            peakConfiguredInFlightTasks: min(configuration.concurrency, configuration.operations),
            wallSeconds: 0,
            throughputOperationsPerSecond: 0,
            latencyNanoseconds: latencyDistribution(latencies),
            queueObservation: nil,
            notes: notes
        )
    }
}

private actor OperationDistributor {
    private var nextIndex = 0
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func next() -> Int? {
        guard nextIndex < limit else { return nil }
        defer { nextIndex += 1 }
        return nextIndex
    }
}

private func runWorkers(
    operationCount: Int,
    concurrency: Int,
    operation: @escaping (Int) async throws -> UInt64
) async throws -> [UInt64] {
    let distributor = OperationDistributor(limit: operationCount)
    return try await withThrowingTaskGroup(of: [UInt64].self, returning: [UInt64].self) { group in
        for _ in 0..<min(operationCount, concurrency) {
            group.addTask {
                var localLatencies = [UInt64]()
                while let index = await distributor.next() {
                    try Task.checkCancellation()
                    localLatencies.append(try await operation(index))
                }
                return localLatencies
            }
        }

        var allLatencies = [UInt64]()
        for try await localLatencies in group {
            allLatencies.append(contentsOf: localLatencies)
        }
        return allLatencies
    }
}

private actor CounterState {
    private var lastValue: ValueType = .null

    func set(_ value: ValueType) -> ValueType {
        lastValue = value
        return value
    }

    func get() -> ValueType {
        lastValue
    }
}

private final class CounterCell: GeneralCell {
    private let counterState: CounterState

    required init(owner: Identity) async {
        counterState = CounterState()
        await super.init(owner: owner)
    }

    required init(from decoder: Decoder) throws {
        counterState = CounterState()
        try super.init(from: decoder)
    }

    override func installCellRuntimeBindingsForAccess() async throws {
        let owner = storedOwnerIdentity
        await registerSet(key: "value", owner: owner) { [counterState] _, value in
            await counterState.set(value)
        }
        await registerGet(key: "value", owner: owner) { [counterState] _ in
            await counterState.get()
        }
    }
}

private final class LockedFlowPusher: @unchecked Sendable {
    private let lock = NSLock()
    private let producer: FlowElementPusherCell
    private let requester: Identity

    init(producer: FlowElementPusherCell, requester: Identity) {
        self.producer = producer
        self.requester = requester
    }

    func push(_ element: FlowElement) {
        lock.lock()
        producer.pushFlowElement(element, requester: requester)
        lock.unlock()
    }
}

private actor ReceiptLedger {
    private var received = Set<String>()
    private var waiters = [UUID: (identifier: String, continuation: CheckedContinuation<Bool, Never>)]()

    func record(_ identifier: String) {
        received.insert(identifier)
        let ready = waiters.filter { $0.value.identifier == identifier }
        for (token, waiter) in ready {
            waiters[token] = nil
            waiter.continuation.resume(returning: true)
        }
    }

    func count() -> Int {
        received.count
    }

    func wait(for identifier: String, timeoutNanoseconds: UInt64) async -> Bool {
        if received.contains(identifier) { return true }
        let token = UUID()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.waitForReceipt(identifier: identifier, token: token) }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return false
            }
            let value = await group.next() ?? false
            group.cancelAll()
            cancelWaiter(token)
            return value
        }
    }

    private func waitForReceipt(identifier: String, token: UUID) async -> Bool {
        if received.contains(identifier) { return true }
        return await withCheckedContinuation { continuation in
            if received.contains(identifier) {
                continuation.resume(returning: true)
            } else {
                waiters[token] = (identifier, continuation)
            }
        }
    }

    private func cancelWaiter(_ token: UUID) {
        guard let waiter = waiters.removeValue(forKey: token) else { return }
        waiter.continuation.resume(returning: false)
    }
}

private actor PersistenceDriver {
    private let utility: TypedCellUtility
    private let storage: FileSystemCellStorage

    init() throws {
        storage = FileSystemCellStorage()
        utility = TypedCellUtility(storage: storage)
        try utility.register(name: "GeneralCell", type: GeneralCell.self)
    }

    func persistAndReload(index: Int, owner: Identity) async throws {
        let cell = await GeneralCell(owner: owner)
        cell.persistancy = .persistant
        do {
            guard let documentRootPath = CellBase.documentRootPath else {
                throw BenchmarkFailure.persistencePathPreflightFailed("documentRootPath is nil")
            }
            let root = URL(fileURLWithPath: documentRootPath, isDirectory: true)
            let candidate = root.appendingPathComponent(cell.uuid, isDirectory: true)
            let cellDirectory: URL
            do {
                cellDirectory = try CellStoragePathPolicy.component(cell.uuid, under: root)
            } catch {
                throw BenchmarkFailure.persistencePathPreflightFailed(
                    "\(error); root=\(root.path); candidate=\(candidate.path); resolvedRoot=\(root.resolvingSymlinksInPath().path); resolvedCandidate=\(candidate.resolvingSymlinksInPath().path)"
                )
            }
            _ = try CellStoragePathPolicy.filename("typedCell.json", under: cellDirectory)
        } catch let error as BenchmarkFailure {
            throw error
        } catch {
            throw BenchmarkFailure.persistencePathPreflightFailed(String(describing: error))
        }
        do {
            try storage.storeCell(
                cellName: "GeneralCell",
                cell: cell,
                uuid: cell.uuid,
                options: CellStorageWriteOptions(
                    ownerIdentityUUID: owner.uuid,
                    encryptedAtRestRequired: true
                )
            )
        } catch {
            throw BenchmarkFailure.persistenceWriteFailed(String(describing: error))
        }
        guard let loaded = utility.loadTypedEmitCell(with: cell.uuid) as? GeneralCell else {
            throw BenchmarkFailure.persistenceLoadFailed("TypedCellUtility returned nil after a successful write")
        }
        _ = try await loaded.keys(requester: owner)
        _ = index
    }
}

private enum MonotonicClock {
    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedNanoseconds(since started: UInt64) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds - started
    }

    static func elapsedSeconds(since started: UInt64) -> Double {
        Double(elapsedNanoseconds(since: started)) / 1_000_000_000
    }
}

private func currentResourceUsage() -> ResourceUsage {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else {
        return ResourceUsage(
            userCPUSeconds: 0,
            systemCPUSeconds: 0,
            maximumResidentBytes: 0,
            voluntaryContextSwitches: 0,
            involuntaryContextSwitches: 0,
            blockInputOperations: 0,
            blockOutputOperations: 0,
            pageReclaims: 0,
            pageFaults: 0
        )
    }
    return ResourceUsage(
        userCPUSeconds: timeInterval(usage.ru_utime),
        systemCPUSeconds: timeInterval(usage.ru_stime),
        maximumResidentBytes: Int64(usage.ru_maxrss),
        voluntaryContextSwitches: Int64(usage.ru_nvcsw),
        involuntaryContextSwitches: Int64(usage.ru_nivcsw),
        blockInputOperations: Int64(usage.ru_inblock),
        blockOutputOperations: Int64(usage.ru_oublock),
        pageReclaims: Int64(usage.ru_minflt),
        pageFaults: Int64(usage.ru_majflt)
    )
}

private func timeInterval(_ value: timeval) -> Double {
    Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
}

private func resourceDelta(before: ResourceUsage, after: ResourceUsage, wallSeconds: Double) -> ResourceUsageDelta {
    let user = max(0, after.userCPUSeconds - before.userCPUSeconds)
    let system = max(0, after.systemCPUSeconds - before.systemCPUSeconds)
    let total = user + system
    return ResourceUsageDelta(
        userCPUSeconds: user,
        systemCPUSeconds: system,
        totalCPUSeconds: total,
        cpuCapacityPercent: wallSeconds > 0 ? (total / wallSeconds) * 100 : 0,
        maximumResidentBytesAtStart: before.maximumResidentBytes,
        maximumResidentBytesAtEnd: after.maximumResidentBytes,
        voluntaryContextSwitches: max(0, after.voluntaryContextSwitches - before.voluntaryContextSwitches),
        involuntaryContextSwitches: max(0, after.involuntaryContextSwitches - before.involuntaryContextSwitches),
        blockInputOperations: max(0, after.blockInputOperations - before.blockInputOperations),
        blockOutputOperations: max(0, after.blockOutputOperations - before.blockOutputOperations),
        pageReclaims: max(0, after.pageReclaims - before.pageReclaims),
        pageFaults: max(0, after.pageFaults - before.pageFaults)
    )
}

private func latencyDistribution(_ values: [UInt64]) -> LatencyDistribution? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    func percentile(_ fraction: Double) -> UInt64 {
        let position = max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)
        return sorted[min(position, sorted.count - 1)]
    }
    return LatencyDistribution(
        samples: sorted.count,
        minimum: sorted[0],
        p50: percentile(0.50),
        p95: percentile(0.95),
        p99: percentile(0.99),
        maximum: sorted[sorted.count - 1]
    )
}
