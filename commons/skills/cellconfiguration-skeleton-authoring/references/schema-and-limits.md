# Schema And Limits

Dette dokumentet er laget for modeller som skal generere eller redigere
`CellConfiguration`.

Bruk kode som sannhetskilde:

- `Sources/CellBase/CellConfiguration/CellConfiguration.swift`
- `Sources/CellBase/Skeleton/SkeletonDescription.swift`
- `Tests/CellBaseTests/SkeletonTests.swift`

## Top-level `CellConfiguration`

Støttede toppfelter er:

- `uuid`
- `name`
- `description`
- `discovery`
- `cellReferences`
- `skeleton`

`discovery` støtter:

- `sourceCellEndpoint`
- `sourceCellName`
- `purpose`
- `purposeDescription`
- `interests`
- `menuSlots`

`cellReferences` støtter:

- `endpoint`
- `subscribeFeed`
- `label`
- `subscriptions`
- `setKeysAndValues`

## Supported Skeleton Elements

Dette er de faktiske `SkeletonElement`-casene som finnes i koden nå:

- `Text`
- `TextField`
- `TextArea`
- `Image`
- `Spacer`
- `HStack`
- `VStack`
- `ZStack`
- `List`
- `Object`
- `Reference`
- `Button`
- `Divider`
- `ScrollView`
- `Section`
- `Grid`
- `Toggle`
- `Picker`
- `FileUpload`
- `AttachmentField` (legacy alias for upload/attachment surfaces)

Alt annet skal behandles som ikke støttet før det er verifisert i kode.

### `FileUpload`

Støtter:

- `title` / `label`
- `helperText`
- `valueKeypath` / `sourceKeypath`
- `stateKeypath`
- `actionKeypath` / `targetKeypath`
- `acceptedContentTypes` / `accept`
- `allowsMultiple` / `multiple`
- `supportsDrop`
- `maxSizeBytes`
- `uploadMode` (`metadata`, `base64`, `chunked`)
- `submitOnSelection`
- `modifiers`

Viktig:

- Renderer sender bare en kortlivet payload til mål-cellen.
- Mål-cellen må validere type/størrelse og bestemme lagring.
- Web/Porthole sender metadata + base64/chunks etter `uploadMode`.
- Apple-renderer bruker native file picker og drag/drop der plattformen støtter det.

## Important Element Notes

### `Text`

Støtter:

- `text`
- `url`
- `keypath`
- `modifiers`

Viktig:

- `Text` er display-orientert.
- `Text` kan hente innhold via `url` eller `keypath`.
- `Text` er ikke en redigerbar teksteditor.

### `TextField`

Støtter:

- `text`
- `sourceKeypath`
- `targetKeypath`
- `placeholder`
- `modifiers`

Viktig:

- brukes for enkel input/binding
- ikke lov å anta avansert editoroppførsel

### `TextArea`

Støtter:

- `text`
- `sourceKeypath`
- `targetKeypath`
- `placeholder`
- `minLines`
- `maxLines`
- `submitOnEnter`
- `editorMode`
- `modifiers`

`editorMode` støtter:

- `plain`
- `richMarkdown`

Viktig:

- Swift-rendereren støtter `submitOnEnter`
- meta/ctrl-enter-distinksjon er dokumentert som gap
- ikke lov å love full rich text-editor eller komplett markdown-editor utover
  dagens implementasjon

### `Image`

Støtter:

- `url`
- `name`
- `type`
- `resizable`
- `scaledToFit`
- `padding`
- `modifiers`

### `List`

Støtter blant annet:

- `topic`
- `keypath`
- `filterTypes`
- `elements`
- `flowElementSkeleton`
- `selectionMode`
- `selectionValueKeypath`
- `selectionStateKeypath`
- `selectionActionKeypath`
- `activationActionKeypath`
- `selectionPayloadMode`
- `allowsEmptySelection`
- `modifiers`

Viktig:

- `flowElementSkeleton` er forventet som en `VStack`
- selection-felter har valideringsregler
- ikke lov å finne opp andre selection payload-modes enn de som finnes i koden

Støttede selection-modes:

- `none`
- `single`
- `multiple`

Støttede payload-modes:

- `item`
- `item_id`
- `selected_items`
- `selected_ids`

### `Object`

Støtter:

- `elements`
- `modifiers`

Viktig:

- brukes for nøkkel/element-komposisjon
- wrapper-formen er `{ "Object": { "elements": ... } }`
- legacy unwrapped decode finnes, men bruk wrapper-form ved ny authoring

### `Reference`

Støtter:

- `keypath`
- `topic`
- `filterTypes`
- `flowElementSkeleton`
- `scaledToFit`
- `padding`
- `modifiers`

### `Button`

Støtter:

- `keypath`
- `label`
- `url`
- `payload`
- `modifiers`

Viktig:

- knappen bruker runtime-oppførsel, ikke bare schema
- ikke lov å anta avansert action-semantikk utover keypath/url/payload

### `Grid`

Støtter:

- `columns`
- `spacing`
- `keypath`
- `itemSkeleton`
- `elements`
- `modifiers`

Kolonner støtter:

- `fixed`
- `flexible`
- `adaptive`

### `Toggle`

Støtter:

- `label`
- `keypath`
- `isOn`
- `modifiers`

### `Picker`

Støtter:

- `label`
- `placeholder`
- `elements`
- `keypath`
- `optionLabelKeypath`
- `selectionValueKeypath`
- `selectionStateKeypath`
- `selectionActionKeypath`
- `selectionPayloadMode`
- `allowsEmptySelection`
- `modifiers`

## Supported Modifiers

`SkeletonModifiers` støtter blant annet:

- layout: `padding`, `width`, `height`, `maxWidthInfinity`,
  `maxHeightInfinity`, `hAlignment`, `vAlignment`
- surface: `background`, `cornerRadius`, `shadowRadius`, `shadowX`, `shadowY`,
  `shadowColor`, `borderWidth`, `borderColor`, `opacity`, `hidden`
- text: `foregroundColor`, `fontStyle`, `fontSize`, `fontWeight`, `lineLimit`,
  `multilineTextAlignment`, `minimumScaleFactor`
- metadata: `styleRole`, `styleClasses`

Viktig:

- `styleRole` og `styleClasses` er ikke full CSS eller full theme-engine
- bruk dem som metadata, ikke som garanti for ferdig styling

## Canonical Authoring Guidance

Ved ny authoring:

- bruk canonical wrapper keys
- bruk eksplisitte og eksisterende felt
- hold JSON minimal
- ikke legg inn felt som ikke finnes i `Codable`-modellene
- ikke anta at decode av legacy-shapes betyr at de bør genereres på nytt

## Practical Composition Guidance

Når ønsket er aa finne, sette sammen og vise data fra celler:

- bruk `cellReferences` til aa koble inn celler som konfigurasjonen avhenger av
- bruk tydelige `label`s paa referansene
- bruk `keypath`/`sourceKeypath`/`targetKeypath` for aa lese og skrive data
- bruk enkel `Text` eller `TextField`/`TextArea` naar du bare trenger direkte
  binding
- bruk `List` naar du viser en samling
- bruk `Reference` naar en feed/topic skal vises gjennom en referanseflate
- bruk `Object` naar du trenger strukturert sammensetning av navngitte felt
- bruk `Grid` kun naar rutelayout faktisk trengs og er enklere enn nested
  stacks

Modellen skal alltid kunne forklare:

- hvilken celle data kommer fra
- hvilket keypath som leses
- hvilket keypath som eventuelt skrives til
- hvorfor valgt skeleton-struktur passer dataformen

## When To Prefer Which Element

- `Text`: enkeltfelt eller enkel avledet tekst
- `TextField`: enkel brukerinput til ett target-keypath
- `TextArea`: lengre input eller editor-lignende flyt innenfor dagens grenser
- `List`: liste over `ValueType`-elementer, gjerne med `flowElementSkeleton`
- `Reference`: feed/topic-basert visning
- `Object`: navngitt sammensatt blokk
- `VStack`/`HStack`/`ZStack`: layoutkomposisjon
- `Section`/`ScrollView`: struktur og scroll
- `Grid`: kort- eller matrisevisning
- `Toggle`/`Picker`: enkel kontrollflate mot tilstand eller valg

## Known Limits And Gaps

Dette skal rapporteres tydelig til brukeren hvis det etterspørres:

- ingen generisk CSS-/class-style engine i SwiftUI-rendereren
- `Text` er ikke en redigerbar editor-node
- `TextArea` har ikke full meta/ctrl-enter-paritet dokumentert i Swift
- filopplasting er beskrevet som plan, ikke som aktivt skeleton-element
- ikke støttede elementer skal ikke improviseres

## Hard Stop Conditions

Stopp og si fra til Kjetil før implementering hvis ønsket krever:

- ny skeleton-elementtype
- ny renderer-semantikk
- ny stylingmotor
- filopplasting/media/embed utover det som faktisk finnes i enumen
- andre nye capabilities som ikke allerede er kodet
