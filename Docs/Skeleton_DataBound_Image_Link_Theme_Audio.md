# Skeleton: bilde, lenke og temafarger fra data, og lyd

Lagt til for PDD «kunstnerside som flate» (26.10.2026, godkjent av Kjetil: C, D, E og F). Målet er at kunstnersider, Butterpop Kollektivet og den generelle sidebyggeren kan lages som CellConfiguration + skeleton i stedet for egen HTML.

Alle feltene er valgfrie. En konfigurasjon uten dem rendres som før. Eldre renderere som ikke kjenner `Audio`, viser elementet som `Unsupported` i stedet for å feile.

## C. Bilde fra data

```json
{"Image": {"urlKeypath": "media.preview", "altKeypath": "title", "alt": "Bilde mangler"}}
```

- `urlKeypath` leses på raden (inne i en `Grid`/`List` med `itemSkeleton`) eller på roten. Punktum gir nøstede felt.
- Når `urlKeypath` er satt, brukes ikke den faste `url`. En rad uten verdi viser bilde-mangler-tilstanden, aldri en tom ramme.
- Bildet åpnes bare etter samme regler som lenker: https, eller samme opphav når adressen er relativ.

## D. Hele elementet som lenke

```json
{"VStack": {"elements": [...], "modifiers": {"linkURLKeypath": "link", "linkURL": "/pub/sindre-hustveit/verk"}}}
```

- `modifiers.linkURLKeypath` (fra raden) vinner over `modifiers.linkURL` (fast).
- Hele elementet blir én lenke med tastaturfokus. Lenken åpnes etter samme regler som lenkeknapper (`SkeletonButtonNavigation`).
- Revisjonen (`SkeletonReachabilityAudit`) melder `nestedLink` når en lenke ligger inni en elementlenke, fordi nettlesere ikke kan nøste lenker.

## E. Temafarger fra data

```json
{"modifiers": {"styleVariables": {"accent": "#4a4a46"}, "styleVariablesKeypath": "site.theme"}}
```

- Tillatte navn: `accent`, `ink`, `paper`, `line`, `muted`, `surface` (`SkeletonStyleVariables.allowedNames`). Ikke fri CSS.
- Verdier må være `#RRGGBB` eller `#RRGGBBAA`. Feil navn eller farge i selve konfigurasjonen er en formatfeil. Feil i data hoppes stille over.
- Data vinner over faste verdier, så eierens valg overstyrer malen.
- Web setter `--haven-<navn>` på elementet. Native bruker dem ikke ennå (egen runde).

## F. Lyd

```json
{"Audio": {"srcKeypath": "track.src", "titleKeypath": "track.title", "mimeType": "audio/mpeg"}}
```

- Krever `src` eller `srcKeypath`. Uten kilde blir elementet `Unsupported` og meldes av revisjonen.
- Elementet sier bare hva som skal spilles. Levering, tilgang og låtpolicy ligger i musikkcellene som serverer adressen.
- Web spiller én låt om gangen per flate, med spill, pause og spoling. Native har spill og pause i første runde. Begge viser en synlig tilstand når lyden mangler.

## Nedstrøms

`SkeletonElement` har fått casen `.Audio`. Kode i andre repoer som gjør en uttømmende `switch` over `SkeletonElement` må legge til én linje når de oppdaterer CellProtocol.

## H og I. Spillerkø med spillerlinje (Butterpop steg 2)

Godkjent av Kjetil 30.10.2026 (G1: «Ja til G1», G, H og I) og 31.10.2026 (G2).

```json
{"AudioQueue": {"currentKeypath": "player.current", "endedActionKeypath": "track.playedThrough", "label": "Spiller"}}
{"Button": {"keypath": "", "label": "Spill sang", "playQueueKeypath": "freeQueue", "playQueueStartKeypath": "id", "playingLabel": "Spiller"}}
{"Button": {"keypath": "", "label": "Spill album", "playQueueKeypath": "queue", "playingLabel": "Spiller"}}
```

- `AudioQueue` er spilleren. Det er én per flate, og den viser en spillerlinje nederst med tittel, pause, spoling, gjenta og lukk.
- En `Button` med `playQueueKeypath` sender ingen handling. Den gir spilleren lista på nøkkelstien og starter den. Med `playQueueStartKeypath` starter lista på knappens egen sang, ellers øverst.
- Mens knappens sang spiller, eller spilleren spiller nøyaktig knappens liste, viser knappen `playingLabel`. Det gir «Spiller»-merket.
- En sang er et objekt med `id` og `src`, og eventuelt `title`, `mode`, `detail` og `coverURL`. Sanger uten `src` hoppes over, så en betalt sang kommer aldri i køen.
- `currentKeypath` (I): når objektet der får en ny `playID`, spiller spilleren den sangen. Serveren svarer slik når betalingsporten har godkjent et kjøp.
- `endedActionKeypath` (I): når en sang er spilt ferdig, sendes handlingen med `{"id": <sang>}`. Uten vert, som i en åpen visning, sendes ingenting.
- `src` åpnes etter samme regler som lenker.
- `playQueueStartKeypath` og `playingLabel` uten `playQueueKeypath` er en formatfeil. Det samme er en tom `currentKeypath` eller `endedActionKeypath`.
- Native viser ikke spilleren ennå. Køknapper sender ingenting der. Det tas i en egen Binding-runde.

`SkeletonElement` har fått casen `.AudioQueue`. Kode med uttømmende `switch` over `SkeletonElement` må legge til én linje.
