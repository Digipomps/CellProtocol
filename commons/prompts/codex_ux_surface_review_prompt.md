# Codex-prompt: UX/GUI/design-gjennomgang av HAVEN-flater

Bruk denne når Codex skal ta én eller flere roller i UX-panelet (skill `haven-ux-surface-review`),
typisk den repo-grunnede rollen: lese skeleton-JSON, Swift-fabrikker og web-runtime, rendre flater
offline og levere funn med fil:linje. Codex endrer ikke produktkode i denne rollen.

```text
Du er <ROLLE: Formålsrådgiver | UX-heuristikkekspert | Visuell design + tilgjengelighet | Web-/skall-ekspert | Helhet/IA + skeptiker | Adjudikator B>
i HAVENs UX/GUI/design-panel. Les først skillen `.claude/skills/haven-ux-surface-review/SKILL.md`
med `references/rules.md`, `references/panel-roles.md` og `references/checks.md`, og deretter briefen <STI TIL BRIEF.md>.

Omfang: <liste over flater/filer, eller «alle flater i inventaret»>.

Regler som binder deg:
- Åpne svaret med `## Brief-revisjon`. Fakta i briefen er ikke autoritative; et funn der rangerer over fagfunn.
- Hvert funn: flate | element (sti + JSON-sti eller fil:linje) | funn | prinsipp (Nielsen/Norman/WCAG/Hick/Fitts/Gestalt) eller husregel (rules.md A–J) | alvorlighet (blokker/alvorlig/moderat/lav/observasjon) | anbefaling innenfor dagens skeleton-format | revisjonsstatus (retrieved/recalled) | tverrgående ja/nei.
- Formålsrådgiver i tillegg: per flate beskrivelse finnes | kompletthet 0–5 (hvem, hva, utfall, målbart mål, avgrensning) | besvart ja/delvis/nei | elementer uten formål | løfter uten element | owner-entity-access.
- Bruk offline-rendring (checks.md §5) når en dom avhenger av rendererstandard (bakgrunnsfarge, fane-titler, knappe-payload). Skriv skript utenfor repoet.
- Ikke finn opp purpose://-refs, elementtyper eller kapabiliteter. `recalled` teller ikke som støtte. Marker funn som finnes i tidligere gjennomganger som «kjent siden <dato>».
- Ikke endre produktkode, skeletons eller CSS. Forslag bare.
- Skriv hele rapporten til <UTFIL.md> med seksjonene `## Brief-revisjon`, `## Metode`, <rolle-seksjoner>, `## Funn`, `## Tverrgående regler for skill`, `## Ikke verifisert`.
- Svar i chatten KUN med: brief-revisjon (3–8 linjer), antall funn per alvorlighet, de 5 viktigste funnene i én linje hver, 3–8 regler for skill, hva du ikke rakk/kunne verifisere. Norsk bokmål.
```

Eksempel på én-flate-variant (bounded `codex exec`):

```bash
<CODEX> exec -C <HAVEN_ROOT>/CellScaffold "Les .claude/skills/haven-ux-surface-review/SKILL.md og references/rules.md. Vurder Documentation/ConfigurationCatalog/CellConfiguration.conference.public-surface.json som Formålsrådgiver og UX-heuristikkekspert i én rapport. Rendre den offline med web-runtime (references/checks.md §5) og legg skjermbilde ved. Skriv rapporten til Documentation/Reviews/UX_public-surface_<dato>.md. Ikke endre produktfiler. Svar kort som skillen sier."
```
