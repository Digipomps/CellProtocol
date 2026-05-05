# Agreement Admission Remediation Plan

## Formaal
Denne planen beskriver hvordan HAVEN skal gaa fra dagens `signContract`-prototype til et komplett, forklarbart og brukerledet admission-lop for ikke-eier-tilgang.

Maalet er:
- en ikke-eier skal kunne starte `attach(...)`
- target-cellen skal kunne svare `signContract` nar avtalevilkar ikke er oppfylt enn
- conditions skal evalueres deterministisk
- runtime skal kunne skille mellom automatisk remediering og brukerhandling
- bruker skal kunne ledes til riktig helper/workbench
- nye bevis, credentials, betalinger eller grants skal kunne legges til
- admission skal kunne proveres pa nytt uten at hele konteksten gaar tapt
- signert agreement skal lagres med nok audit-spor til at tilgangen kan forklares senere

## Onsket flyt
1. `source.attach(emitter:label:requester:)` kalles.
2. `target.admit(context:)` returnerer `connected`, `denied` eller `signContract`.
3. Ved `signContract` evaluerer runtime target-cellens `agreementTemplate`.
4. Hver condition returnerer et eksplisitt resultat:
   - `met`
   - `autoResolvable`
   - `userActionRequired`
   - `denied`
5. Hvis alle conditions er `met`, blir agreement signert og `addAgreement(...)` fullfores.
6. Hvis noen conditions krever brukerhandling, emitter runtime en `connect.challenge` med:
   - `sessionId`
   - agreement payload
   - liste over condition issues
   - `requiredAction`
   - `helperCellConfiguration`
   - forklaring pa hva som mangler
7. Porthole eller annen klient aapner riktig helper.
8. Helperen hjelper brukeren med aa:
   - presentere VC eller annet bevis
   - betale billett eller registrere kvittering
   - be om et grant eller delegasjon
   - redigere og gjennomga agreement
9. Helperen trigger en retry av samme admission session.
10. Runtime evaluerer conditions pa nytt og gaar til `connected` nar alt er oppfylt.

## Dagens styrker
- `GeneralCell.attach(...)` kaller target-cellens `admit(context:)`.
- `GeneralCell.consumeConnectResponseForIdentity(...)` handterer `.signContract`.
- `processContractChallenge(...)` bygger allerede en liste med issues og sender `connect.challenge`.
- `ConnectChallengeDescriptor` kan allerede bære `requiredAction`, `userMessage` og `helperCellConfiguration`.
- Porthole kan allerede aapne `helperCellConfiguration` fra et `connect.challenge`.
- `AgreementWorkbench` finnes allerede som en egen scaffold/workbench for agreement-redigering.
- `EntityStudio` kan allerede importere agreement-records fra workbench.

## Dagens hull
- `Agreement` er fortsatt mer kontrakt enn request. Den mangler tydelige request-felt som `requestedCapabilities`, `declaredPurpose` og `evidenceRefs`.
- `ConnectContext` baerer bare source, target og identity. Den mangler admission-session, retry-kontekst og samlet evidence.
- `Condition.resolve(context:)` finnes, men brukes ikke i admission-lopet.
- Bare `ConditionalEngagement` beskriver i praksis en brukerledet remediering.
- `LookupCondition` og flere andre conditions er ikke robuste nok for deterministisk evaluering.
- `connect.challenge` mangler `sessionId`, slik at klienten ikke kan retry samme lop eksplisitt.
- `AgreementWorkbench` er ikke standard helper for `review_agreement`.
- Signed agreement records lagrer ikke full condition/evidence-bakgrunn for hvorfor tilgang faktisk ble gitt.

## Arkitektur-invarianter
- Resolver og runtime skal fortsatt vaere den eneste kilden til om access er gyldig.
- Ingen helper skal kunne "tvinge gjennom" tilgang uten at condition-evaluering gaar til `met`.
- All remediering skal vaere forklarbar for bruker og revisjon.
- Agreement og evidence skal vaere identity-bound og domain-scoped.
- Retry av admission skal vaere idempotent for samme session.
- Et `connect.challenge` skal alltid ha nok metadata til at klienten vet hva brukeren maa gjore videre.

## Fase 1 - Deterministisk condition-evaluering

### Maal
Gjor condition-evaluering stabil, asynkron og forklarbar uten aa endre hele systemet samtidig.

### Endringer
- Legg til en ny runtime-type:
  - `Sources/CellBase/Agreement/Condition/ConditionEvaluation.swift`
- La `Condition` faa en ny default-API via extension:
  - `evaluate(context:) async -> ConditionEvaluation`
  - default wrapper rundt dagens `isMet(context:)`
- Behold `isMet(context:)` midlertidig for bakoverkompatibilitet.
- Utvid `ConditionEvaluation` med:
  - `state`
  - `reasonCode`
  - `userMessage`
  - `requiredAction`
  - `canAutoResolve`
  - `helperCellConfiguration`
  - `developerHint`
  - `evidenceHints`
- Oppdater `GeneralCell.processContractChallenge(...)` til aa bruke `evaluate(context:)` i stedet for aa sette sammen metadata ad hoc.

### Filer
- `Sources/CellBase/Agreement/Condition/Condition.swift`
- `Sources/CellBase/Agreement/Condition/ConnectChallengeDescriptor.swift`
- `Sources/CellBase/Agreement/Condition/ConditionState.swift`
- `Sources/CellBase/Cells/GeneralCell/GeneralCell.swift`

### Konkrete feil som skal ryddes opp
- `LookupCondition` maa slutte aa bruke losrevne `Task { ... }` i `isMet`, og heller await-evaluere oppslag direkte.
- `GrantCondition` maa slutte aa ha demo-logikk som hardkoder `isMember`.
- `LoginCondition` maa enten implementeres ordentlig eller flagges tydelig som unsupported i challenge-resultatet.

### Akseptansekriterier
- En condition skal gi samme resultat ved samme input.
- `connect.challenge` skal inneholde minst ett issue med forklarbar metadata.
- Nye og gamle tester for `GeneralCellInterfaceTests` skal fortsatt passere.

## Fase 2 - Admission sessions og retry

### Maal
Gi admission-lopet en eksplisitt session som kan pauses, forklares og retryes.

### Endringer
- Legg til nye typer:
  - `Sources/CellBase/Agreement/AdmissionSession.swift`
  - `Sources/CellBase/Agreement/AdmissionSessionState.swift`
- `AdmissionSession` skal minst inneholde:
  - `id`
  - `label`
  - `requester`
  - `targetCellUUID`
  - `agreement`
  - `issues`
  - `createdAt`
  - `updatedAt`
  - `retryCount`
  - `lastConnectState`
- Lagre sessions i `GeneralAuditor`.
- Utvid `connect.challenge` payload med `sessionId`.
- Legg til en runtime-vei for retry. Kort sikt:
  - nye `GeneralCell` keypaths som `admission.sessions`, `admission.selectedSession`, `admission.retry`
- Lang sikt:
  - vurder en eksplisitt `Absorb.resumeAdmission(sessionID:requester:)`.

### Filer
- `Sources/CellBase/Cells/GeneralCell/Cast/GeneralAuditor.swift`
- `Sources/CellBase/Cells/GeneralCell/GeneralCell.swift`
- `Sources/CellBase/Protocols/CellProtocol.swift` (kun hvis vi gjor retry til protokoll-API)

### Akseptansekriterier
- En klient som mottar `connect.challenge` kan retry samme session uten aa miste agreement-konteksten.
- Runtime kan liste aktive admission sessions for debugging og UI.

## Fase 3 - Agreement som request, ikke bare contract-template

### Maal
Fa Agreement-modellen naermere den normative boka uten aa bryte dagens kode unodvendig.

### Endringer
- Utvid `Agreement` med request-felt:
  - `requestedCapabilities: [String]`
  - `declaredPurpose: String?`
  - `evidenceRefs: [AgreementEvidenceRef]`
  - `requestContext: Object?`
- Legg til:
  - `Sources/CellBase/Agreement/AgreementEvidenceRef.swift`
- Oppdater serialisering og alle agreement-payloads.
- La `AgreementWorkbench` redigere disse feltene eksplisitt.
- La `connect.challenge` vise declared purpose og manglende evidence i plain language.

### Filer
- `Sources/CellBase/Agreement/Agreement.swift`
- `Sources/CellBase/Agreement/ConnectContext.swift`
- `Sources/CellBase/ValueTypes/ValueType.swift`
- `Sources/CellBase/Cells/GeneralCell/GeneralCell.swift`
- `CellScaffold/Sources/App/Cells/AgreementWorkbench/AgreementWorkbenchCell.swift`
- `CellScaffold/Sources/App/Cells/AgreementWorkbench/AgreementWorkbenchConfigurationFactory.swift`

### Akseptansekriterier
- En agreement payload forklarer hva requester ber om, hvorfor, og hvilke evidence refs som ble brukt.
- Existing agreement serialization tests oppdateres uten tap av bakoverkompatibilitet.

## Fase 4 - Koble helpers inn i connect.challenge

### Maal
Sorge for at runtime kan lede brukeren til riktig remediering i stedet for bare aa si "review agreement".

### Endringer
- Definer en mapping fra `requiredAction` til default helper.
- Bruk `AgreementWorkbench` som default helper for:
  - `review_agreement`
  - `request_access`
- Lag egne helper-spor for:
  - `present_credential`
  - `prove_payment`
  - `obtain_grant`
  - `complete_login`
- La conditions som kan forklare seg selv implementere `ConnectChallengeProvidingCondition`.
- Der conditions ikke har egen helper, skal runtime legge paa tydelig `developerHint`.

### Filer
- `Sources/CellBase/Cells/GeneralCell/GeneralCell.swift`
- `Sources/CellBase/Agreement/Condition/ConnectChallengeDescriptor.swift`
- `CellScaffold/Sources/App/Cells/AgreementWorkbench/AgreementWorkbenchConfigurationFactory.swift`
- nye helper-celler i `CellScaffold/Sources/App/Cells/...`

### Foerste helper-pakke
- `AgreementWorkbench` for agreement review og request/grant-forklaring
- en enkel credential/proof helper som kan peke til `TrustedIssuerCell`/proof-paths
- en enkel payment/ticket helper for billett-bevis og kvittering
- en delegasjons/helper for nar brukeren maa faa tilgang til et keypath i egen identity eller side-cell

### Akseptansekriterier
- Et `connect.challenge` med `requiredAction=review_agreement` skal kunne aapne workbench direkte.
- Minst ett VC/proof-scenario og ett payment-scenario skal ha eksplisitt helper-konfig.

## Fase 5 - Bruk `Condition.resolve(context:)` som faktisk remedieringshook

### Maal
Gi conditions en standardisert krok for aa klargjore auto-remediering eller helper-oppsett.

### Endringer
- Definer tydelig ansvarsdeling:
  - `isMet/evaluate` svarer pa om vilkaret er oppfylt
  - `resolve` brukes til aa forberede remediering eller hente hjelpekonfig
- `resolve` skal ikke kunne gi access direkte.
- For `canAutoResolve == true` kan runtime prove:
  - refresh av bevis
  - lookup av ny state
  - hente oppdaterte grants
- Hvis auto-resolve ikke lykkes innen samme session, skal runtime falle tilbake til brukerhandling.

### Filer
- `Sources/CellBase/Agreement/Condition/Condition.swift`
- `Sources/CellBase/Agreement/Condition/Implementation/*.swift`
- `Sources/CellBase/Cells/GeneralCell/GeneralCell.swift`

### Akseptansekriterier
- Minst en condition-type bruker `resolve(context:)` men krever fortsatt ny `evaluate(...)` for aa gaa til `met`.
- Auto-resolve kan ikke omgaa vanlig agreement-signering.

## Fase 6 - Persistens, audit og agreement history

### Maal
Nar tilgang blir gitt, skal vi kunne forklare hvorfor.

### Endringer
- Signed agreement records maa inneholde:
  - final agreement payload
  - declared purpose
  - evidence refs
  - condition outcomes
  - source/target identities
  - session id
  - signed/updated timestamps
- `EntityRepresentation.agreementRefs` skal fortsatt vaere lettvekts-index.
- Full historikk skal ligge i signed-agreement records.

### Filer
- `Sources/CellBase/Agreement/SignedAgreementEntity.swift`
- `CellScaffold/Sources/App/Cells/AgreementWorkbench/AgreementWorkbenchCell.swift`
- `CellScaffold/Sources/App/Cells/EntityStudio/EntityStudioCell.swift`

### Akseptansekriterier
- En gitt access kan spores tilbake til agreement, evidence og conditions som ble oppfylt.
- `EntityStudio` kan vise signed records uten aa miste forklaringskontekst.

## Fase 7 - Teststrategi

### Kjernetester
- `GeneralCellInterfaceTests`
  - `signContract` med unmet lookup condition
  - `signContract` med helper-backed challenge
  - retry av admission session etter brukerhandling
- nye tester for `LookupCondition`, `GrantCondition`, `ProvedClaimCondition`
- serialiseringstester for utvidet `Agreement`

### Scaffold-tester
- `AgreementWorkbench` kan motta prefill fra challenge/session
- `AgreementWorkbench` kan sende retry for en konkret session
- `EntityStudio` kan importere signed agreement med evidence og condition outcomes
- minst ett end-to-end scenario:
  - bruker mangler billettbevis
  - challenge opprettes
  - payment/proof helper fullfores
  - retry skjer
  - connection gaar til `connected`

## Anbefalt implementeringsrekkefolge
1. Fase 1 - condition-evaluering
2. Fase 2 - admission sessions
3. Fase 4 - helper wiring til `AgreementWorkbench`
4. Fase 3 - utvidet agreement-modell
5. Fase 5 - faktisk remedieringshook
6. Fase 6 - persistens og audit
7. Fase 7 - full end-to-end testdekning

Denne rekkefolgen gir raskest vei til et brukerfungerende lop uten at vi maa loese hele den normative agreement-modellen i samme patch.

## Minimum viable slice
Hvis vi vil komme raskt til en demonstrerbar versjon, bor neste arbeidsstykke vaere:
- fiks `LookupCondition` til deterministisk async evaluering
- innfor `AdmissionSession` + `sessionId` i `connect.challenge`
- la `review_agreement` aapne `AgreementWorkbench`
- la workbench retry samme admission session

Det er den minste pakken som gjor dagens prototype om til et faktisk brukerforlop.
