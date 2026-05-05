# Skeleton Renderer Null-Gap Iterasjon (2026-02-19)

## Mål
- Bytte aktiv render-path i CellProtocol til kun `SkeletonView`.
- Portere nødvendig funksjonalitet fra gammel `SkeletonElementView` for å unngå regresjoner.
- Redusere gap mot web-rendereren (`CellScaffold/Public/js/skeleton-runtime.js`).
- Dokumentere hva som bevisst ikke er tatt med, med kode og begrunnelse.
- Lage plan for nytt filopplastings-element som persisterer i celler.

## Iterasjoner

### Iterasjon 1: Migrer aktive kallsteder til `SkeletonView`
- `PortholeView` rendrer nå med `SkeletonView`.
- `CellListView` og `CellReferenceView` rendrer rekursivt med `SkeletonView`.
- `TestCellSkeletonView` bruker `SkeletonView`.
- `SkeletonElementView` er markert som deprecated (ikke lenger aktiv path).

Konsekvens:
- Vi har én aktiv renderer i SwiftUI-ruten, som reduserer drift i feature-set og bugs.

### Iterasjon 2: Portering fra gammel renderer
- Button-overstyring fra `userInfoValue` (`url`, `keypath`, `payload`, `label`) er flyttet inn i `SkeletonView`.
- `Text` rendres nå via `CellTextView` som bruker `SkeletonText.asyncContent(userInfoValue:)`.
- `Object` rendres rekursivt med nøkkel/verdi-visning i stedet for hardkodet `"Object"`.
- Debug-UI/print-støy i list/reference er fjernet.

Konsekvens:
- Funksjonalitet som ble brukt i flow-row-context (spesielt knapper) er bevart.

### Iterasjon 3: Prioriterte web-gap i Swift renderer
- `styleRole`/`styleClasses` konsumeres nå i Swift som metadata via `accessibilityIdentifier` i `applySkeletonModifiers`.
- `TextField` støtter submit på Enter (`onSubmit`) med dispatch via `SkeletonButton.execute`.
- `TextArea.submitOnEnter` støttes (plain Enter) med dispatch via `SkeletonButton.execute`.

Konsekvens:
- Swift renderer nærmer seg web-semantikk for submit-oppførsel og stilmetadata.

## Bevisste utelatelser (med kode)

### 1) Redigerbar `TextEditor` + `AppStorage` per element (ikke videreført)
Gammel kode:

```swift
TextEditor(text: $persistedText)
    .task {
        if persistedText == "..." {
            let content = await cellText.asyncContent(userInfoValue: userInfoValue)
            if !content.isEmpty { persistedText = content }
        }
    }
```

Hvorfor ikke med:
- Web-rendereren har ikke redigerbar `Text`-node; den er en display-node.
- For null-gap mot web er `Text` nå read-only, med dynamisk innhold via `asyncContent`.

### 2) `AppStorage`-persistens for button response binding (ikke videreført)
Gammel kode:

```swift
@AppStorage("__placeholder_value__") private var persistedValueString: String = "__nil__"
private var valueTypeBinding: Binding<ValueType?> { ... }
CellButtonView(skeletonButton: skeletonButton, userInfoValue: userInfoValue, responseValue: valueTypeBinding)
```

Hvorfor ikke med:
- Ny renderer bruker `viewModel.cache` og target-keypath submit-flyt (samme retning som web runtime action-dispatch).
- Lokalt AppStorage-lag per view ga state-lekkasje mellom visninger og var vanskeligere å holde deterministisk.

### 3) Full CSS-lignende klasse-styling i SwiftUI (delvis)
Gjort nå:
- `styleRole`/`styleClasses` lagres som metadata i accessibility identifier.

Ikke gjort nå:
- Ingen generisk SwiftUI “style sheet” som oversetter klassestrenger til visuell stil.

Hvorfor:
- SwiftUI har ikke innebygd klasse/CSS-modell; full parity krever et eget style registry med tydelig scope.

## Nåværende gap mot web renderer

1. `TextArea` meta/ctrl-enter-distinksjon.
- Web støtter Meta/Ctrl+Enter-spesifikk flyt; SwiftUI `TextEditor` gir begrenset key-event-kontroll uten wrapper.

2. List-binding signatur-optimalisering.
- Web har eksplisitt signature-basert diff for list rows.
- Swift bruker SwiftUI diffing + data fra viewmodel/list-kilder.

3. Objekt-fallback-format.
- Web fallback viser JSON (`pre`).
- Swift viser strukturert key/value når `SkeletonObject` finnes.

## Plan for nytt element: Filopplasting

## Prinsipp
- Ingen lagring utenfor celler.
- Renderer holder kun kortlivet data (i minne), og sender payload til mål-celle via keypath.
- Mål-cellen bestemmer endelig lagringsstrategi (rå fil, chunket blob, database, etc.) basert på egne rettigheter.

## Forslag til Skeleton-spec

```swift
public struct SkeletonFileUpload: Codable, Identifiable {
    public var id = UUID()
    public var label: String?
    public var accept: [String]?            // MIME/UTType hints
    public var multiple: Bool?
    public var maxSizeBytes: Int?
    public var sourceKeypath: String?       // valgfri lesekilde
    public var targetKeypath: String?       // submit-destinasjon
    public var uploadMode: String?          // raw | base64 | chunked
    public var submitOnSelection: Bool?
    public var modifiers: SkeletonModifiers?
}
```

`SkeletonElement` utvides med:

```swift
case FileUpload(SkeletonFileUpload)
```

## Web renderer plan
- Render `<input type="file">` (+ ev. multiple).
- Les fil(er) i minne (`ArrayBuffer`), konverter etter `uploadMode`.
- Dispatch action til `targetKeypath` med payload:
  - filnavn, mime, size
  - data (raw/base64) eller chunk-metadata.

## SwiftUI renderer plan
- Bruk `fileImporter` for plattformnær filvelger.
- Les fil bytes i minne (`Data`) og form payload tilsvarende web.
- Dispatch til `targetKeypath` med samme kontrakt.

## Persistenskontrakt
- Renderer sender kun payload til cell.
- Mål-celle må selv:
  - validere type/størrelse,
  - velge lagring (intern DB/blob/chunks),
  - returnere referanse/kvittering på keypath.

## Testplan (filopplasting)
1. Enkeltfil, liten størrelse, `submitOnSelection=true`.
2. Avvisning over `maxSizeBytes`.
3. `multiple=true` med blandede MIME-typer.
4. Chunked payload gjenoppbygges i mål-celle.
5. Reconnect/retry uten lokal diskpersistens i renderer.

## Verifikasjon utført i denne iterasjonen
- `swift build` i `CellProtocol`: OK.
- `swift test --filter SkeletonTests`: 11/11 passerte.
