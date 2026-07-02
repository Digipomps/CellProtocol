# CellSecurityKit Architecture

Status: runtime integration, authorized probe runner, local containment and
CellScaffold SecurityWorkbench are in place

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

- flytte policy ut av Resolver
- lage en stor observability-stack
- legge til nye tredjepartsavhengigheter
- signere, verifisere eller hente remote data paa vegne av runtime
- auto-utbedre access-denials uten eksplisitt policybeslutning
- bruke Workbench eller probes som authority eller auto-grant
- utfoere generell nettverksskanning eller motangrep

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

Foerste kodepass etablerte tre smaa byggesteiner. Neste pass koblet
endpoint-policyen inn i CellConfiguration-opploesning og strammet Orchestrator
sin config-mutasjon til write-policy. Runtime-pass nummer to koblet security
event sink inn i authorization-denials, bridge signing denials og config lookup
blocks, og koblet replay-store inn i inbound bridge signing. Dette passet
la til lokal containment, autorisert probe-runner og en SecurityWorkbench i
CellScaffold.

### 1. Security event model

`CellSecurityEvent` er et redigert, maskinlesbart hendelsesformat. Det skal
kunne brukes av tester, staging-diagnostikk og fremtidig SecurityWorkbench.

Designvalg:

- Metadata er `[String: String]` for aa holde formatet lett og trygt.
- Actor/resource er egne strukturer, slik at identity fingerprint kan logges
  uten aa logge private data.
- Hendelsen har `requiredAction` og `canAutoResolve`, slik at bruker- eller
  policy-lag kan forklare neste steg.
- `InMemoryCellSecurityEventSink` er bounded som default. Den beholder de nyeste
  hendelsene og er ment som lett staging-/workbench-buffer, ikke som varig
  audit-lager.

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

### 4. Local containment

`CellSecurityContainmentPolicy` og `CellSecurityContainmentController` gir
lokale defensive tiltak uten aa flytte authority ut av Resolver eller Vault.

Default er `monitorOnly`. I denne modusen registreres foreslaatte tiltak, men
ingenting blokkeres. Naar policy settes til `localProtection`, kan runtime
bruke tiltakene som lokal beskyttelse:

- rate-limit paa signing/admission-scope
- midlertidig bridge quarantine ved replay eller eksplisitt lokal handling
- revoke/retry challenge som remediation ved replay
- require re-auth for high/critical eventer
- blokkering av remote config lookup naar endpoint-policy sier nei

Viktige sikkerhetsvalg:

- Rate-limit scope for bridge-signering inkluderer bridge id, action, identity
  uuid, signing key fingerprint og identity domain. Det er bevisst ikke
  uuid-only.
- Quarantine stopper en bridge-signering foer vaulten faar signeringsoppdraget.
- Containment-actions kan aldri gi tilgang, mint-e contracts eller signere noe.
- `CellBase.recordSecurityEvent(_:)` er felles inngang: event sink registrerer
  hendelsen og containment-controlleren observerer den med gjeldende policy.
- Containment-controlleren er bounded som default for actions,
  re-authentication actors og rate-limit scopes. Langvarig observability maa
  eksportere aggregerte events eller bruke en dedikert sink.

### 5. Authorized probe runner

`CellSecurityProbeRunner` kjorer deterministiske probe-simuleringer basert paa
`CellSecurityProbeCatalog.baseline`.

Runneren:

- gjoer ikke nettverks-I/O
- nekter probes som deklarerer `performsNetworkIO`
- har `local` og `stagingAllowlist` modus
- krever eksplisitt target endpoint og host allowlist i staging-modus
- returnerer rapport med planned/refused, expected event kind, reasonCode,
  requiredAction og remediation

Dette er et staging-smoke-grunnlag, ikke et generelt angrepsverktøy.

### 6. SecurityWorkbench

CellScaffold har naa `SecurityWorkbenchCell` og
`SecurityWorkbenchConfigurationFactory`.

Workbench viser:

- sanitized `CellSecurityEvent`-liste fra `InMemoryCellSecurityEventSink`
- baseline probe-katalog
- siste probe-run rapport
- containment policy og snapshot
- authority-regler for Identity/Resolver/Vault

Workbench-actions er avgrenset til:

- run local probes
- run staging allowlist probes
- switch monitor/localProtection
- clear in-memory events
- reset containment
- require re-auth for current requester

Workbench kan ikke auto-grante tilgang, utstede Contract, endre Agreement eller
signere data. Den er en menneskelig og testbar observability-/operasjonsflate,
ikke policy-authority.

## Defensive brukstilfeller

- Avvise replay av signerings-challenges.
- Logge access-denials med konkret remediation.
- Blokkere uventet remote config lookup.
- Aktivere lokal rate-limit/quarantine/re-auth i `localProtection`.
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
- In-memory event og containment buffers trimmer eldste entries naar de naar
  sin konfigurerte grense.
- Ingen bakgrunnsjobber eller global singleton i foerste fase.

## Sikkerhetsgrenser

- Eventer er observasjon, ikke autorisasjon.
- Endpoint-policy er input-gate, ikke access grant.
- Replay-store er en ekstra kontroll, ikke erstatning for signature/expiry.
- SecurityWorkbench skal aldri signere med produksjonsidentiteter som default.
- Ingen policy skal baseres paa uuid alene.
- SecurityWorkbench viser bare redigerte eventfelter og skal ikke vise private
  payloads, tokens, raw challenge bytes eller raw signatures.

## Integrasjon senere

Anbefalt rekkefolge:

1. Utvid replay-store-bruk fra inbound bridge signing til flere verifier- og
   admission paths der challenge faktisk konsumeres.
2. Emit `CellSecurityEvent` fra flere Resolver/Orchestrator denial paths og fra
   contract rejection der det finnes stabil reasonCode.
3. Utvid probe-runneren fra deterministic planning til lokale mock-fixtures for
   de viktigste denial-pathene.
4. Legg staging-smoke rundt Workbench/runner med eksplisitt allowlist.
5. Vurder egen SwiftPM target naar API-et har stabil importflate.

## Teststrategi

Foerste testsett skal bare bevise de nye primitive invariantene:

- replay-store godtar foerste challenge og avviser samme challenge igjen
- replay-store avviser expired challenge
- endpoint-policy blokkerer remote endpoints default
- endpoint-policy tillater eksplisitt allowlistet host
- canonicalization bevarer path case
- CellConfiguration resolution blokkerer remote source endpoint default
- Orchestrator config-mutasjon bruker write-policy
- authorization-denial produserer redigert `CellSecurityEvent`
- inbound bridge signing avviser replayed challenge og produserer
  `signingChallengeReplay`
- baseline probe-katalog er local-only og deklarerer expected event/remediation
- containment-policy foreslaar replay/re-auth/quarantine uten grant semantics
- containment-controller rate-limiter bare i `localProtection`
- bridge quarantine stopper inbound signering foer vault-signering
- probe-runner planlegger local catalog og nekter uallowlistet staging target
- SecurityWorkbench viser state, kjorer probes og publiseres i katalogen

Senere testsett skal dekke bredere Resolver/Bridge-integrasjon,
contract-rejection events og staging-probes.
