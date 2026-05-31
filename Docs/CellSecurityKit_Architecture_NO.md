# CellSecurityKit Architecture

Status: initial implementation with first runtime integration started

## Formaal

CellSecurityKit skal vaere et lite, testbart sikkerhetsbibliotek for
CellProtocol. Det skal hjelpe runtime, tester og etter hvert et
Security/ThreatLab CellScaffold med aa oppdage og forklare angrep uten at UI,
transport eller scaffold-kode blir ny sikkerhetsautoritet.

Biblioteket skal beskytte disse grunnreglene:

- Ingen tilgang uten eierbevis, signert contract/capability, oppfylt condition
  eller eksplisitt cell-policy.
- Identity er domain-scoped og maa aldri reduseres til uuid-only.
- Private keys skal bare brukes i vaulten der noekkelen bor.
- Resolver er enforcement boundary for cell-tilgang.
- Denial er en del av protokollkontrakten og skal kunne testes.
- Diagnostikk maa forklare hva brukeren eller policy-laget kan gjoere videre,
  uten aa lekke sensitivt innhold.

## Ikke-maal

Foerste fase skal ikke:

- innfoere ny UI eller nytt CellScaffold
- flytte policy ut av Resolver
- lage en stor observability-stack
- legge til nye tredjepartsavhengigheter
- signere, verifisere eller hente remote data paa vegne av runtime
- auto-utbedre access-denials uten eksplisitt policybeslutning

## Plassering

Foerste versjon ligger under `Sources/CellBase/Security`. Det gir tre fordeler:

1. Ingen ny SwiftPM target eller produktflate foer API-et er stabilt.
2. Koden kan bruke eksisterende CellBase-modeller som
   `IdentitySigningChallenge` uten target-sirkler.
3. CellScaffold kan senere bruke API-et via `CellBase`, mens en egen
   `CellSecurityKit` target kan splittes ut naar formen er moden.

Hvis API-et viser seg stabilt og flere apper skal importere bare
sikkerhetsprimitive, boer vi splitte ut en egen target:

- `CellSecurityKit`: rene modeller, policy og test-hjelpere
- `CellSecurityRuntime`: adapters mot Resolver, Bridge og Flow
- `SecurityWorkbenchCell`: UI/CellScaffold som visualiserer resultatene

## Foerste leveranse

Foerste kodepass etablerer tre smaa byggesteiner. Neste pass koblet
endpoint-policyen inn i CellConfiguration-opploesning og strammet Orchestrator
sin config-mutasjon til write-policy.

### 1. Security event model

`CellSecurityEvent` er et redigert, maskinlesbart hendelsesformat. Det skal
kunne brukes av tester, staging-diagnostikk og fremtidig SecurityWorkbench.

Designvalg:

- Metadata er `[String: String]` for aa holde formatet lett og trygt.
- Actor/resource er egne strukturer, slik at identity fingerprint kan logges
  uten aa logge private data.
- Hendelsen har `requiredAction` og `canAutoResolve`, slik at bruker- eller
  policy-lag kan forklare neste steg.

Eksempler paa event kinds:

- `authorizationDenied`
- `identityMismatch`
- `ownerProofFailed`
- `vaultSignRejected`
- `signingChallengeReplay`
- `configLookupBlocked`
- `transportRejected`

### 2. Signing challenge replay store

`CellSecuritySigningChallengeReplayStore` er en liten actor som kan markere en
`IdentitySigningChallenge` som brukt og avvise samme nonce/scope/fingerprint
ved replay.

Designvalg:

- Nookkel inkluderer identity uuid, public key fingerprint, domain, resource,
  action, audience og nonce.
- Store er memory-only i foerste fase. Det er riktig for prosesslokal bridge og
  verifier-path, men staging/prod kan trenge persistent eller distribuert store.
- Store signerer ingenting. Den er bare en replay-brems.

Neste steg er aa bruke denne i verifier/admission path og eventuelt i
signering-orakel path for aa redusere nytten av capture/replay innenfor
challenge-vinduet.

### 3. Endpoint policy

`CellSecurityEndpointPolicy` validerer endpoint-strenger foer en config lookup
eller source-backed configuration faar bruke dem.

Designvalg:

- Remote endpoints er blokkert som default.
- Local `cell:///Name` og `cell://localhost/Name` kan tillates uten nettverk.
- Remote hoster maa allowlistes eksplisitt.
- Canonicalization lowercaser bare scheme/host og bevarer path case. Det
  hindrer at to case-sensitive cell paths kollapser til samme verdi.

Dette er naa koblet inn i `CellConfigurationPayloadSupport` for direct,
candidate- og source-backed resolution. En malicious configuration skal derfor
ikke kunne bruke privileged requester som confused deputy mot uventede remote
endepunkter uten en eksplisitt allowlist-policy.

## Defensive brukstilfeller

- Avvise replay av signerings-challenges.
- Logge access-denials med konkret remediation.
- Blokkere uventet remote config lookup.
- Teste at wrong-vault og same-uuid/wrong-key aldri gir owner access.
- Lage staging-hendelser for policy-forslag uten aa gi tilgang.

## Offensive testbrukstilfeller

Dette er autorisert intern testing, ikke verktøy for angrep mot andre systemer.

Foerste katalog boer dekke:

- forged uuid med feil signing key
- signing challenge mot feil vault
- replay av signatur/challenge
- config lookup til uallowlistet host
- oversized eller dypt nestet configuration payload
- downgrade-forsok til utrygg transport
- contract som er expired, feil subject eller feil issuer
- proof laundering der credential er gyldig, men subject/context er feil

## Effektivitet

CellSecurityKit skal vaere billig aa bruke i hot paths:

- O(1) replay lookup i dictionary.
- Ingen nettverk, disk eller crypto i security event model.
- Endpoint parsing bruker `URLComponents` og simple set membership.
- Store rydder expired entries opportunistisk ved consume.
- Ingen bakgrunnsjobber eller global singleton i foerste fase.

## Sikkerhetsgrenser

- Eventer er observasjon, ikke autorisasjon.
- Endpoint-policy er input-gate, ikke access grant.
- Replay-store er en ekstra kontroll, ikke erstatning for signature/expiry.
- SecurityWorkbench skal aldri signere med produksjonsidentiteter som default.
- Ingen policy skal baseres paa uuid alene.

## Integrasjon senere

Anbefalt rekkefolge:

1. Koble replay-store inn i verifier/admission path for
   `IdentitySigningChallenge`.
2. Emit `CellSecurityEvent` fra Resolver/Bridge/Orchestrator denial paths.
3. Bygg SecurityWorkbenchCell som leser eventer og kjorer autoriserte probes.
4. Vurder egen SwiftPM target naar API-et har stabil importflate.

## Teststrategi

Foerste testsett skal bare bevise de nye primitive invariantene:

- replay-store godtar foerste challenge og avviser samme challenge igjen
- replay-store avviser expired challenge
- endpoint-policy blokkerer remote endpoints default
- endpoint-policy tillater eksplisitt allowlistet host
- canonicalization bevarer path case
- CellConfiguration resolution blokkerer remote source endpoint default
- Orchestrator config-mutasjon bruker write-policy

Senere testsett skal dekke Resolver/Bridge-integrasjon og staging-probes.
