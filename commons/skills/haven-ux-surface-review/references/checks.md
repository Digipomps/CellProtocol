# Sjekker og verktøy

Alle skript kjøres med `python3 -I` fra en arbeidsmappe utenfor repoet; skriv aldri analysefiler inn i repoet før leveransen.

## 1. Inventar

`scripts/surface_inventory.py <repo-rot> <utmappe>` → `inventory.json` + `inventory.md`.
Per JSON-flate: sti, navn, `discovery.purpose/purposeDescription/purposeRefs/interests/menuSlots`, cellReferences, elementtyper (både objekt- og array-form stakker), dybde, knappe-etiketter, tekstprøver, hex-farger, fontSize-fordeling, styleRoles, antall keypath-bindinger, inndatafelt uten etikett, `Image` uten alt.
Legg til for hånd: Swift-fabrikker (`grep -rn -E 'purposeDescription: *"' Sources --include=*.swift`; husk fabrikker som setter feltet via konstant/parameter), `Resources/Views/*.leaf`, `Deployment/porthole/surfaces*.json`.

## 2. Dedup og drift

```bash
python3 -I - <<'EOF2'
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
a=a.get("skeleton",a); b=b.get("skeleton",b)
print("IDENTISK" if a==b else "DRIFT")
EOF2
```
Sorter nøkler og ignorer genererte `id`-UUID-er på Picker før du kaller noe drift.

## 3. Lint-grep (funn på nivå alvorlig eller høyere når de treffer i produksjonsflater)

```bash
# Generisk knappetekst
grep -rn '"label": *"Action"' <skeletons>
# selectionStateKeypath som peker på action
python3 -I -c 'import json,sys,re;[print(p) for p in sys.argv[1:] if re.search(r"selectionStateKeypath\"\s*:\s*\"(?!.*\.state\.)[^\"]+\"", open(p).read())]' <skeletons>
# Internspråk i brukertekst
grep -rn -E '"(text|label|placeholder)": *"[^"]*(purpose://|interest://|keypath|skeleton|AttachmentField|fallback|preview|mock|runtime)' <skeletons>
# Input uten targetKeypath (krever JSON-parsing – se inventory unlabelledInputs og egen sjekk)
# Hex uten bakgrunn: foregroundColor satt, ingen background i filen
for f in <skeletons>; do grep -q foregroundColor "$f" && ! grep -q '"background' "$f" && echo "ENKELTFARGE $f"; done
# Web-maler
grep -o '<html lang="[a-z-]*"' Resources/Views/*.leaf | sort | uniq -c
grep -rn 'HTTP \${' Public/js/*.js
grep -rn 'href="#"' Resources/Views
grep -rno 'render("[a-z_0-9]*"' Sources/App | sed 's/.*render("//;s/"//' | sort -u > /tmp/routes; ls Resources/Views | sed 's/\.leaf$//' | sort > /tmp/views; comm -3 /tmp/routes /tmp/views
```

## 4. Kontrast fra JSON

For hvert `Text`/`Button`/felt: finn `foregroundColor` og nærmeste forelder med `background`/`backgroundColor`; beregn WCAG-kontrast (relativ luminans). Mangler bakgrunn: oppgi rendererstandard som ANTAKELSE (web: `.canvas` i `Public/css/porthole-webo.css`; produkt-/conference-view har mørk bakgrunn, ellers hvit) og krev ett skjermbilde før dommen settes til blokker.

## 5. Offline rendring med web-runtime (ingen Swift-server)

Mønsteret finnes i `CellScaffold/playwright/skeleton-element-catalog.spec.js`: `page.route` som serverer `Public/js/skeleton-runtime.js` og `Public/css/porthole-webo.css`, HTML-skall `<main class="canvas product-view view-mode"><div id="root" class="skeleton-host"></div></main>`, deretter `window.HavenSkeletonRuntime.createRenderer`. Bruk det til å (a) lese `getComputedStyle` på tekst og bakgrunn, (b) se hva `Tabs` uten etiketter heter, (c) se om en `TextArea` uten `targetKeypath` når knappens payload, (d) ta skjermbilde per tilstand (deviceScaleFactor 1 for egen inspeksjon, 2 for bilder til Digipomps). Chromium er forhåndsinstallert i cloud-sesjoner; på Mac brukes repoets Playwright. Dokumentér hvilke keypaths som fikk tomt state.

## 6. Owner-entity-access-sveip

For hver produksjonsflate: finnes `Button`/`Reference`/`Text`+`linkURL` med mål Co-Pilot/egen entitet (`configurationName=Co-Pilot%20Chat`, `addConfiguration`, «Min HAVEN», «Åpne i HAVEN»)? Hvis nei: er flaten skall-rendret, og gir skallet veien for denne konfigurasjonen (les `Public/js/porthole-webo.js`: `isProductSurfaceConfigurationName`, `showProductChrome`, Butler-nav)? Resultat per flate: element / skall-garanti (dokumentert?) / mangler.
