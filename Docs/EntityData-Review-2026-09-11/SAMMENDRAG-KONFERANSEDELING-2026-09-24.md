# Deling av entitetsdata innenfor en gruppe – sammendrag

Skrevet 24. september 2026, avstemt 6. november mot Kjetils beslutninger 22.–25. september ([BESLUTNING-UUID-OG-GRUPPER-2026-09-22.md](BESLUTNING-UUID-OG-GRUPPER-2026-09-22.md), [V2-BESLUTTET-FORM.md](V2-BESLUTTET-FORM.md)). Kort status til andre tråder som jobber med EntityData, konferanse-scaffold, identitet eller avtaler. Forslagene ligger i [proposals-2026-09-24.json](proposals-2026-09-24.json), er sendt Kjetil 24.09 og er **ikke besvart eller ført inn i skjemaet**.

## Scenariet

Person A deltar på konferanse B. A vil dele egen agenda med et utvalg av egne kontakter (gruppe A, f.eks. kollegaer), men bare med dem som også er deltakere på B, og dessuten med nye relasjoner A får på B underveis.

## Det vi ble enige om

1. **Konferansen er en entitet i As data.** B er en entitet i `relations.entities` (uuid-nøklet) med en relasjonspost i `relations.records` som bærer As perspektivgraf om B. Alt annet i treet refererer til B med entitets-uuid. Kjetils 22.09-beslutning om uuid gjennomgående løste ID-spørsmålet vi hadde reist.

2. **Gruppe A er en `groups`-post.** `groups.<uuid>` med `name` og uvektet `members` over entitets-uuid-er (vedtatt 22.09). Eierdefinerte navngitte lister under `relations` er avvist.

3. **Publikummet er B ∩ (A ∪ {bᵢ}).** Nye relasjoner bᵢ oppstår på B og er i B per konstruksjon. Regelen blir: deltaker på B (bevisbart), og enten medlem av gruppe A eller relasjon med `origin.context = B` (avgjørbart fra As egne data). Mottakerlisten trenger ikke materialiseres; en grant som bærer regelen forblir riktig når nye relasjoner kommer til.

4. **Matching skjer i en celle deltakeren eier, utstedt av konferansen.** Deltakeren sender kontaktene sine til cellen; cellen henter deltakeroversikt fra B, matcher internt og returnerer resultatet. As kontaktliste forlater ikke As kontroll. Motstykket: B bør bare levere deltakere som har samtykket til å bli funnet av kontakter, og levere hashede identitetsnøkler, ikke profiler, slik at cellen og eieren bare lærer snittet. Celler adresseres `cell:///<uuid>` (Kjetil 27.09).

5. **Identitetskryssing løses med samtykke, ikke deteksjon.** C kan være kjent for A via identitet i₁ og registrert på B med i₂. I stedet for at A eller B skal avgjøre om i₁ og i₂ er samme entitet, oppgir C selv per konferanse hvilke identiteter C vil matches på (`matchConsent`). Korrelasjon på tvers av domener blir et eksplisitt valg hos den det gjelder.

6. **Resultatet blir bevis i grafen.** Treff lagres som bevis fra B i det flate lageret `proofs.credentials` (23.09-mønsteret), med `supports.entityRef` = Cs entitets-uuid og `supports.keypaths` mot kanten `relations.records.<rel-uuid>.entityRepresentation.partOf`. `proofs.index.byKeypath` bygges ved dekoding. Medlemskap er en vektet kant med bevis, ikke en egen liste.

## Forslag til skjemaendringer (åpne, ubesvart av Kjetil)

| Sti | Forslag |
|---|---|
| `conference.<entity-uuid>` | Roten nøkles per konferanse. Dagens ene skive kolliderer ved flere konferanser og peker ikke på noen entitet. Fortsatt unøklet i målskjemaet per 06.11. |
| `conference.<entity-uuid>.cells[]` | Celler konferansen har utstedt til eieren (`cellReference`, `issuedBy`, gyldighet). Avklares mot `scaffoldPresence.mounts`/`bindings` – én source of truth. |
| `conference.<entity-uuid>.matchConsent` | Egne identiteter (uuid-er i `relations.identities`) som kan matches, og for hvilke formål. |
| Grant-betingelse i avtalekontrakten | «Gyldig medlemskapsbevis i `proofs.credentials` med `supports.entityRef = X`», kombinerbar med relasjonsregelen. Bevisst ikke i `InterestCondition`, som beskriver kunnskap og ikke autorisasjon. |

## Det som fortsatt er åpent

Forholdet mellom utstedte celler, `scaffoldPresence` og `bindings`. Hvor mye eieren av matchecellen kan lese av det cellen mottar (eierskap trumfer normalt intercepts, så det B leverer må være begrenset i seg selv). Om hashede nøkler er nok, eller om ekte private set intersection trengs. Identitetslikhet generelt er fortsatt uavklart i målmodellen (V2-BESLUTTET-FORM 25.09); `matchConsent` omgår det for dette scenariet, men løser det ikke.
