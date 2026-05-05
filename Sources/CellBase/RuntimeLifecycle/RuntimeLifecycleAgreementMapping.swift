// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct RuntimeLifecycleAgreementDefaults: Sendable {
    public var defaultHotTTLTicks: UInt64
    public var defaultMemoryWarningLeadTicks: UInt64
    public var defaultColdTTLTicks: UInt64?
    public var defaultTombstoneGraceTicks: UInt64
    public var defaultMemoryExpiryAction: RuntimeMemoryExpiryAction

    public init(
        defaultHotTTLTicks: UInt64 = 300,
        defaultMemoryWarningLeadTicks: UInt64 = 30,
        defaultColdTTLTicks: UInt64? = nil,
        defaultTombstoneGraceTicks: UInt64 = 0,
        defaultMemoryExpiryAction: RuntimeMemoryExpiryAction = .notifyOnly
    ) {
        self.defaultHotTTLTicks = defaultHotTTLTicks
        self.defaultMemoryWarningLeadTicks = defaultMemoryWarningLeadTicks
        self.defaultColdTTLTicks = defaultColdTTLTicks
        self.defaultTombstoneGraceTicks = defaultTombstoneGraceTicks
        self.defaultMemoryExpiryAction = defaultMemoryExpiryAction
    }
}

public enum RuntimeLifecycleAgreementMappingError: Error, Sendable, Equatable {
    case replaySnapshotRequiresColdStorage
    case replaySnapshotRequiresRetention
}

public struct RuntimeLifecycleAgreementResolution: Sendable, Equatable {
    public var policy: RuntimeLifecyclePolicy
    public var replayMode: ReplayGuaranteeMode
    public var allowEventLogGap: Bool
    public var payerIdentityUUID: String?
    public var billingTier: LifecycleBillingTier
    public var fundedUntilTick: UInt64?
    public var coldStorageAllowed: Bool
    public var encryptedAtRestRequired: Bool
    public var deleteIfUnfunded: Bool

    public init(
        policy: RuntimeLifecyclePolicy,
        replayMode: ReplayGuaranteeMode,
        allowEventLogGap: Bool,
        payerIdentityUUID: String?,
        billingTier: LifecycleBillingTier,
        fundedUntilTick: UInt64?,
        coldStorageAllowed: Bool,
        encryptedAtRestRequired: Bool,
        deleteIfUnfunded: Bool
    ) {
        self.policy = policy
        self.replayMode = replayMode
        self.allowEventLogGap = allowEventLogGap
        self.payerIdentityUUID = payerIdentityUUID
        self.billingTier = billingTier
        self.fundedUntilTick = fundedUntilTick
        self.coldStorageAllowed = coldStorageAllowed
        self.encryptedAtRestRequired = encryptedAtRestRequired
        self.deleteIfUnfunded = deleteIfUnfunded
    }
}

public enum RuntimeLifecycleAgreementMapper {
    public static func resolve(
        agreement: Agreement,
        nowTick: UInt64,
        defaults: RuntimeLifecycleAgreementDefaults = RuntimeLifecycleAgreementDefaults()
    ) throws -> RuntimeLifecycleAgreementResolution {
        var replay = ReplayGuaranteeCondition(mode: .none, minimumRetentionTicks: 0)
        var funding = LifecycleFundingCondition(
            payerIdentityUUID: "",
            billingTier: .none,
            maxHotTTLTicks: nil,
            maxColdTTLTicks: nil,
            fundedUntilTick: nil
        )
        var cold = ColdStorageCondition(
            allowPersistedColdTier: false,
            encryptedAtRestRequired: true,
            deleteIfUnfunded: true,
            tombstoneGraceTicks: defaults.defaultTombstoneGraceTicks
        )

        var hasReplay = false
        var hasFunding = false
        var hasCold = false

        for condition in agreement.conditions {
            if let replayCondition = condition as? ReplayGuaranteeCondition {
                replay = replayCondition
                hasReplay = true
                continue
            }
            if let fundingCondition = condition as? LifecycleFundingCondition {
                funding = fundingCondition
                hasFunding = true
                continue
            }
            if let coldCondition = condition as? ColdStorageCondition {
                cold = coldCondition
                hasCold = true
            }
        }

        let payerIdentityUUID = hasFunding ? funding.payerIdentityUUID : nil
        let funded = hasFunding ? ((funding.fundedUntilTick ?? UInt64.max) > nowTick) : false
        var effectiveBillingTier = hasFunding ? funding.billingTier : .none

        if !funded && cold.deleteIfUnfunded {
            effectiveBillingTier = .none
        }

        if effectiveBillingTier == .nonExpiring {
            return RuntimeLifecycleAgreementResolution(
                policy: .nonExpiring,
                replayMode: hasReplay ? replay.mode : .none,
                allowEventLogGap: hasReplay ? replay.allowEventLogGap : false,
                payerIdentityUUID: payerIdentityUUID,
                billingTier: effectiveBillingTier,
                fundedUntilTick: hasFunding ? funding.fundedUntilTick : nil,
                coldStorageAllowed: hasCold ? cold.allowPersistedColdTier : false,
                encryptedAtRestRequired: hasCold ? cold.encryptedAtRestRequired : true,
                deleteIfUnfunded: hasCold ? cold.deleteIfUnfunded : true
            )
        }

        var memoryTTLTicks = defaults.defaultHotTTLTicks
        if let maxHot = funding.maxHotTTLTicks {
            memoryTTLTicks = min(memoryTTLTicks, maxHot)
        }
        if memoryTTLTicks == 0 {
            memoryTTLTicks = 1
        }

        var persistedDataTTLTicks: UInt64? = defaults.defaultColdTTLTicks
        if let replayRetention = hasReplay ? Optional(replay.minimumRetentionTicks) : nil {
            switch replay.mode {
            case .none:
                break
            case .snapshot:
                guard hasCold, cold.allowPersistedColdTier else {
                    throw RuntimeLifecycleAgreementMappingError.replaySnapshotRequiresColdStorage
                }
                if replayRetention == 0 {
                    throw RuntimeLifecycleAgreementMappingError.replaySnapshotRequiresRetention
                }
                persistedDataTTLTicks = replayRetention
            case .eventLog:
                // Event-log replay can work without snapshots.
                if replayRetention > 0 {
                    persistedDataTTLTicks = max(persistedDataTTLTicks ?? 0, replayRetention)
                }
            }
        }

        if effectiveBillingTier == .hotOnly || effectiveBillingTier == .none {
            persistedDataTTLTicks = nil
        } else if let maxCold = funding.maxColdTTLTicks, let current = persistedDataTTLTicks {
            persistedDataTTLTicks = min(current, maxCold)
        }

        let policy = RuntimeLifecyclePolicy.expiring(
            memoryTTLTicks: memoryTTLTicks,
            memoryWarningLeadTicks: defaults.defaultMemoryWarningLeadTicks,
            persistedDataTTLTicks: persistedDataTTLTicks,
            tombstoneGraceTicks: hasCold ? cold.tombstoneGraceTicks : defaults.defaultTombstoneGraceTicks,
            memoryExpiryAction: defaults.defaultMemoryExpiryAction
        )

        return RuntimeLifecycleAgreementResolution(
            policy: policy,
            replayMode: hasReplay ? replay.mode : .none,
            allowEventLogGap: hasReplay ? replay.allowEventLogGap : false,
            payerIdentityUUID: payerIdentityUUID,
            billingTier: effectiveBillingTier,
            fundedUntilTick: hasFunding ? funding.fundedUntilTick : nil,
            coldStorageAllowed: hasCold ? cold.allowPersistedColdTier : false,
            encryptedAtRestRequired: hasCold ? cold.encryptedAtRestRequired : true,
            deleteIfUnfunded: hasCold ? cold.deleteIfUnfunded : true
        )
    }
}

public extension Agreement {
    func runtimeLifecycleResolution(
        nowTick: UInt64,
        defaults: RuntimeLifecycleAgreementDefaults = RuntimeLifecycleAgreementDefaults()
    ) throws -> RuntimeLifecycleAgreementResolution {
        try RuntimeLifecycleAgreementMapper.resolve(
            agreement: self,
            nowTick: nowTick,
            defaults: defaults
        )
    }
}
