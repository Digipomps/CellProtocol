# Bridge PR #53 — sikkerhet, latency og robusthet

Dato: 2026-10-03. Status: **vurdering ferdig; PR-en er ikke ferdig rettet eller klar for merge**.

## Anbefaling

Behold den felles Bridge/Resolver-arkitekturen og forbindelsesbundet identitetsbevis. Integrer den allerede testede N35-rettingen, lukk de åpne Scanner-funnene og krev bevis fra både native klient og server. Gjør automatisk gjenoppretting og faktisk end-to-end-latency til egne akseptansekriterier før broen beskrives som friksjonsløs.

Løsningen er hensiktsmessig som fundament, men dagens leveranse er ikke tilstrekkelig. Sikkerhetsarbeidet har rettet reelle feil; samtidig har implementasjonen vokst til flere sammenvevde livsløp. Ytterligere punktvise kontroller alene er en svak strategi. Samle eierskap, opptak og pensjonering rundt få eksplisitte instanser, og prøv de samme invariantene gjennom alle adapterne.

Ikke bytt til en ny kryptoprotokoll eller QUIC som en hasteløsning i denne PR-en. Det ville ikke rette de påviste feilene i brukerhandlinger, tilstand eller Swift-oppgaver. En standardisert transport kan være riktig senere, etter måling og en konkret sammenligning.

## 1. Grunnlag og hva som faktisk ble gjort

Brukerens mål: «sørge for at broen har minst mulig sårbarheter, samtidig så det har så lav latency som mulig og er robust», som fundament for HAVEN på tvers av hardware og tjenester.

- GitHub [PR #53](https://github.com/Digipomps/CellProtocol/pull/53) er åpen, ikke merget. Kontrollert head: `3824cf84b58903f900a49b0987ee660085f3d875`, gren `pdd/bro-kanal-auth`.
- Lokal PR-worktree er ren og har samme head. Kildestier i denne rapporten er repository-relative og gjelder denne revisjonen hvis ikke annet står.
- Separat N35-kandidat: runtimecommit `091c85b`, testet head `7ef06e7541d57561f04d1a3ca8d2ced44cbd0eb1`, nåværende kandidatgren `codex/bridge-mux-independent-dispatch-20261001` på `990fffe09e8bdd8058b1d56e1cc17fca6ad71dce`. De siste endringene er dokumentasjon og gjenoppretting av vanlig CI-policy. Kandidaten er ikke del av PR-head.
- Lest: de relevante auth-, gate-, record-, mux-, Resolver-, Apple/Vapor- og Scanner-kjedene, utvalgte regresjoner, kontroll 8 og tidligere design/leveransebevis. Dette er ikke en ny full audit av alle 91 endrede filer eller en formell kryptorevisjon.
- Eksisterende G1/G2 for `CellProtocolDocuments/Deliverables/PDD_bro-paa-i-prod_2026-09-26/` er godkjent. G3 venter. Tidligere beslutning om alle funn før merge videreføres.
- Ny lokal kapasitetskontroll ga exit **75**: 56,5 GiB ledig; 46,5 GiB/5 % etter 10 GiB reserve, krav 40 GiB **og 10 %**. Ingen Swift-build, nye runtime-regresjoner, CI-start, push, merge eller deploy er utført i denne vurderingen.
- Main hadde eksisterende endringer i Skeleton/List-filer. De er ikke endret av dette arbeidet.

`N35.patch` i denne mappen er en eksport av den eksisterende kandidatens nettoendring mot PR-head, ikke en ny eller integrert runtime-retting. `evidence.json` angir revisjoner, hashes og kontrollresultater.

## 2. Det vi bør beholde

| Valg | Hvorfor det er riktig | Viktig avgrensning |
|---|---|---|
| Én Bridge med utskiftbare adaptere | Samme cellemodell og tilgangsvei på tvers av hardware og tjenester | Adapterne må bevise like egenskaper; et felles interface gjør dem ikke automatisk like |
| Kanalproof før factory/Cell-oppslag | Hindrer at en løs UUID eller `ready` gir tilgang til broen | Beviser nøkkelkontroll, ikke personidentitet eller en Cell-rettighet |
| Lokal vault, minimalt offentlig identitetsobjekt | Private nøkler og lokale signeringstillatelser blir på eierenheten | Ingen fallback til serverens eller standardvaultens myndighet |
| Resolver/Agreement etter kanalopptak | Transport og celleautorisasjon har forskjellige ansvar | Kanalproof kan ikke ukritisk erstatte origin-proof eller kontraktkontroll |
| Kvoter før asynkront arbeid, beholdt gjennom cleanup | Begrenser opphopning selv når operasjoner ignorerer cancellation | Appkvoter er ikke et absolutt tak på OS/framework-reassembly eller RSS |
| Lokal kanalinstans/generasjon fremfor wire-ID som levetidsanker | Sene svar og gammel cleanup skal ikke påvirke en ny forbindelse | Må også gjelde brukerklikk, terminal events, factory-resultater og fysiske callbacks |
| Mux og deling av pågående handshake | Amortiserer oppkobling og reduserer samtidige forbindelser | Del bare innen samme sikkerhetsbundne poolnøkkel og behold isolasjon mellom kanaler |

Kilder: `Sources/CellBase/Cells/Bridging/BridgeChannelAuthentication.swift`, `BridgeChannelSession.swift`, `BridgeChannelTransport.swift`, `BridgeIdentityProofAuthorization.swift`, `BridgeMultiplexing.swift`; `Sources/CellBase/Cells/CellResolver/CellResolver.swift:2300–2345`.

## 3. Restene på PR-head

Dette er kontroll 8s åpne poster, kontrollert mot relevante kildeutdrag. Ingen av dem lukkes ved å eksportere N35-kandidaten.

| Post | Konsekvens | Konkret retting og nødvendig bevis |
|---|---|---|
| N35 | En holdt celleoperasjon stanser andre mux-kanaler og logisk close på samme Vapor-socket | Integrer eksisterende kandidat. Bevar lokal rekkefølge, instansbinding og beholdte kvoter. Tre regresjoner har historisk rødt/grønt bevis |
| N36 | Gammelt kontakt-/detaljsamtykke kan forbruke en ny pending under samme remoteUUID/requestId | Lokal engangs-ID på den eksakte pending-instansen, bundet til uforanderlig innhold, principal og generasjon. Prøv reconnect/annen nøkkel og TTL/ID-gjenbruk for begge handlingstyper |
| N39 | Gammelt accept/reject kan treffe en ny invitasjon | Bær eksisterende invitasjonsinstans og servicegenerasjon frem til handlingen. Valider før handleren tas. Test faktisk publisert action ved ny fysisk peer, samme peer/nytt setup og servicebytte |
| N37 | Radar-ledger og probehistorikk er ikke omfattet av den faste consumer-grensen | Faste count-/bytegrenser og eiet utløp også her. Kjør over mange UUID-/TTL-vinduer uten radar-get. Bevar replay/ratevern; ikke tøm dette blindt ved reconnect |
| N32 | Terminal status kan forsvinne når siste serviceeier slippes; gammel service kan publisere etter utskifting | Én eier av terminallevering og serviceidentitet ved siste effekt. Test reell cellestopp og gammel callback etter restart |
| N38 | Første probe etter reconnect kan feile fordi gammel `.probing`-tilstand overlever pending | Pensjoner pending og dens eide operasjonstilstand samlet. Første friske probe må virke, og sen gammel cleanup må ikke nullstille den |
| N12 | Native NI/UWB er ikke verifisert mellom to fysiske iPhones | Faktisk token-/kanalbinding, avvisning av feil peer, revoke/reconnect og radiotest. macOS-mock og iOS-kompilering erstatter ikke dette |

Konkrete kildeankre: `Sources/CellApple/EntityRadar/EntityScannerCell.swift:410–419,531–556,643–665,1141–1165,1236–1285,1320–1322,1458–1528`; `ScannerService.swift:823–839`; `ScannerConsumerContext.swift:69–77`; `RadarModels.swift:422–480`; `NearbyProbe.swift:75–139`.

## 4. Ytterligere vurderingspunkter som berører hovedmålet

### A1 — Native Apple-inngang har fortsatt én fullføringskjede

Kildebasert funn: `Sources/CellApple/WebSocketConnection.swift:265–287` registrerer neste `receive` **etter** `await delegate.onMessage`. `AppleBridgeTransport.swift:158–168` venter videre på `consumeResponse`/`consumeCommand`. Holder et delegatkall, blir ikke neste app-melding hentet, uavhengig av logisk kanal. N35 endrer bare Vapor-adapterens planlegging og to felles mux/gate-filer; denne Apple-kjeden er uendret.

Dette er en konkret ventekjede i koden, ikke en kjørt native deadlock-reproduksjon. Hvor lenge vanlige BridgeBase-kall holder kjeden, og konsekvensen for UI, må måles. En treg lokal signeringsvault er én relevant barriere. Det er ikke dokumentert at alle normale kall henger.

Rett ved å skille begrenset mottak fra fullført kanalbehandling også på Apple. Ikke flytt bare `listen()` foran `await` og opprett ubegrenset med Tasks. Bevar pre-decode-opptak, bounded kø, lokal kanalrekkefølge, signeringsfremdrift og pensjonering. Regresjon: ekte native WS-klient, hold A, krev B og relevant kontrolltrafikk før A slippes, og test burst/close/stale callback.

### A2 — Fem minutters sikkerhetslevetid er ikke sømløs kontinuitet

`BridgeChannelAuthentication.channelLifetime = 300`. `BridgeChannelTransport.scheduleExpiry` lukker forbindelsen. `BridgeBase.swift:428–440` tilbyr eksplisitt renewal som avslutter gamle streams og pending; den krever at transporten direkte er en `BridgeChannelTransport`. Dette er ikke i seg selv en mux-renewal-kontrakt. Søk i den vurderte CP-kilden fant definisjonen og tester, men ingen automatisk produksjonskaller av denne metoden. Resolver kan opprette ny bro ved nytt oppslag; det flytter ikke et eksisterende abonnement automatisk.

Anbefalt kontrakt: klargjør en ny autentisert generasjon før utløp, med spredt tidspunkt og begrenset overlapp; flytt bare operasjoner som har definert gjenopptakelse. Autorisasjon og revokasjon må revalideres. Et read kan hentes på nytt etter gjeldende policy. Et feed trenger snapshot/cursor/gap-regler. Et SET med tapt svar har ukjent utfall og skal ikke automatisk gjentas uten en eksplisitt idempotenskontrakt. Ikke øk bare TTL for å skjule bruddet.

Dette er et produkt-/integrasjonsgap, ikke en påvist proof-omgåelse. Automatiske, uavbrutte abonnementer er foreslått arbeid, ikke implementert i denne vurderingen.

### A3 — Isolasjon ved kømetning er svakere enn isolasjon ved én treg operasjon

Vapor har 64 meldinger/4 MiB per forbindelse og en delt 1024/32 MiB-grense. N35s uavhengige kanaler bruker fortsatt samme opptaksbudsjett. Et overfylt fysisk budsjett lukker socketen. Én kanal som fyller budsjettet kan derfor påvirke søsken, selv etter N35. Kandidaten dokumenterer dessuten at uferdige channel-factories fortsatt bruker felles setup-hale.

Dette er en eksplisitt avveining i nåværende kode, ikke en ny påstand om ubundet minnevekst. Legg til kanalvis rettferdighet og et lite, avgrenset kontrollbudsjett dersom kravet er fortsatt søskenfremdrift ved belastning. Ingen kontrollmelding skal få ubegrenset opptak eller omgå principal-/generasjonskontroller. Test både én holdt factory og en kanal som bruker sin kvote, med en fungerende søskenkanal på samme socket.

### A4 — Sikkerhetskompleksiteten bør reduseres gjennom eierskap

Mot PR-ens base `9c60001` er runtimeendringen 31 kildefiler, +5238/−1907 linjer. Størrelse alene er ikke en feil, men flere av restene har samme årsak: gjenbrukbar ekstern ID velger nåværende tilstand, mens brukerhandling/async-arbeid tilhører en eldre instans.

Bruk eksisterende bounded records til å bære lokale engangs-ID-er. La én instans eie pending, arbeid, terminallevering og opprydding. Kontroller den ved siste irreversible effekt. Unngå nye parallelle oppslagstabeller og mange nesten like `isCurrent`-sjekker. Normaliser adapterenes opptaks-/dispatch-kontrakt etter at regresjonene finnes; ikke gjør en stor omskriving samtidig med reparasjonen.

## 5. Latency: hvor tiden sannsynligvis går

Det finnes ikke grunnlag her for å love et antall millisekunder. Eksisterende runtimebenchmark sier uttrykkelig at den syntetiske resolvermålingen ikke inkluderer signaturverifisering eller remote bridge-kostnad (`Benchmarks/CellRuntimeBenchmarks/main.swift:416–423`). CI-suksess og timeoutbaserte regresjoner er heller ikke latencyprofiler.

### Kald WS-forbindelse

Etter DNS/TCP/TLS/HTTP-upgrade følger `Hello → Challenge → Proof → Accepted`: omtrent **2 nettverks-RTT** før klienten har auth-aksept, pluss lokal signering/verifisering, policy og factory. Et nytt mux-kanaloppsett og proxybeskrivelse kan komme i tillegg. Dette er en protokollbasert kostnadsmodell, ikke en måling; noen steg kan overlappe i en bestemt caller.

### Varm, beskyttet handling

`GeneralCell.checkIdentityOrigin` lager en fersk challenge og venter på signatur. Når vault er `BridgeIdentityVault`, går signeringen tilbake til klienten (`GeneralCell.swift:2253–2291`; `Identity/BridgeIdentityVault.swift:70–78`). En protected request/response med én slik kontroll kan derfor kreve omtrent **2 RTT**: ett for selve operasjonen og ett inne i operasjonen for origin-proof. Flere etterfølgende tilgangskontroller kan koste flere runder. Ikke alle get-paths har samme antall kontroller.

Eksempel, kun modell: med 50 ms RTT er 2 RTT omtrent 100 ms før CPU/køtid. Å spare noen mikrosekunder i hashing har da liten effekt sammenlignet med en ekstra nettverksrunde.

Mål antall signerings-RPC-er per brukerhandling før optimalisering. En eventuell kortlivet attest for nøkkelkontroll må være lokalt utstedt, bundet til eksakt kanal/principal/domene/resource og utløp/revokasjon. Den må ikke cache en Agreement-tillatelse som om den var uforanderlig. Dagens proof-kontroller skal beholdes inntil en slik modell er spesifisert og testet.

### Peer

V3 bruker fem handshake-meldinger, efemær DH, lokale signaturer, krypterte identiteter og to Finished-meldinger. M2/M3 har 8192 byte padding hver; M4/M5 1024 hver, før tag/base64/envelope. Det er minst omtrent 24,1 KiB bare for base64 av de fire forseglede blokkene, pluss øvrige felter og M1. Identitetsvern og eksplisitt bekreftelse har altså en målbar oppkoblingskostnad. Behold dem nå; mål på faktiske enheter før en eventuell wireendring.

Peer-records har 65 byte header/tag, minst 34 byte flow-control-body og 40 byte per piggyback-kvittering. Datavinduet er 32 records/2 MiB (`BridgePeerFlowControl.swift:12–16`). Vinduet gir en grov gjennomstrømmingsgrense på `min(2 MiB, 32 × recordstørrelse) / kvitteringsrundtur`, før annen kostnad. Små meldinger kan dermed være begrenset av recordantallet. Dette er en modell, ikke målt kapasitet.

### Prioritering

1. Fjern venting på andre kanaler, både server og native klient.
2. Gjenbruk gyldig forbindelse og pågående handshake innen riktig sikkerhetskontekst.
3. Mål og reduser unødvendige serielle signerings-/metadata-runder uten å svekke autoritet.
4. Gjør utløp/reconnect kontrollert og synlig for abonnementets eier.
5. Profilér kopiering/JSON, Task-antall og global kvotelås. `BridgeChannelLimits` gjør flere summeringer/filtreringer under én lås; det er en mulig skaleringseffekt, ikke en målt flaskehals.
6. Vurder batching eller alternativ transport først når pkt. 1–5 er målt. Batching må ha både størrelses- og tidsgrense.

## 6. Kryptografi og transportvalg

**WSS/TLS for server:** godt utgangspunkt med standardbiblioteker, proxy- og nettverksstøtte. Kanalproof legger HAVENs lokale nøkkelkontroll oppå serverkanalen. Ikke legg peer-v3-kryptering oppå WSS uten et konkret ekstra tillitskrav.

**Peer-v3:** SIGMA-I er et relevant mønster når eksisterende vault-nøkler signerer, og identitet skal skjules under nøkkelutvekslingen. V3 er likevel en egen instansiering med eget transcript, encoding, padding, records og livsløp. Sikkerhetsanalysen av SIGMA er ikke et bevis for hele denne implementasjonen. Anbefalt tillegg før bred utrulling: uavhengig kryptoreview av den eksakte bytekontrakten og negative testvektorer. Ingen ny konkret nøkkel-/AEAD-omgåelse er etablert i denne vurderingen. [SIGMA, §§2.2 og 5](https://iacr.org/cryptodb/archive/2003/CRYPTO/1495/1495.pdf).

**Noise:** standard XX bruker statiske DH-nøkler. Å erstatte disse med dagens signaturer er en ny konstruksjon, ikke en direkte overgang til standard Noise. Et reelt alternativ krever nøkkel-/vault-/migrasjonsdesign. [Noise, håndtrykksmønstre](https://noiseprotocol.org/noise.html#interactive-handshake-patterns-fundamental).

**QUIC:** kan fjerne transportens head-of-line-blokkering mellom separate streams ved pakketap. En Swift-dispatchhale som venter på forrige celleoperasjon vil fortsatt blokkere uansett transport. Native/WAN-bruk kan begrunne en QUIC-adapter senere; HTTP/WS bør beholdes der interoperabilitet krever det. [RFC 9000, §13](https://www.rfc-editor.org/rfc/rfc9000.html#section-13).

**0-RTT:** bør ikke brukes for vanlige mutasjoner for å spare latency. Early data kan spilles av igjen; brukerhandlinger med sideeffekt trenger en særskilt replay-/idempotensmodell. [RFC 8446, §8](https://www.rfc-editor.org/rfc/rfc8446.html#section-8).

Identitetsvern må også beskrives presist: en aktivt akseptert motpart kan motta responderens identitet under disclosurepolicy. Kryptering skjuler ikke dette for parten som terminerer håndtrykket, og kanalproof er ikke bevis på fysisk nærhet.

## 7. Akseptanse som dekker brukerens mål

Følgende er foreslåtte porter/målinger, ikke allerede beståtte resultater eller brukerfastsatte SLO-er.

| Mål | Prøve | Godkjenningsgrunnlag |
|---|---|---|
| Riktig myndighet | Alle kommandotyper før/etter proof; feil principal/domene; revoke mens signer/factory er holdt | Ingen uautorisert resolver-/celle-/sign-/persist-effekt; friske tillatte operasjoner virker |
| Riktig brukerbeslutning | Faktisk publisert kontakt/detail/invitasjonsaction, ny pending under samme eksterne ID | Gammel action har null effekt og forbruker ikke ny pending; fersk action virker |
| Uavhengige kanaler | Hold A og factory C; kjør B og selektiv close gjennom Vapor og Apple | B fullfører før barrierene slippes; ingen gammel levering til gjenbrukt kanal; kvote beholdes til slutt |
| Avgrenset ressursbruk | Quota+1, mange nøkler/UUID-er, TTL-vinduer, holdt audit/cleanup, ingen radar-polling | Alle eide køer/tabeller har faste grenser; stabilisert retained state; mål også RSS separat |
| Kontinuitet | Minst 30 minutter, flere auth-utløp, sleep/wake, nettbytte, radio-/serverbrudd | Ingen stille feed-stopp; hull rapporteres/repareres etter definert kontrakt; ingen automatisk dobbeltskriving |
| Latency | Kald connect→første tillatte svar; varm get/set; feed fra send til mottak; reconnect | p50/p95/p99, timeout-rate, RTT, sign-RPC-antall, bytes, CPU og energibruk per faktisk enhet/nett |
| Belastning | 1/8/16 kanaler, små og store payloads, RTT 1/20/50/100 ms, pakketap 0/1/3 % i kontrollert miljø | Vis køtid og p99 for frisk B mens A er treg; sammenlign før/etter på samme hardware |
| Hardwareparitet | macOS native↔Vapor, iPhone↔Vapor, fysisk peer i begge inviterretninger, NI på to støttede iPhones | Samme auth-/ordre-/retirementkontrakt; dokumenterte transportspesifikke begrensninger |
| Reell drift | Eksakt CP-pin i Binding/CellScaffold, WSS/proxy, offentlig og admin-rute, delt bridge | Faktisk beskyttet lesing/skriving/abonnement med korrekt requester; separate negative kontroller |

Et millisekundmål bør fastsettes etter første baseline per scenario. Fastsett samtidig maksimal tillatt bruddtid og hva «ingen tap» betyr: siste tilstand, alle events eller bekreftet mutasjon. Disse er forskjellige garantier.

## 8. Reparasjonsrekkefølge og leveransegrense

1. **N35:** bruk den testede kandidatens runtime og regresjoner. Eksporten her gjør nettodiffen konkret. Ikke ta med et permanent CI-unntak; kandidatens siste commit har gjenopprettet vanlig workflow.
2. **N36/N39:** rett samtykkebinding samlet som ett mønster, men test kontakt, detail og invitasjon hver for seg. Dette krever ingen ny roundtrip; det er lokal instansbinding.
3. **N32/N37/N38:** samle retirement og ressursregnskap; test gjennom ekte EntityScannerCell uten avhengighet av polling.
4. **Apple og belastning:** reproduksjon og bounded kanalvis dispatch; hold sikkerhet/integritet/rekkefølge lik på begge WS-ender.
5. **N12 og konsumentene:** fysisk NI-bevis samt app-/hostintegrasjon med eksakt kandidat. Oppdater PR-beskrivelsen, som fortsatt omtaler gamle heads og tidligere uløste poster.
6. **Kontinuitet/latency:** mål baseline og innfør den avtalte gjenopprettingskontrakten. Større proof-cache-/QUIC-/wireendringer er separate designvalg etter måling.

N35-kandidatens [CI-kjøring 37049974688](https://github.com/Digipomps/CellProtocol/actions/runs/37049974688) er kontrollert som fullført med SUCCESS. Jobbloggen bekrefter testet SHA, Xcode 26.6/Swift 6.3.3 og sekvensen original-regresjoner → rettet-regresjoner → fullsuite → TSAN. Det nedlastede artefaktets fire rålogger og `result.json` er kontrollert: tre originale regresjoner med seks registrerte feil, tre grønne kandidat-tester, fullsuite 1539/5 skips/0 feil og TSAN 55/0. Originalprøven gjeninnsatte de tre gamle runtimefilene med de nye testene; den var ikke en urørt historisk checkout. SHA-256 for alle tre runtimefiler matcher den eksporterte kandidatens innhold. Ni Python-tester for testorkestreringen ble også kjørt lokalt med null feil; de er ikke Swift-runtimebevis. Hashes, kommandoer og sluttsammendrag står i `evidence.json`. CI-resultatene er eksisterende bevis og ikke en attestasjon av hele PR-en.

Gjenværende gjennomføringshindringer er lokal byggekapasitet og fysisk NI-verifikasjon. De gjør ikke kildereview eller patchkontroll umulig, men hindrer at nye runtimeendringer kan rapporteres som verifisert her. Ingen port er godkjent på brukerens vegne.

## 9. Læringsfangst

`L-2026-10-03-bridge-native-latency-boundaries` er fanget, anvendt og synkronisert til transport-skillen, lokale Claude/Codex-kopier og Desktop-ZIP. Eksisterende endringer i den kanoniske skillen ble bevart. Den globale `haven_learn.py check --strict` ga exit 1 på to andre åpne og tolv tidligere usynkroniserte poster; denne vurderingens læring står ikke blant dem. Ingen av de andre postene er markert ferdig her.
