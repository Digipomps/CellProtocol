# Cross-Repo Stability Dispatch Note

Denne noten er den korte operative versjonen av stabiliseringsarbeidet for:

- `CellProtocol`
- `CellScaffold`
- `Binding`

Målet er aa holde tydelige eierskap, unngaa kryssende arbeid, og sikre at
`Binding` ender opp som robust og superstabil uten at `CellScaffold` eller
`CellProtocol` blir dratt ut av rolle.

## Anbefalt kjorerekkefolge

1. `CellProtocol` maa vaere stabilt og dokumentert for delte kontrakter.
2. `CellScaffold` maa hardne kontrollplan og parity-fixtures.
3. `Binding` maa deretter konsumere disse flatene og fikse host-stabilitet.
4. Til slutt maa parity og kompatibilitet verifiseres pa tvers.

## Hva maa vaere ferdig for neste repo kan starte

### For at `CellScaffold` skal gaa videre

`CellProtocol` maa ha:

- stabile admission- og katalogkontrakter
- dokumentasjon som beskriver shape, invariants og migrasjonsretning
- tester som viser at dagens payloads fortsatt dekodes riktig

`CellScaffold` skal stoppe og eskalere hvis:

- det maa finne opp lokale kontraktshapes som egentlig er protokollfelles
- admission- eller katalogpayload maa endres ikke-additivt

### For at `Binding` skal gaa videre

`CellScaffold` maa ha:

- stabile parity-fixtures med deterministiske payloads og identifikatorer
- tydelig kontrollplan for bootstrap, same-entity linking og role-grant-grense
- tydelig beskjed om hva som fortsatt er conference-eid

`Binding` skal stoppe og eskalere hvis:

- scaffold truth er uklar og maa erstattes med lokal Binding-logikk
- parity bare kan passere med produktspesifikke hacks
- cache begynner aa fungere som lokal autoritet i stedet for recovery-lag

## Praktisk gjennomforing

### `CellProtocol`

Ferdig betyr:

- delte kontrakter er additive og dokumenterte
- kontraktstestene er gronne
- repoet er referansepunktet for hva admission og katalog faktisk betyr

### `CellScaffold`

Ferdig betyr:

- `ScaffoldSetupCell` er hardnet som kontrollplanflate
- parity-fixtures er scaffold-eide og deterministiske
- notification-seams er gjenbrukbare uten aa bli produktforkledd generisk lag
- eksisterende conference-ruter oppforer seg som for

### `Binding`

Ferdig betyr:

- `ConfigurationCatalog`-absorbering er fikset uten adgangs-workarounds
- typed admission handling er konsistent
- portable cache er kontraktstro og ikke autoritativ
- actor-isolation / Swift-6-fragilitet er ryddet i nye seams
- parity brukes som reell gate

## Endelig gate for hele trancheringen

Trancheringen er ikke ferdig for alle tre repoene foer dette holder samtidig:

- `CellProtocol` kontrakter og docs er stabile
- `CellScaffold` parity-fixtures er stabile
- `Binding` konsumerer disse flatene uten aa omskrive dem
- same-entity link-flow er fortsatt atskilt fra role/access grant-flow
- parity og relevante tester er gronne

## Kort dispatch-beskjed

Kjor i denne rekkefolgen: `CellProtocol` ferdigstilles som kontraktgrunnlag,
`CellScaffold` hardner kontrollplan og parity-fixtures, og `Binding` tar
stabiliseringspasset etterpaa. Ingen repo skal kompensere for uklarhet i et
lavere lag ved aa finne opp egne sannheter. Hvis det skjer, stopp og push
problemet ned til riktig eierlag.
