// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  HavenPushRegistrationTests.swift
//  PDD_testmatrise-og-apns-chat WP2 / T5.1 — token belongs to an entity.
//  purpose://candidate.testmatrise.apns.token-belongs-to-an-entity
//

import Foundation
import XCTest
@testable import CellBase

final class HavenPushRegistrationTests: XCTestCase {

    private let token = String(repeating: "ab12cd34", count: 8)
    private let otherToken = String(repeating: "ef56ab78", count: 8)
    private let bundle = "org.digipomps.haven"

    private func register(
        _ entity: SimulatedEntity,
        token: String? = nil,
        environment: HavenPushEnvironment = .sandbox,
        now: Date = Date()
    ) async throws -> HavenPushRegistration {
        try await HavenPushRegistration.make(
            entity: entity.owner, environment: environment, bundleId: bundle, token: token ?? self.token, now: now
        )
    }

    private func expect(_ failure: HavenPushVerifier.Failure, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? HavenPushVerifier.Failure, failure, file: file, line: line)
        }
    }

    func testSignedRegistrationVerifiesAndIsKeyedByEntity() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        let registration = try await register(kjetil)
        XCTAssertEqual(registration.entity, kjetil.owner.uuid)
        XCTAssertNoThrow(try HavenPushVerifier.verify(registration))
        var registry = HavenPushRegistry()
        let record = try registry.register(registration)
        XCTAssertEqual(registry.activeRegistrations(entity: kjetil.owner.uuid), [record])
    }

    func testUnsignedRegistrationIsRefused() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        var registration = try await register(kjetil)
        registration.proof = nil
        expect(.unsigned) { try HavenPushVerifier.verify(registration) }
    }

    func testTamperedRegistrationIsRefused() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        var registration = try await register(kjetil)
        registration.token = otherToken            // signature covers the token
        expect(.signatureDoesNotMatchEntity) { try HavenPushVerifier.verify(registration) }
    }

    func testRegistrationSignedForAnotherEntityIsRefused() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        let vegar = await SimulatedEntity.make("vegar")
        var registration = try await register(kjetil)
        registration.entity = vegar.owner.uuid     // claim Vegar's token slot with Kjetil's signature
        expect(.signatureDoesNotMatchEntity) { try HavenPushVerifier.verify(registration) }
    }

    func testBadTokenAndBundleAreRefused() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        var bad = try await register(kjetil)
        bad.token = "NOT-HEX"
        expect(.badTokenFormat) { try HavenPushVerifier.verify(bad) }
        var badBundle = try await register(kjetil)
        badBundle.bundleId = "no/slashes"
        expect(.badBundleID) { try HavenPushVerifier.verify(badBundle) }
    }

    func testStaleRegistrationIsRefused() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        let old = try await register(kjetil, now: Date().addingTimeInterval(-3_600))
        expect(.stale) { try HavenPushVerifier.verify(old) }
    }

    func testEnvironmentOutsideTheTwoKnownDoesNotDecode() throws {
        let json = #"{"schema":"haven.push.register.v1","entity":"x","environment":"staging"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(HavenPushRegistration.self, from: Data(json.utf8)))
    }

    func testRegistryStoresOnlyTheAgreedFields() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        var registry = HavenPushRegistry()
        try registry.register(try await register(kjetil))
        let text = String(decoding: try JSONEncoder().encode(registry), as: UTF8.self)
        for forbidden in ["displayName", "email", "phone", "contact", "kjetil-private"] {
            XCTAssertFalse(text.contains(forbidden), "registry must not hold \(forbidden)")
        }
    }

    func testSameTokenAgainIsARefreshNotADuplicate() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        var registry = HavenPushRegistry()
        try registry.register(try await register(kjetil))
        try registry.register(try await register(kjetil))
        XCTAssertEqual(registry.activeRegistrations(entity: kjetil.owner.uuid).count, 1)
    }

    func testTwoDevicesOfTheSameEntityBothStay() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        var registry = HavenPushRegistry()
        try registry.register(try await register(kjetil, token: token))
        try registry.register(try await register(kjetil, token: otherToken))
        XCTAssertEqual(registry.activeRegistrations(entity: kjetil.owner.uuid).count, 2)
    }

    func testAnotherKeyCannotTakeOverAnEntity() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        var registry = HavenPushRegistry()
        try registry.register(try await register(kjetil))
        // Same UUID, different key: an impostor who minted a key for Kjetil's UUID.
        var impostorIdentity = Identity(kjetil.owner.uuid, displayName: "impostor", identityVault: nil)
        let impostorVault = EphemeralIdentityVault()
        await impostorVault.addIdentity(identity: &impostorIdentity, for: "private")
        let registration = try await HavenPushRegistration.make(
            entity: impostorIdentity, environment: .sandbox, bundleId: bundle, token: otherToken
        )
        XCTAssertThrowsError(try registry.register(registration)) {
            XCTAssertEqual($0 as? HavenPushVerifier.Failure, .keyChanged)
        }
        XCTAssertEqual(registry.activeRegistrations(entity: kjetil.owner.uuid).count, 1)
    }

    func testRevokeClearsTokenAndKeepsOnlyTheTime() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        var registry = HavenPushRegistry()
        let registration = try await register(kjetil)
        try registry.register(registration)
        let revocation = try await HavenPushRevocation.make(registrationID: registration.registrationID, by: kjetil.owner)
        try registry.revoke(revocation)
        XCTAssertTrue(registry.activeRegistrations(entity: kjetil.owner.uuid).isEmpty)
        XCTAssertTrue(registry.hasOnlyRevoked(entity: kjetil.owner.uuid))
        let record = try XCTUnwrap(registry.records.first)
        XCTAssertNil(record.token)
        XCTAssertNil(record.bundleId)
        XCTAssertNotNil(record.revokedAt)
        let text = String(decoding: try JSONEncoder().encode(registry), as: UTF8.self)
        XCTAssertFalse(text.contains(token), "a revoked token must not remain in stored state")
    }

    func testOnlyTheOwnerCanRevoke() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        let vegar = await SimulatedEntity.make("vegar")
        var registry = HavenPushRegistry()
        let registration = try await register(kjetil)
        try registry.register(registration)
        var revocation = try await HavenPushRevocation.make(registrationID: registration.registrationID, by: vegar.owner)
        XCTAssertThrowsError(try registry.revoke(revocation)) {
            XCTAssertEqual($0 as? HavenPushVerifier.Failure, .notTheOwnerOfRegistration)
        }
        revocation.proof = nil
        XCTAssertThrowsError(try registry.revoke(revocation)) {
            XCTAssertEqual($0 as? HavenPushVerifier.Failure, .unsigned)
        }
        XCTAssertEqual(registry.activeRegistrations(entity: kjetil.owner.uuid).count, 1)
    }

    func testRevokingAnUnknownRegistrationIsRefused() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        var registry = HavenPushRegistry()
        let revocation = try await HavenPushRevocation.make(registrationID: "pr-unknown", by: kjetil.owner)
        XCTAssertThrowsError(try registry.revoke(revocation)) {
            XCTAssertEqual($0 as? HavenPushVerifier.Failure, .unknownRegistration)
        }
    }

    func testApnsUnregisteredMarksTheTokenRevokedInternally() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        var registry = HavenPushRegistry()
        let registration = try await register(kjetil)
        try registry.register(registration)
        registry.markUnregistered(registrationID: registration.registrationID)
        XCTAssertTrue(registry.activeRegistrations(entity: kjetil.owner.uuid).isEmpty)
    }

    func testEntityLookupIsCaseInsensitive() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        var registry = HavenPushRegistry()
        try registry.register(try await register(kjetil))
        XCTAssertEqual(registry.activeRegistrations(entity: kjetil.owner.uuid.lowercased()).count, 1)
        XCTAssertEqual(registry.activeRegistrations(entity: kjetil.owner.uuid.uppercased()).count, 1)
    }

    func testCapPerEntityDropsTheOldest() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        var registry = HavenPushRegistry()
        for index in 0...HavenPushRegistry.maxActivePerEntity {
            let tokenN = String(format: "%064x", index + 1)
            try registry.register(try await register(kjetil, token: tokenN, now: Date().addingTimeInterval(TimeInterval(index))))
        }
        XCTAssertEqual(registry.activeRegistrations(entity: kjetil.owner.uuid).count, HavenPushRegistry.maxActivePerEntity)
    }
}
