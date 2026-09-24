# Deling av entitetsdata innenfor en gruppe – sammendrag 24. september 2026

Kort status til andre tråder som jobber med EntityData, konferanse-scaffold, identitet eller avtaler. Full begrunnelse i [OPPDATERT-ETTER-GJENNOMGANG-2026-09-16.md](OPPDATERT-ETTER-GJENNOMGANG-2026-09-16.md) (siste seksjon) og [proposals-2026-09-24.json](proposals-2026-09-24.json). Forslagene er sendt Kjetil og er **ikke** ført inn i skjemaet.

## Scenariet

Person A deltar på konferanse B. A vil dele egen agenda med et utvalg av egne kontakter (undergruppe A, f.eks. kollegaer), men bare med dem som også er deltakere på B, og dessuten med nye relasjoner A får på B underveis.

## Det vi ble enige om

1. **Konferansen er en entitet i As graf.** B er en vanlig post i `relations.records` med `entityRepresentation` (type konferanse/gruppe). Ingen ny rot for grupper eller organisasjoner. Alt annet i treet refererer til B med samme ID; foreslått regel: `relationID` for posten = `nodeIdentifier` for rotnoden.

2. **Publikummet er B ∩ (A ∪ {bᵢ}).** Nye relasjoner bᵢ oppstår på B og er i B per konstruksjon. Regelen blir: deltaker på B (bevisbart), og enten medlem av navngitt liste A eller relasjon med `origin.context = B` (avgjørbart fra As egne data). Mottakerlisten trenger ikke materialiseres; en grant som bærer regelen forblir riktig når nye relasjoner kommer til.

3. **Matching skjer i en celle deltakeren eier, utstedt av konferansen.** Deltakeren sender kontaktene sine til cellen; cellen henter deltakeroversikt fra B, matcher internt og returnerer resultatet. As kontaktliste forlater ikke As kontroll. Motstykket: B bør bare levere deltakere som har samtykket til å bli funnet av kontakter, og levere hashede identitetsnøkler, ikke profiler, slik at cellen og eieren bare lærer snittet.

4. **Identitetskryssing løses med samtykke, ikke deteksjon.** C kan være kjent for A via identitet i₁ og registrert på B med i₂. I stedet for at A eller B skal avgjøre om i₁ og i₂ er samme entitet, oppgir C selv per konferanse hvilke identiteter C vil matches på (`matchConsent`). Korrelasjon på tvers av domener blir et eksplisitt valg hos den det gjelder.

5. **Resultatet blir bevis i grafen.** Treff lagres som inclusion proofs fra B i `proofs.entityInclusion`, indeksert via `proofs.index.byKeypath` mot kanten `relations.records.<C>.entityRepresentation.partOf[<B>]`. Medlemskap er en vektet kant med bevis, ikke en egen liste.

## Forslag til skjemaendringer (åpne til Kjetil)

| Sti | Forslag |
|---|---|
| `conference.<relationID>` | Roten nøkles per konferanse. Dagens ene skive kolliderer ved flere konferanser og peker ikke på noen entitet. |
| `conference.<relationID>.cells[]` | Celler konferansen har utstedt til eieren (`cellReference`, `issuedBy`, gyldighet). Avklares mot `scaffoldPresence.mounts`/`bindings`. |
| `conference.<relationID>.matchConsent` | Egne identiteter som kan matches, og for hvilke formål. |
| Grant-betingelse i avtalekontrakten | «Gyldig `proofs.entityInclusion` for entitet X», kombinerbar med relasjonsregelen. Bevisst ikke i `InterestCondition`, som beskriver kunnskap og ikke autorisasjon. |

## Det som fortsatt er åpent

Elementformen i eierdefinerte navngitte lister. Forholdet mellom utstedte celler, `scaffoldPresence` og `bindings`. Hvor mye eieren av matchecellen kan lese av det cellen mottar (eierskap trumfer normalt intercepts, så det B leverer må være begrenset i seg selv). Om hashede nøkler er nok, eller om ekte private set intersection trengs.
