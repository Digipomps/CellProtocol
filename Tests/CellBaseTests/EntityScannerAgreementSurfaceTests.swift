// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellApple
@testable import CellBase

/// Vaktpost mot F1-klassen av feil: en nøkkel som blir lagt til
/// `EntityScannerCell.agreementTemplate` uten at noen tenker over hva den
/// eksponerer. `probeResult` og `disclosurePolicy` lå der en periode med `r---`,
/// slik at en innsluppet peer kunne lese refs godkjent for en annen peer, og
/// hele brukerens policy i klartekst.
///
/// Testen enumererer hele malen og feiler på alt som ikke står i fasiten.
/// Å legge til en nøkkel skal kreve at noen redigerer denne fasiten — det er
/// hele poenget.
final class EntityScannerAgreementSurfaceTests: XCTestCase {

    /// Handlinger. Skrivbare, aldri lesbare.
    private static let expectedWriteOnlyKeys: Set<String> = [
        "start",
        "stop",
        "invite",
        "requestContact",
        "acceptContact",
        "exportEncounter",
        "exportEncounterJSON",
        "sharedToken",
        "setDisclosurePolicy",
        "approveBeacon",
        "probeRequest",
        "probeDetail",
        "respondToInvitation"
    ]

    /// Lesbare for en motpart som er sluppet inn. Hver enkelt må kunne
    /// forsvares som noe en motpart trenger og som ikke lekker en tredjepart.
    private static let expectedReadableKeys: Set<String> = [
        "verificationMethods",
        "capabilities",
        "encounters"
    ]

    /// Arvet fra `GeneralCell` sin standardmal, ikke satt av EntityScannerCell.
    /// `feed` er flow-abonnementet en tilkoblet motpart må ha for i det hele tatt
    /// å motta hendelser, og `identity.displayName` er navnet du allerede har
    /// delt ved å koble til. Begge er gjennomgått og vurdert som riktige her.
    private static let inheritedBaseKeys: Set<String> = [
        "feed",
        "identity.displayName"
    ]

    /// Nøkler som ALDRI skal stå i malen, uansett rettighet.
    /// `disclosurePolicy` er brukerens intensjon i klartekst.
    /// `probeResult` er hele kartet, nøklet på hver eneste remote-UUID.
    private static let forbiddenKeys: Set<String> = [
        "disclosurePolicy",
        "probeResult"
    ]

    private func agreementTemplateGrants() async -> [Grant] {
        let owner = Identity()
        let cell = await EntityScannerCell(owner: owner)
        return cell.agreementTemplate.grants
    }

    func testAgreementTemplateExposesOnlyTheApprovedSurface() async {
        let grants = await agreementTemplateGrants()
        let keys = Set(grants.map(\.keypath))
        let expected = Self.expectedWriteOnlyKeys
            .union(Self.expectedReadableKeys)
            .union(Self.inheritedBaseKeys)

        let unexpected = keys.subtracting(expected)
        XCTAssertTrue(
            unexpected.isEmpty,
            """
            EntityScannerCell.agreementTemplate eksponerer nøkler som ikke er \
            gjennomgått: \(unexpected.sorted()). Legg dem til fasiten i denne \
            testen bare hvis du har vurdert hva en innsluppet motpart kan lese \
            gjennom dem — se F1 i Codex_FixList_NearbyScanner_2026-08-24.md.
            """
        )

        let missing = expected.subtracting(keys)
        XCTAssertTrue(missing.isEmpty, "Forventede nøkler mangler i malen: \(missing.sorted())")
    }

    func testForbiddenKeysAreNeverInTheAgreementTemplate() async {
        let grants = await agreementTemplateGrants()
        let keys = Set(grants.map(\.keypath))
        for forbidden in Self.forbiddenKeys {
            XCTAssertFalse(
                keys.contains(forbidden),
                """
                \(forbidden) står i agreement-malen. Den lekker enten brukerens \
                policy i klartekst eller refs godkjent for en annen peer. \
                Den skal være eier-bare.
                """
            )
        }
    }

    func testActionKeysAreWriteOnlyAndNeverReadable() async {
        let grants = await agreementTemplateGrants()
        for grant in grants where Self.expectedWriteOnlyKeys.contains(grant.keypath) {
            XCTAssertEqual(
                grant.permission.permissionString,
                "-w--",
                "Handlingsnøkkelen \(grant.keypath) skal være kun skrivbar, ikke \(grant.permission.permissionString)."
            )
        }
    }
}
