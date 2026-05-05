# Iteration 3 Prompt - Skeleton Parity + File Upload

Mål:
- migrer aktiv Swift-render-path til kun `SkeletonView`
- lukk gap mot web skeleton-runtime uten å brekke eksisterende flows
- dokumenter alt som bevisst ikke videreføres fra gammel renderer
- design nytt `FileUpload`-element som persisterer kun via celler

Teknikk:
1. Lag en eksplisitt gap-matrise (`SkeletonElementView` vs `SkeletonView` vs web runtime).
2. Migrer kallsteder først, før feature-portering.
3. Porter kun funksjoner som er nødvendige for kompatibilitet/regresjonsfrihet.
4. Verifiser med bygg + målrettede tester.
5. Oppdater dokumentasjon med:
   - hva som er gjort
   - hva som er utelatt
   - konsekvenser
   - neste steg

Done-kriterier:
- ingen aktive referanser til gammel renderer i Porthole render-path
- bygget passerer
- skeleton tester passerer
- dokumentasjon + iterasjonsprompt er oppdatert
