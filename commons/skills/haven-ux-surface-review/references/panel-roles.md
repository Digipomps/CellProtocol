# Panelroller, brief-mal og adjudikering

## Roller (minimum fem, kjørt parallelt med samme brief)

| Rolle | Mandat | Leverer |
|---|---|---|
| **Formålsrådgiver** (obligatorisk) | Er formålsbeskrivelsen komplett (fem spørsmål, 0–5)? Er den besvart i flaten? Hvilke elementer har ikke uttalt formål, hvilke løfter mangler element? Owner-entity-access? Tre listetilstander? | Formålsmatrise per flate + funn. Ved mange flater: del i A (JSON-flater) og B (Swift-fabrikker + web-maler). |
| **UX-heuristikkekspert** | Nielsen H1–H10, Norman, Hick/Fitts, Gestalt, kognitiv belastning, tom-/feil-/lastetilstander, farlige handlinger, plassholder-lekkasje, husets guardrails. Én per flateklynge (≤ ~15 flater). | Per-flate-profil (primærhandling, tetthet) + funn. |
| **Visuell design + tilgjengelighet** | Typografiskala, palett/tokens, kontrast (WCAG 1.4.3/1.4.11) regnet fra JSON + CSS, alt-tekst, feltnavn, treffstørrelse, mørk/lys. | Kontrasttabell (kun brudd), palett-inventar, funn. |
| **Web-/skall-ekspert** | Leaf-maler, Porthole-skall, login, admin: landemerker, `lang`, feilmeldinger, live-regioner, `<form>`, døde ruter/maler, lekkasjeliste. | Funn med fil:linje; liste over rester uten formål. |
| **Helhet/IA + skeptiker** | Navigasjonsmønstre, språk og knappeverb på tvers, visuelle familier, kilder og drift, husreglenes innbyrdes konsistens, formålsarkitektur, faste holdepunkter. Leter aktivt etter feil i briefen. | Tverrgående funn (alle merket tverrgående=ja). |
| **Adjudikator A** (orkestrator) | Korreksjonsrunde, konsolidering, matrise, rangering, Q1–Q10. | RAPPORT.md |
| **Adjudikator B** | Får de hardeste dommene som eksplisitte utfordringer med motargument; må rendre eller lese kode; navngir også funn der panelet var for mildt. | ADJ_B.md med «står / faller / omklassifiser» per utfordring. |

Ulike AI-flater kan ta ulike roller (Codex repo-grunnet, Claude lang kritikk, lokale modeller for deterministiske sjekker).

## Brief-mal

```
# Panel-brief: <oppdrag> (<dato>)
Briefen binder til REGLER, ikke FAKTA. Hvert faktum har revisjonsstatus (retrieved/recalled/unavailable/contradicted).
Åpne svaret med `## Brief-revisjon`; et funn der rangerer over fagfunn.

## 0 Oppdraget (ordrett) + Formål og mål (tabell F1..Fn med målbart mål)
## 1 Repoer og stier (HEAD, inventarfil, kjente purpose-refs)
## 2 Flate-inventar (lag A–H: katalog-JSON, Public/skeletons, ressurs-skeletons, fixtures som er produktflater,
     Playwright-scenarier (dedup + drift), Swift-fabrikker, web-maler/skall, runtime-flateliste)
## 3 Hvor formålsbeskrivelsen bor
## 4 Husets regler panelet måler mot (kilder; «les før du siterer»); tidligere gjennomganger (marker kjente funn)
## 5 Kjente konflikter (deklarert, ikke løst)
## 6 Rubrikk (alvorlighet; funnformat; formålsvurderingsformat; forbud mot å finne opp refs/elementer; språk)
## 7 Leveranseformat (full rapport til fil; retur = brief-revisjon, antall per alvorlighet, topp 5, regler, ikke verifisert)
```

Fakta i briefen som erfaringsmessig blir feil: antall filer, «nyeste snapshot», hva A/B-varianter er, hvilken fil en farge kommer fra, hva et skript faktisk teller. Skriv dem med `retrieved` bare når du har lest kilden i denne økten.

## Returformat fra hver rolle

1. Brief-revisjon (3–8 linjer)
2. Antall funn per alvorlighet
3. De 5 viktigste funnene, én linje hver
4. 3–8 tverrgående regler for skill
5. Hva som ikke ble rukket / ikke kunne verifiseres

Full rapport skrives til fil med seksjonene `## Brief-revisjon`, `## Metode`, (rolle-spesifikke seksjoner), `## Funn`, `## Tverrgående regler for skill`, `## Ikke verifisert`.

## Adjudikering

1. **Korreksjonsrunde.** Samle brief-revisjonene. For hver feil i briefen: hvilke funn hviler på den? Faller, står eller flipper. Rett briefen i leveransen med en «Korrigert»-liste; aldri stille.
2. **Utfordringer til B.** Velg 3–5 dommer: (a) enhver `blokker` som hviler på en renderer-antakelse, (b) en tverrgående dom som hviler på et ulest skall, (c) en «død keypath»-påstand, (d) en dom der to roller er uenige. Gi B motargumentet ferdig formulert og krav om bevis (rendring/kode).
3. **Q2-retning.** Objektet er husets egne flater, kommisjonert av eieren → feilmodus er hardhet. B skal også navngi funn der panelet var for mildt (E-seksjon), så ikke bare én retning korrigeres.
4. **Terminal status.** Hvert funn ender som: står / omklassifisert / falt / åpent-med-eier. Hvert formål i briefen ender som satisfied / missed / blocked med begrunnelse.
5. **Q1–Q10** (Book 30) publiseres som diagnostikk, aldri som mål.
