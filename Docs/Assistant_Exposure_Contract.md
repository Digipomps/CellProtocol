# Assistant Exposure Contract (fase 1 av Siri AI-planen)

Last verified against code: 2026-11-04 (`Sources/CellBase/Assistant/`, branch
`claude/youthful-hawking-sm0c4i`). Plan og formålstre:
`Docs/SiriAI_HAVEN_Nytteverdi_og_Implementeringsplan_NO.md` §5–§6, fase 1.

Dette laget er Apple-fritt og ligger i `CellBase`. Det svarer på ett spørsmål:
**hva av en celle får en assistent se og kalle, og med hvilken identitet?**
Adaptere i `CellApple` (App Intents tool intents, `AppEntity`, Foundation
Models `Tool`) og i Vapor/Porthole leser samme deskriptorer (fase 2 og 3).

## 1. `assistant`-feltet på Explore-kontrakten (WP1.1)

`ExploreContract.Field.assistant` er et additivt, valgfritt objekt på en
nøkkels kontrakt. Kontrakter som ikke setter det, serialiseres nøyaktig som
før (`AssistantExposureContractTests.testContractWithoutAssistantHasNoAssistantField`).

| Felt | Type | Default | Betydning |
|---|---|---|---|
| `exposeAsTool` | bool | false | `set`-nøkkelen kan kalles som verktøy |
| `exposeAsEntity` | bool | false | returverdien (eller samlingen under `entityItemsKey`) beskriver entiteter |
| `entityIDKey` | string | `id` | egenskap med stabil ID per entitet |
| `entityTitleKey` | string | `title` | egenskap med visningstittel |
| `entityItemsKey` | string? | nil | sti i returobjektet der entitetslista ligger |
| `authentication` | `alwaysAllowed` / `requiresAuthentication` / `requiresLocalDeviceAuthentication` | `requiresAuthentication` | hva assistenten må bevise før verdien vises (speiler Apples `IntentAuthenticationPolicy`) |
| `indexable` | bool | false | entitetene kan legges i lokal semantisk indeks; aldri for `consent`-innhold |

Ukjent `authentication` dekodes som «ikke eksponert» (fail closed).

Celler setter feltet gjennom `registerGet(..., assistant:)`,
`registerSet(..., assistant:)` eller `registerExploreContract(..., assistant:)`:

```swift
await registerSet(key: "lists.item.add", owner: owner, input: stringOrObject,
                  returns: resultSchema, permissions: ["-w--"],
                  description: .string("Nytt punkt …"),
                  assistant: .tool(authentication: .requiresAuthentication)) { requester, payload in … }

await registerGet(key: "lists.state", owner: owner, returns: stateSchema, permissions: ["r---"],
                  assistant: .entity(idKey: "id", titleKey: "title", itemsKey: "lists", indexable: true)) { requester in … }
```

Kontraktkatalogen (`exploreContractCatalog`) tagger slike poster med
`assistant.tool`, `assistant.entity` og `assistant.indexable` for RAG/discovery.

## 2. Deskriptorer (WP1.2)

`AssistantDescriptorProjection.project(for: cell, requester:)` (eller
`project(cellType:contracts:)` for ren projeksjon) gir en
`AssistantSurfaceDescriptor` (`haven.assistant.surface.v1`):

- `tools: [AssistantToolDescriptor]` — én per eksponert `set`-nøkkel: `key`,
  `title` (humanisert nøkkel, «Lists item add»), `description` (kontraktens
  `summary`), `permission`, `authentication`, `parameters` (flatet ut fra
  input-skjemaet: én per egenskap for objektskjema, ellers én `value`),
  `inputType`, `returnType`, `flowTopics`, `inputSchema`.
- `entities: [AssistantEntityDescriptor]` — én per eksponert nøkkel med
  `exposeAsEntity`: `typeName`, `idKey`, `titleKey`, `itemsKey`, `properties`
  (fra entitetsskjemaet), `indexable`, `itemSchema`.
- `grants: [AssistantGrantRequirement]` — dedupliserte `(keypath, permission)`
  en requester må ha. Bare eksakte nøkler, aldri eiers områdegrant.

Alt er sortert, så lik input gir lik output byte for byte
(`AssistantDescriptorTests.testProjectionIsDeterministicAndOrderIndependent`).
Golden-fixtures for dagens flater:
`Tests/CellBaseTests/Fixtures/AssistantSurface.ListsCell.v1.json` og
`AssistantSurface.VaultCell.v1.json`. Regenerer etter en bevisst endring med
`HAVEN_WRITE_ASSISTANT_FIXTURES=1 swift test --filter AssistantDescriptorTests`.

## 3. Celler som er opt-in i dag (WP1.3)

| Celle | Verktøy (`-w--`) | Entitet (`r---`) |
|---|---|---|
| `ListsCell` (`cell:///Lists`) | `lists.list.create`, `lists.item.add`, `lists.item.toggle` | `lists.state` → rader i `lists[]` (id, title, kind, isActive, openCount, doneCount, summaryText, selectPayload, mount), indekserbar |
| `VaultCell` (`cell:///Vault`) | `vault.note.create`, `vault.note.list` | `vault.state` → `notes[]` (`VaultNoteRecord`), indekserbar |

Ikke eksponert, med vilje: `lists.item.remove`, `lists.list.remove`,
`lists.list.rename`, `lists.list.clearDone`, `vault.note.update`,
`vault.link.*`, `vault.retention.*`. Sletting og omdøping er bivirkninger
eieren skal starte selv (Apples egen regel for tool intents sier det samme).

En celle som eksponerer en nøkkel **må** også legge nøkkelen i sitt
`agreementTemplate` (`ensureGrant("-w--", for: key)` /
`ensureGrant("r---", for: entityKey)`). Uten det avvises enhver
assistent-admisjon (`testSurfaceOutsideTheTemplateIsRejected`).

Handlerne for eksponerte nøkler sjekker
`validateAccess(_:atKey:orArea:for:)`: eier passerer på områdegranten,
assistenten på det eksakte nøkkelgrantet. Nøkler som ikke er eksponert
sjekker fortsatt bare området, så en assistent når dem aldri.

## 4. Requester-kontrakt og gateway (WP1.4)

**Assistenten er en requester, ikke eieren.** `AssistantRequesterContract`:

- `agreementRequest(for: cell, surface:)` bygger en `Agreement` i
  template-form med nøyaktig `surface.grants`, cellens template-betingelser og
  -policybinding, og varighet ≤ templatens. Tom flate gir `nil`.
- `admit(assistant:to:surface:authorizedBy:)` kjører cellens ordinære
  `addAgreement(_:for:authorizedBy:)`. Eieren signerer; resultatet er en
  vanlig signert `Contract`, revokerbar som alle andre.

`AssistantGateway(cell:surface:)` er det eneste inngangspunktet en adapter skal
kalle:

| Kall | Utfall |
|---|---|
| `invokeTool(key:payload:requester:)` på nøkkel som ikke er verktøy | `.refused(reason: "key_not_exposed_as_tool")`, cellen ser ingenting |
| payload bryter `inputSchema` | `.invalidInput(ExploreValidationReport)`, cellen ser ingenting |
| requester uten gyldig kontrakt | `.denied` |
| ellers | `.response(ValueType?)`, cellens vanlige svar |
| `readEntities(key:requester:)` | tilsvarende for entitetsnøkler |

Hva dette **ikke** er: en autorisasjon. En flate som sier `exposeAsTool` gir
ingen rettigheter; kontrakten gjør det. Eksterne bivirkninger (publisering,
leverandørkall) er fortsatt `PurposeBoundActionIntent`-arbeid i
`proposeOnly`; ingen av dagens eksponerte nøkler har `flowEffects` utenfor
eierens eget lager.

## 5. Tester

| Suite | Dekker |
|---|---|
| `AssistantExposureContractTests` | feltet er fraværende som default, roundtrip, fail closed, overlever registrering, katalog-tags |
| `AssistantDescriptorTests` | golden-fixtures for Lists og Vault, determinisme, tom flate, parameter-flating, humanisering |
| `AssistantRequesterContractTests` | kontrakt = nøyaktig flatens grants; opt-in-nøkkel svarer; ikke-opt-in nøkkel nektes; gateway avviser før cellen; tom/utenfor-template avvises; Vault create/list ok, update nektet |

Alle tre er lagt til Linux-gaten i
`.github/workflows/cellprotocol-swift-linux.yml`, så de kjører uten Apple-rammeverk.
