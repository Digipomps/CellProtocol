# Codex-handoff: Siri AI fase 0 (måling før bygging)

Kontekst: `CellProtocol/Docs/SiriAI_HAVEN_Nytteverdi_og_Implementeringsplan_NO.md`
§6 fase 0 og `CellProtocol/Docs/SiriAI_Developer_Preview_Funn_2026-11-04.md`.

G1 ble godkjent 2026-11-04 og fase 1 er implementert i CellProtocol
(`Docs/Assistant_Exposure_Contract.md`). Slicene under er fortsatt egne
beslutninger; i tillegg kommer **Slice D** som verifiserer fase 1 lokalt.

Status for slicene (bare Kjetil endrer status):

- Slice A (WP0.1 enhetsmåling): **blocked** — venter på Kjetils ord
- Slice B (WP0.2 Apple-eksempel med `@AppIntent(.tool)`): **blocked** — venter på Kjetils ord
- Slice C (WP0.3 Foundation Models-baseline for `AppleIntelligenceCell`): **blocked** — venter på Kjetils ord
- Slice D (fase 1 verifisering, `swift test --filter Assistant`): **blocked** — venter på Kjetils ord

Regler: utfør bare slices merket **godkjent**. Ingen git gjennom mount. Ikke rør
andre filer enn de som er nevnt. Skriv rå output til evidensfiler; ikke
oppsummer i stedet for å lagre.

## Slice A — Enhetsmåling (Kjetil + Codex)

Mål: avgjøre om Siri AI Developer Preview er tilgjengelig på Kjetils enheter.

1. Bekreft Xcode 27.3-beta og OS 27.3-beta på Mac og én iPhone/iPad. Skriv
   versjoner til `HAVEN-Deploy/_handoff/SIRI-AI/maal/ENHET-MAALING.md`.
2. For hver kombinasjon (macOS/iOS) × (språk: engelsk, norsk) × (region: Norge):
   noter om Innstillinger viser Apple Intelligence aktiv, om Siri AI-preview er
   tilgjengelig, og nøyaktig tekst i eventuell avvisning. Skjermbilde per rad.
3. Ikke konkluder «virker ikke i Norge» fra én enhet; skriv hva som ble målt og
   hva som ikke ble målt.

## Slice B — Apple-eksempel (Codex + Xcode)

Mål: bevise at tool-sporet fungerer på enheten før vi bygger vårt.

1. Last ned Apples sample «Integrating your messaging app with Apple
   Intelligence» (UnicornChat) fra developer.apple.com/documentation/appintents.
2. Legg til én `@AppIntent(.tool)` med `title`, `description` og beskrevne
   parametre. Bygg, signer med utviklerprofil, kjør på enheten fra Slice A.
3. Si til Siri: «In UnicornChat, <handlingen>». Noter om tool ble kalt
   (breakpoint i `perform()`), og hva Siri Integration Advisor i Xcode melder.
4. Skriv én `SiriScenario` i et UI-testtarget og kjør den tre ganger. Lagre
   Xcode-rapporten og `intentsAllPass` per kjøring i
   `HAVEN-Deploy/_handoff/SIRI-AI/maal/APPLE-EKSEMPEL.md`.

## Slice C — Foundation Models-baseline (Codex)

Mål: vite hva dagens `AppleIntelligenceCell` gjør på 27.3 før vi endrer den.

1. I `CellProtocol`: `swift test --filter AppleIntelligenceCellContractTests`
   på macOS 27.3. Rå output til
   `HAVEN-Deploy/_handoff/SIRI-AI/maal/FM-BASELINE-swift-test.log`.
2. Fra Binding (eller en liten macOS-kommandolinje som linker CellApple): kall
   `ai.sendPrompt` med `{"prompt": "Lag tre forslag til formål for en dag med
   hjemmekontor", "instructions": "Svar på norsk, kort."}` og `ai.discover`.
   Lagre `ai.outbox` som JSON etter hvert kall. Noter `SystemLanguageModel.default.availability`
   og `PrivateCloudComputeLanguageModel().availability` (forventet utilgjengelig
   uten entitlement; noter nøyaktig grunn).
3. Ikke endre `AppleIntelligenceCell`. Hvis noe feiler, lagre feilen; ikke fiks.

## Verifikasjon som forventes

- Tre evidensfiler finnes under `HAVEN-Deploy/_handoff/SIRI-AI/maal/`.
- Hver måling har dato, enhet, OS-versjon og språk/region.
- Rapporten til Kjetil sier per slice: utført / blocked (grunn) / delvis (hva).

## Slice D — Fase 1 verifisering på Mac (Codex)

Mål: bevise at fase 1 bygger og testene er grønne på et ekte toolchain.

1. I `CellProtocol` på branch `claude/youthful-hawking-sm0c4i`:
   `swift build` og deretter
   `swift test --filter 'AssistantExposureContractTests|AssistantDescriptorTests|AssistantRequesterContractTests|ListsCellTests|VaultCellTests|ExploreContractValidatorTests'`.
   Rå output til `HAVEN-Deploy/_handoff/SIRI-AI/maal/FASE1-swift-test.log`.
2. Hvis golden-fixturene avviker: kjør
   `HAVEN_WRITE_ASSISTANT_FIXTURES=1 swift test --filter AssistantDescriptorTests`,
   legg diffen i loggen og ikke commit den regenererte fixturen uten å si hva som endret seg.
3. Kjør hele `swift test` én gang og noter antall tester og eventuelle nye feil
   mot `origin/main` (bruk `land-cellprotocol.sh <spec>` med `PORTS_ONLY=1` hvis tilgjengelig).
