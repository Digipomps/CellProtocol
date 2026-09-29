# Lazy authentication — analyse

Skrevet natt til 28. august 2026 av Claude. **Ingen kode er endret.**
Codex startet oppgaven 27.08 kl. 17:26, skrev avgrensningen under, og stoppet
der. `Sources/CellApple/IdentityVault.swift` er urørt.

## Formål

Brukeren skal promptes for Touch ID **når vaulten åpnes** — ikke ved hver
appstart.

## Mekanismen, slik den faktisk er

`IdentityVault` er en actor. `initialize()` kaller `authenticatev2()`
ubetinget, som kjører `LAContext.evaluatePolicy` og deretter
`finishAuthentication()`.

`finishAuthentication()` gjør to ting som henger sammen:

1. henter `mainSecret` via `scopedSecretData(tag:minimumLength:)`
2. dekrypterer og laster hele identitetskatalogen fra `Identities.crypt`

Punkt 2 er avhengig av punkt 1: filen er kryptert med `mainSecret`. Og
`mainSecret` ligger i nøkkelringen bak

```swift
SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                .userPresence, nil)
```

Nøkkelringen håndhever altså brukertilstedeværelse selv. Den autentiserte
`LAContext`-en sendes videre som `kSecUseAuthenticationContext` i hver
etterfølgende spørring, slik at én autentisering dekker resten av økten.

**Konsekvens:** vaultens innhold kan ikke leses uten opplåsing. Lat
autentisering betyr derfor «lås opp ved første *vault-tilgang*», ikke «ved
første privatnøkkel-tilgang». Det er nøyaktig det formålet sier, men det er en
annen avgrensning enn oppdraget først antok.

## Hvor prompten faktisk kommer fra

Appen har allerede en bevisst totrinnsmodell, med denne kommentaren i
`BindingRuntimeBootstrap.ensureInfrastructureBaseline()`:

> The app intentionally transitions from a prompt-free startup vault
> to the authenticated vault.

- `ensureInfrastructureBaseline()` — promptfri. Bruker
  `BindingStartupIdentityVault`, en ren minne-vault som genererer ferske
  P256-nøkler per prosess og aldri rører nøkkelringen.
- `ensureBaseline()` — kaller `IdentityVault.shared.initialize()`. **Her kommer
  Touch ID-dialogen.**

## Defekt 1 — avbrutt autentisering blir spurt om igjen

```swift
let task = Task {
    do {
        try await self.authenticatev2()
        self.finishInitialization()      // initialized = true
    } catch {
        CellBase.diagnosticLog("Authenticate failed with error: \(error)", domain: .identity)
        self.resetInitializationTask()   // initialized forblir false
    }
}
```

Feiler autentiseringen — eller avbryter brukeren — settes `initialized` aldri.
Neste `ensureBaseline()` starter en ny task og en **ny dialog**.

Og kalleren retryer. I `ContentView` (rundt linje 5355):

```swift
await BindingRuntimeBootstrap.ensureBaseline()
… AppInitializer.initialize() …
await BindingRuntimeBootstrap.ensureBaseline()     // igjen, umiddelbart
…
for attempt in 1...60 {                            // 250 ms mellom hver
    if attempt == 1 || attempt.isMultiple(of: 10) {
        await BindingRuntimeBootstrap.ensureBaseline()   // og igjen
    }
}
```

Avbryter du dialogen én gang, kan du bli spurt inntil sju ganger til per
konfigurasjonslasting. Det finnes ingen «brukeren sa nei»-tilstand som stopper
spørringen. Dette er committet kode, ikke uforpliktet arbeid.

## Defekt 2 — ivrig autentisering i initialize()

Prompten kommer fordi runtime-bootstrappen vil ha en autentisert vault før den
laster en konfigurasjon — ikke fordi en privat nøkkel trengs. Det er dette lat
opplåsing skal fjerne.

Verdt å merke seg: `authenticatedRuntimeIsReady` sjekker
`CellBase.defaultIdentityVault is IdentityVault` — altså **typen**, ikke om
vaulten er låst opp. Slutter `initialize()` å autentisere, blir denne sjekken
sann uten opplåsing, retry-løkken avsluttes, og alt fungerer. Det passer
teknisk, men navnet lyver allerede i dag og ville lyve mer. Den bør enten
omdøpes eller bevisst uttrykke opplåsingstilstand.

## Anbefalt rekkefølge

1. **Defekt 1 først.** Den er committet, den er den brukeren merker mest, og
   den er uavhengig av resten. Krever én beslutning fra Kjetil: skal avbrutt
   autentisering regnes som «ikke spør igjen før brukeren ber om det», eller
   skal noe kunne be på nytt? Uten den beslutningen kan ikke semantikken
   skrives riktig.
2. **Deretter defekt 2.** `initialize()` autentiserer ikke; en idempotent
   `ensureUnlocked()` på actoren kaller `authenticatev2()` ved første tilgang
   til vaultinnhold — det vil si alt som leser `identities`,
   `identitiesDictionary`, `identitiesUUIDDictionary` eller `mainSecret`, ikke
   bare privatnøkkel-metodene.
3. **Til slutt** `authenticatedRuntimeIsReady`.

## Hvorfor jeg ikke skrev koden

Semantikken for avbrutt autentisering er en beslutning om brukerkontroll over
egen vault, ikke en implementasjonsdetalj — og dette er en personverngrense i
et repo uten branch protection, med andres uforpliktede arbeid i treet.
