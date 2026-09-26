# Periodisk testrevisjon i HAVEN

Etablert 2026-09-10 etter Kjetils ønske om regelmessig test suite audit og dokumentasjon. Formålet er å bevare relevant feiloppdagelse og samtidig kontrollere kostnaden ved testing. En grønn suite, høy kodedekning eller et stigende testantall er ikke alene et kvalitetsmål.

Dette dokumentet er den varige arbeidspraksisen. Første avgrensede kartlegging finnes i [revisjonen 2026-09-10](../Audits/2026-09-10/HAVEN-test-suite-audit.md). Den er ingen full kvalitetsdom over alle testene. Automatisert håndheving utover eksisterende repo-kontroller er ikke implementert av dette dokumentet.

## Hva vi skal vurdere

Tester er vedlikeholdt kildekode med et beskyttelsesformål. Både håndskrevne og AI-genererte tester kan bli utdaterte. En irrelevant test kan fortsette å bestå fordi den ikke lenger undersøker den atferden brukerne er avhengige av. En gammel regresjonstest kan samtidig være svært verdifull nettopp fordi den hindrer at en sjelden feil kommer tilbake.

For hver test eller sammenhengende testfamilie skal revisjonen besvare:

1. Hvilket brukerbehov, protokollkrav, sikkerhetskrav eller støttet kompatibilitetsløfte beskytter den?
2. Hvilken konkret feil ville den oppdage, og er forventningen uavhengig av koden som testes?
3. Er den faktisk oppdaget og kjørt på relevante plattformer, pinner og konfigurasjoner?
4. Er den pålitelig, og kan en feil spores til produkt, testoppsett, avhengighet eller miljø?
5. Gir den selvstendig dekning, eller gjentar den samme bevis som en annen test på samme nivå?
6. Står kjøretid, minne, CPU, I/O, artefaktmengde og vedlikeholdsarbeid i forhold til verdien?

Test av observerbar atferd bør være hovedregelen. Implementasjonsdetaljer kan være et legitimt krav, for eksempel en dokumentert grense for antall databaseoppslag eller minneallokeringer. Det må da være eksplisitt, slik at en intern refaktorering ikke feilaktig tolkes som en produktregresjon. [Google: Test Behavior, Not Implementation](https://testing.googleblog.com/2013/08/testing-on-toilet-test-behavior-not.html).

## Frekvens og utløsere

Arbeidsantakelsen, inntil Kjetil velger en annen frekvens, er månedlig gjennomgang av endringene og full gjennomgang hvert kvartal. Periodisk oppfølging legges til første mandag i måneden kl. 09:00 Europe/Oslo. Januar, april, juli og oktober bruker kvartalsomfanget. Den første kartleggingen nedenfor erstatter ikke første kvartalsrevisjon.

Månedsrevisjonen tar endringer siden siste verifiserte revisjon, alle åpne funn, alle nye/endrede skip og unntak, vesentlige tids-/ressursregresjoner og endrede produktkontrakter. Kvartalsrevisjonen går gjennom hele testinventaret, inkludert suiter som aldri har feilet, testoppdagelse, filtre, eksperimenter, fixtures, scripts og GUI-/integrasjonstester. Hver familie skal ha en status eller en eksplisitt gjenstående vurdering; manglende tilgang eller tid er ikke grunnlag for å merke revisjonen komplett.

Ved større endringer i CellProtocol/HAVEN-konsepter, fjernet funksjonalitet, sikkerhetsgrenser, avhengighetspinner eller testharness vurderes de berørte testene i samme endring. Denne hendelsesregelen er en arbeidspraksis, ikke en installert GitHub-trigger. Vanlige tester og CI fortsetter mellom revisjonene.

Omfanget er CellProtocol, Sprout, CellScaffold, Binding, DiMyMicropayments, DiMyMint og HavenAgentD, med aktuelle dokumentasjonskontrakter fra CellProtocolDocuments. Revisjonen leser faktiske revisjoner på nytt; datoens pinner skal ikke bli faste antakelser i fremtidige kjøringer.

## Gjennomføring

1. **Fastslå grunnlaget.** Registrer repo, full commit-SHA, test- og avhengighetsrevisjoner, plattform, toolchain, maskin/runner, konfigurasjon og datagrunnlag. Bevar lokale brukerendringer. Bruk eksisterende CI-resultater når de gjelder riktig kilde; ikke kjør en dyr fullsuite på nytt bare for å hente tall vi allerede har.
2. **Avstem inventaret.** Skill mellom testfiler, suiter, oppdagede test-ID-er, valgte test-ID-er, faktisk kjørte tilfeller, runtime-skips og metode-/suiteunntak. Sammenhold testoppdagerens liste med testkjørerens faktiske seleksjon. Navn og regex er en første kartlegging, ikke et komplett testregister. Ta med testtyper utenfor Swift.
3. **Kartlegg beskyttelsesformålet.** Knytt testfamilier til kontrakt, brukerflyt eller opprinnelig feil. Vurder fixtures, mocks, påstander og forventede effekter. Et round-trip kan skjule at encoder og decoder har samme feil; stabile wire-kontrakter trenger også et uavhengig forventet eksempel eller annen tilsvarende kontroll.
4. **Prøv feiloppdagelsen.** For utvalgte viktige familier: bruk kjent før-retting-revisjon, kontrollert feilinnføring i isolert checkout, negative innganger eller uavhengige forventninger. En negativ test som bare beviser at alt avvises trenger også et legitimt positivt løp. Skill mellom oppdaget feil, overlevd endring, semantisk ekvivalent endring, kompilasjonsfeil og ressurs-/kjørefeil. Mutation testing gir nyttig evidens, men ingen enkelt score beviser kvalitet. [PITs metodebeskrivelse](https://pitest.org/quickstart/basic_concepts/) brukes som metodisk kilde; PIT er ikke her innført som Swift-verktøy.
5. **Undersøk stabilitet og kostnad.** Registrer første forsøk og senere forsøk hver for seg, seeds, rekkefølge, samtidighet, task-/prosessisolasjon og miljø. En test som består ved retry skal fortsatt ha sin første feil synlig. Undersøk før feilen tilskrives testen: ustabilitet kan komme fra produktkode. [Google: Where do our flaky tests come from?](https://testing.googleblog.com/2017/04/where-do-our-flaky-tests-come-from.html?hl=it_IT).
6. **Fatt og dokumenter beslutning.** Bruk statusene behold, forbedre, slå sammen, flytt til annet testnivå/eksperiment, tidsavgrenset karantene, fjern-kandidat eller trenger mer bevis. En revisjon oppretter funn og konkrete forslag; den sletter ikke automatisk tester eller endrer merge-porter. Implementasjon følger vanlig kodegjennomgang og relevante kontroller.
7. **Kontroller endringens effekt.** Ved godkjent opprydding vises hvilke krav som fortsatt har dekning, hvilke gamle og nye tester som oppdager representative feil, og før/etter-kostnad med sammenlignbart miljø. Manglende feil i produksjon er ikke i seg selv bevis for at en test kan slettes.

## Regler for unntak, overlapp og fjerning

En feilende test kan indikere et viktig udekket problem; grønn CI er ingen begrunnelse for å fjerne den. Sikkerhets-, rettighets-, lagrings-, pengeverdi-, wire-/legacy- og Apple/Vapor-/web/Binding-kontrakter skal beholde det nødvendige positive og negative beviset.

Lik testtekst eller samme kodedekning beviser ikke redundans. En enhetstest og en GUI-test kan beskytte ulike feilgrenser. Parametrisering eller sammenslåing er aktuelt når alle relevante innganger, plattformer, forventninger og feildiagnostikk beholdes.

Fjerning krever enten et eksplisitt avviklet produkt-/kompatibilitetskrav eller navngitt erstatningsdekning med sammenlignbart bevis. Begrunnelsen, revisjonen, erstatningens test-ID-er, reviewer og resultat skal lagres. Manglende historisk kobling betyr «trenger mer bevis», ikke «irrelevant».

Karantene får årsak, berørt plattform/krav, ansvarlig når avklart, dokumentert gjeninntakskriterium og neste vurderingsdato. En legitim miljøstyrt opt-in-test trenger ikke automatisk utløp, men må ha en kjørevei og et ferskhetskrav for sitt formål. Frister og eiere skal ikke fabrikkeres. Utgått karantene skal bli et synlig avvik; den skal ikke lydløst forlenges. Midlertidig utestenging er ikke en retting av produktet.

Rene generatorer av screenshots, fixtures og måledata skal merkes som generator/eksperiment. Verifikasjonen av at de genererte dataene er korrekte er en separat kontrakt. Fixture-oppdatering må ikke automatisk godkjenne en endret produktatferd.

## Metrikker

| Mål | Krav til tolkning |
| --- | --- |
| Inventar og gjennomgang | Antall test-ID-er oppdaget/valgt/kjørt, suiter/filer, vurderte familier og uavklarte familier. Oppgi nevner og omfang. |
| Relevans | Andel vurderte familier med et navngitt, fortsatt støttet krav; vis hvilke kritiske krav som mangler test. Dette krever vurdering, ikke bare navnesøk. |
| Feiloppdagelse | Kjente feil som fanges og representative feilinnføringer som ikke fanges. Oppgi utvalg og ekvivalente/ugyldige/ikke-kjørte tilfeller separat. |
| Stabilitet | Feil på første forsøk per sammenlignbar revisjon og miljø, andel som består ved retry, klassifiserte årsaker og uavklarte avvik. Én retry gir ikke en sikker flake-rate. |
| Skip/karantene | Antall og alder, gjeninntakskriterier, manglende eier/vurderingsdato og berørte krav. Skill runtime-skip fra tester som aldri ble valgt. |
| Kostnad | Testtid, byggetid og køtid separat; p50/p95 på tilstrekkelige sammenlignbare serier. CPU-sekunder, RSS/peak, faktisk I/O, tilgjengelig tråd/task-måling, CI-minutter og lagrede byte. Manglende tall er null/ukjent, ikke 0. |
| Dekningshull | Produksjons-/konsumentfeil som slapp gjennom, med lenke til manglende eller feilaktig testforutsetning. |

Målsettingen er riktig og rask feildeteksjon per ressursbruk, ikke flest mulig tester, færrest mulig tester eller høyest mulig enkeltprosent. Behold samme risiko-/kontraktsomfang ved før/etter-sammenligning.

## Dokumentasjon og maskinlesing

Hver revisjon lagres som `Docs/Audits/YYYY-MM-DD/HAVEN-test-suite-audit.md` og tilhørende `.json`. Flere kjøringer samme dato får et eksplisitt kjørings-ID-suffiks; gamle kvitteringer skal ikke overskrives. Rapporten skal angi fullt/avgrenset omfang, eksakte revisjoner, utførte kontroller, funn, motbevis, beslutninger og gjenstående arbeid.

JSON-filen er en dokumentasjonskontrakt, ikke et allerede implementert Cell-/scheduler-API. Den skal ha stabile funn-ID-er, kildehenvisninger, status, handling, akseptkriterium, prioriteringsgrunnlag og målinger med enhet og scope. Ved manglende verdi brukes `null` og årsak. Nye revisjoner refererer eksisterende åpne funn i stedet for å lage duplikater. Raw test-ID-er kan lagres som vedlagt inventar; en manuell flerlinjeregistrering for hver triviell parametrisering er ikke påkrevd.

Arbeidsoppgaver registreres via støttet WorkItemCell/AgentJobs-grensesnitt med idempotens og faktisk tilbakelesing når riktig runtime finnes. Inntil da skal lokal dokumentasjon si `nativeRegistered: false`; dokumentert fremdrift er ikke native jobbstatus. Opprinnelig sikkerhetsintake og historiske kvitteringer skal ikke endres for å passe nye funn.

Varige beslutninger og små normaliserte evidensutdrag beholdes. Store logger, screenshots og byggprodukter skal ha egen dokumentert lagringsperiode etter evidensbehov, størrelse og sensitivitetsnivå. Ved normalisering fra midlertidige logger skal nødvendige detaljer kopieres til et varig tillatt artefakt, med kilde-SHA/sjekksum og utdragsmetode; en sjekksum erstatter ikke et utilgjengelig bevis. Denne praksisen gir ingen automatisk slettefullmakt og ingen grunn til å duplisere alle rålogger i Git.

## Periodisk utføring

Den innledende oppfølgingen kan kjøre i denne Codex-oppgaven som en heartbeat. Det er forskjellig fra en installert HAVENAgentD-jobb. Lokal planlagt kjøring forutsetter at maskinen er på, appen kjører og prosjektet er tilgjengelig; den er ingen garantert serverscheduler. [OpenAI: Scheduled tasks](https://learn.chatgpt.com/docs/automations?surface=app).

Ved senere flytting til HAVENAgentD brukes det eksisterende jobbsystemet med stabil revisjons-ID og tilbakelesing. Den gamle oppfølgingen må da avvikles eller samordnes slik at samme audit ikke kjører dobbelt. Bygg og tester følger hvert repos ressursgrenser og eksisterende akseptkrav. Produksjonsdata og liveeffekter inngår bare i et separat autorisert testløp.
