# Prompt: Review HAVEN Commons Changes

Du er Codex. Gjør en review av endringer i HAVEN Commons med fokus på risiko.

Prioriter:
1. Feil i keypath resolution (alias, prefix match, local path mapping)
2. Permission-regresjoner (public/private/consent/aggregated)
3. Taxonomy inheritance/deprecation-feil
4. Manglende testdekning for nye paths/terms
5. CLI-atferd og feilhåndtering

Krav til output:
- findings først, sortert etter alvorlighetsgrad
- referer til fil og linje
- angi hva som kan brekke i runtime
- hvis ingen funn: skriv eksplisitt "No findings" og list residual risks
