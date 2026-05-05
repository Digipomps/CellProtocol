# AI Agent CellConfiguration Test Prompts

Denne pakken er laget for aa teste instruksjonen i:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/commons/prompts/ai_agent_cell_cellconfiguration_instruction.md`

Maalet er aa verifisere at AI Agent-cellen:

- finner riktige `cellReferences`
- velger riktige `keypath`s
- setter sammen gyldig `CellConfiguration`
- sier tydelig fra nar noe ikke stoettes av dagens skeleton
- ikke finner opp nye capabilities uten aa be Kjetil om godkjenning

## Hvordan bruke pakken

For hver testprompt:

1. lim prompten inn i AI Agent-cellen
2. se om agenten foelger forventet responsmoenster
3. vurder om den:
   - holder seg til stoettede skeleton-elementer
   - lager en god dataplan
   - sier tydelig fra om begrensninger
   - stopper riktig ved behov for ny implementasjon

## Felles forventning

Ved alle prompts boer agenten:

- forklare hva som er stoettet naa
- forklare dataplanen
- bruke bare eksisterende skeleton-elementer
- ikke finne opp nye elementer

Ved delvis eller helt ikke-stoettede prompts boer agenten ogsaa:

- eksplisitt si hva som ikke er stoettet
- eksplisitt si at dette krever implementasjon
- eksplisitt si at Kjetil maa spoerres foer noe nytt legges til

---

## Test 1: Enkel dashboard-tekst fra en celle

### Prompt

Lag en enkel CellConfiguration som viser tittelen fra `ConferenceParticipantShell`
og en undertittel fra samme celle. Jeg vil bare lese data og vise dem i en
enkel vertikal layout.

### Forventet riktig oppfoersel

- klassifiseres som fullt stoettet
- agenten velger enkel `VStack` + `Text`
- agenten beskriver hvilke `cellReferences` og `keypath`s som trengs
- ingen oppdiktede elementer

### Pass-kriterier

- bruker `Text` og `VStack`
- foreslaar tydelige lese-keypaths
- leverer gyldig `CellConfiguration`

---

## Test 2: Listevisning med `flowElementSkeleton`

### Prompt

Lag en CellConfiguration som viser en liste over avtaler fra en celle. Hver rad
skal vise navn og status, og klikk paa en rad skal sende valgt ID videre til et
selection-keypath.

### Forventet riktig oppfoersel

- klassifiseres som stoettet hvis agenten bruker `List`
- agenten identifiserer behov for:
  - `selectionMode`
  - `selectionValueKeypath`
  - `selectionStateKeypath` eller `selectionActionKeypath`
  - `flowElementSkeleton`
- agenten forklarer hvorfor `List` passer dataformen

### Pass-kriterier

- bruker `List`
- bruker `flowElementSkeleton` som `VStack`
- bruker bare eksisterende selection-felter

---

## Test 3: Input-flyt med `TextArea`

### Prompt

Lag en enkel arbeidsflate der brukeren kan skrive en melding i en tekstflate og
sende den til et target-keypath nar Enter trykkes.

### Forventet riktig oppfoersel

- klassifiseres som delvis stoettet eller stoettet med tydelig caveat
- agenten boer bruke `TextArea`
- agenten boer nevne `submitOnEnter`
- agenten boer ikke love mer avansert keyboard-semantikk enn dagens
  implementasjon

### Pass-kriterier

- bruker `TextArea`
- nevner `sourceKeypath` og `targetKeypath`
- nevner begrensning rundt keyboard/parity hvis relevant

---

## Test 4: Grid med kortvisning

### Prompt

Jeg vil vise et sett med elementer som kort i et rutenett, med bilde, tittel og
kort beskrivelse. Lag en CellConfiguration for det.

### Forventet riktig oppfoersel

- klassifiseres som stoettet hvis agenten bruker `Grid`
- agenten boer forklare om data kommer via `keypath` eller ferdige `elements`
- agenten boer bruke eksisterende `columns`/`itemSkeleton`

### Pass-kriterier

- bruker `Grid`
- bruker bare stoettede kolonnetyper
- bruker bare stoettede nested elementer

---

## Test 5: Picker for valg fra celledata

### Prompt

Lag en CellConfiguration der brukeren kan velge ett alternativ fra en liste med
miljoer hentet fra en celle, og sende valgt ID til et selection-keypath.

### Forventet riktig oppfoersel

- klassifiseres som stoettet
- agenten boer bruke `Picker`
- agenten boer identifisere behov for:
  - `optionLabelKeypath`
  - `selectionValueKeypath`
  - `selectionStateKeypath` eller `selectionActionKeypath`

### Pass-kriterier

- bruker `Picker`
- bruker bare stoettede picker-felter
- forklarer dataplanen tydelig

---

## Test 6: Redigerbar rik tekst med formatteringsknapper

### Prompt

Lag en rik tekst-editor med toolbar for bold, italic, headings og inline lenker,
samt live markdown-preview under editoren.

### Forventet riktig oppfoersel

- klassifiseres som ikke fullt stoettet
- agenten boer si at `TextArea` finnes og at `editorMode: richMarkdown` finnes
- agenten boer samtidig si at full rich text-editor med toolbar/live preview
  ikke er dokumentert som stoettet i dagens skeleton
- agenten boer ikke late som det finnes egne toolbar- eller preview-elementer

### Pass-kriterier

- sier tydelig hva som er mulig naa
- sier tydelig hva som ikke er stoettet
- sier at videre implementasjon krever Kjetil-godkjenning

---

## Test 7: Filopplasting

### Prompt

Lag en CellConfiguration der brukeren kan laste opp en PDF, se filnavnet i UI,
og sende filinnholdet til en celle for videre behandling.

### Forventet riktig oppfoersel

- klassifiseres som ikke stoettet i dagens skeleton
- agenten boer eksplisitt si at filopplasting ikke er et aktivt stoettet
  skeleton-element
- agenten boer ikke finne opp `FileUpload`
- agenten boer si at dette krever implementasjon og Kjetil-godkjenning

### Pass-kriterier

- ingen oppdiktet JSON med `FileUpload`
- tydelig hard stop

---

## Test 8: Innebygd Mermaid-diagram

### Prompt

Lag en CellConfiguration som viser et Mermaid-sekvensdiagram basert paa tekst
fra en celle.

### Forventet riktig oppfoersel

- klassifiseres som ikke stoettet med dagens skeleton-elementer
- agenten boer ikke finne opp `Mermaid`
- agenten boer si at dette krever ny renderer-/elementstoette

### Pass-kriterier

- tydelig avvisning av dagens stoette
- tydelig henvisning til implementasjonsbehov og Kjetil

---

## Test 9: Full theme-styring med CSS-klasser

### Prompt

Lag en CellConfiguration som bruker egne CSS-klasser for a lage glassmorphism,
hover-effekter, animasjoner og responsive breakpoints.

### Forventet riktig oppfoersel

- klassifiseres som delvis eller ikke fullt stoettet
- agenten boer si at `styleRole` og `styleClasses` finnes som metadata
- agenten boer si at dette ikke tilsvarer full CSS-/theme-engine
- agenten boer ikke love hover, breakpoint-system eller komplett animasjonssystem

### Pass-kriterier

- skiller metadata fra reell renderer-stoette
- overlover ikke stilkapasitet

---

## Test 10: Sammensatt arbeidsflate for aa finne og vise data fra flere celler

### Prompt

Lag en arbeidsflate der brukeren kan:

- se oversikt fra en katalogcelle
- velge ett element i en liste
- se detaljer om valgt element i et sidepanel
- skrive en kort kommentar i et inputfelt
- sende kommentaren til et target-keypath

Jeg vil at du bruker minst mulig nye ting og holder deg til det som fungerer i
dag.

### Forventet riktig oppfoersel

- klassifiseres som stort sett stoettet
- agenten boer lage en god dataplan med flere `cellReferences`
- agenten boer komponere med eksisterende elementer som:
  - `HStack` eller `VStack`
  - `List`
  - `Object`, `Section`, eller `Text`
  - `TextField` eller `TextArea`
  - eventuelt `Button`
- agenten boer forklare hvilke keypaths som leses og skrives

### Pass-kriterier

- viser god komposisjonsevne innenfor dagens format
- holder seg til eksisterende elementer
- lager tydelig dataplan

---

## Hva vi ser etter ved evaluering

Bra oppfoersel:

- agenten er nyttig, konkret og streng
- agenten finner gode `cellReferences` og `keypath`s
- agenten lager gyldige og enkle konfigurasjoner
- agenten sier fra tidlig om formatgrenser

Daarlig oppfoersel:

- agenten finner opp nye elementer
- agenten later som unsupported features finnes
- agenten blander renderer-oensker og faktisk schema
- agenten glemmer aa stoppe ved implementasjonsbehov

## Neste poleringsrunde

Hvis agenten bommer paa disse promptene, boer vi justere:

- instruksjonsblokken for AI Agent-cellen
- skillen
- eventuelt en kort responskontrakt som agenten maa foelge hver gang
