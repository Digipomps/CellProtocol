# CellProtocol Security Development Guide

Status: aktiv utviklingsregel for HAVEN/CellProtocol

## Formaal

Denne guiden skal brukes naar en endring beroerer Identity, Entity,
Resolver, Agreement/Contract, Bridge, Vault, Skeleton public surfaces,
persisted cells eller annen tilgang til privat state.

Maalet er enkelt: eieren av en Entity skal vaere den eneste som har tilgang
til data i entiteten, med mindre eieren eksplisitt har gitt andre tilgang via
signert contract/capability, oppfylt condition eller annen konkret policy som
Resolver/Cell-en kan verifisere.

## Grunnregler

- Ingen authority uten owner proof, signert contract/capability, oppfylt
  condition eller eksplisitt cell-policy.
- Identity er domain-scoped og noekkelbundet. UUID alene er aldri nok.
- Private keys skal bare brukes i vaulten der noekkelen bor.
- Bridge/proxy kan be om signering, men skal aldri eie private keys eller bli
  policy-authority.
- Resolver/GeneralCell er enforcement boundary for cell-tilgang.
- UI, Skeleton, QR, deep links og transportpayloads er aldri authority alene.
- Denial er en del av protokollen: den skal vaere testbar, maskinlesbar og gi
  `reasonCode` og `requiredAction` naar bruker eller policy kan loese saken.
- Security events er observasjon. De gir aldri tilgang.
- Containment er lokal beskyttelse. Det kan deny, rate-limit, quarantine,
  revoke/retry challenge eller kreve re-auth, men aldri gi tilgang.

## PR-sjekkliste

Foer merge skal en sikkerhetsberoerende PR svare paa dette:

1. Hvilken protected resource berøres?
2. Hvilken action/keypath utføres?
3. Hvem er requester, og hvilket identity domain gjelder?
4. Hvilken proof path gir authority?
5. Finnes det allowed- og denied-tester?
6. Hva skjer ved same UUID med feil public key?
7. Hva skjer ved feil vault eller manglende private key?
8. Hva skjer ved expired, missing eller replayed signing challenge?
9. Lekker events, logs, Skeleton, public read models eller diagnostics private
   payloads, secrets, tokens eller raw signing data?
10. Faar brukeren eller policy-laget en konkret `requiredAction` naar tilgang
    kan loeses med scaffold-linking, proof eller ny contract?

Hvis svaret paa ett av punktene er uklart, skal PR-en stoppe til authority path
og denial-kontrakt er tydelig.

## Ikke Gjoer Dette

- Ikke sammenlign bare `uuid` for ownership eller membership.
- Ikke legg inn midlertidige bypasses for demo, preview eller staging.
- Ikke la transport, web socket, bridge eller UI bestemme access-policy.
- Ikke signer raw payloads naar pathen forventer `IdentitySigningChallenge`.
- Ikke la en bridge signere med en identity som ikke finnes i lokal signing
  vault med matchende public key.
- Ikke auto-grant tilgang fra QR/deep link/config lookup uten signert proof.
- Ikke eksponer private Entity-data i SecurityEvent metadata.
- Ikke bruk offensive probes mot eksterne systemer eller ikke-allowlistede
  staging-miljoer.
- Ikke la SecurityWorkbench, staging-smoke eller probe-runner autoutstede
  contracts, grants eller proofs.

## Identity Og Vault

En Identity-reference er gyldig bare naar UUID og public signing key/fingerprint
matcher den trusted identity som er lagret eller kontraktsfestet.

Naar en Identity dekodes fra persistent storage skal den gjenopprette public
key-materiale og default vault-reference, men den skal ikke faa owner authority
foer proof eller signert contract faktisk verifiseres.

Vault-regel:

- Lokal vault kan signere bare for identiteter den har private key for.
- Presented Identity maa ha samme public signing key som stored identity.
- BridgeIdentityVault er en proxy og skal ikke mint-e eller gjenopprette lokale
  identities.
- Replay-store skal brukes der en signing challenge faktisk konsumeres av en
  signer/verifier. Proxy-stier skal validere challenge shape, men ikke brenne
  en legitim challenge foer signerende boundary er naadd.
- Rate-limit og andre containment scopes skal inkludere public key fingerprint
  og domain der dette finnes. Ikke lag defensive state som bare skiller paa
  UUID naar noekkelbinding finnes.

## Contracts Og Conditions

Agreement er forslag/forhandlingsflate. Contract er signert snapshot av en
Agreement og skal brukes som verifiserbar authority.

En contract maa avvises naar:

- subject ikke matcher requester med public key/fingerprint
- issuer ikke matcher eier eller autorisert utsteder
- signatory ikke matcher trusted identity
- domain/resource/action ikke dekker requested access
- condition ikke er oppfylt
- contract er expired, revoked eller tampered

Nye conditions og grants skal alltid ha minst en allowed-test og en denied-test.

## Security Events

Runtime skal bruke `CellSecurityEvent` for security-relevante avslag:

- `authorizationDenied`
- `identityMismatch`
- `ownerProofFailed`
- `vaultSignRejected`
- `signingChallengeReplay`
- `configLookupBlocked`
- `contractRejected`
- `transportRejected`

Event metadata skal vaere redigert. Bruk identity UUID, public key fingerprint,
domain, resource, action og reasonCode. Ikke legg private payloads, credentials,
tokens, raw signatures eller raw challenge bytes i event metadata.

## Offensive Probes

Offensive tiltak betyr autoriserte lokale probes og aktiv lokal containment,
ikke motangrep.

Foerste probe-katalog skal dekke:

- forged UUID med feil public key
- wrong-vault signing
- replayed signing challenge
- expired, wrong-domain eller wrong-audience challenge
- malformed contract
- remote config lookup uten allowlist
- oversized configuration payload
- unknown bridge command
- proof/context mismatch

Alle probes skal deklarere forventet event kind, reasonCode, requiredAction og
remediation. Probes skal som default vaere `localOnly` og `performsNetworkIO ==
false`.

Staging-probes skal bare kjoeres via eksplisitt allowlist. En staging-runner
skal nekte target uten host allowlist, og skal ikke bli et generelt nettverks-
eller angrepsverktøy. SecurityWorkbench kan vise rapport og foreslaa
remediation, men skal ikke auto-grante tilgang.

## Containment Og Workbench

`monitorOnly` er trygg default. Den registrerer events og foreslaatte tiltak,
men blokkerer ikke.

`localProtection` kan brukes naar runtime skal beskytte seg lokalt:

- rate-limit signing/admission-scope
- quarantine bridge midlertidig
- kreve re-auth for high/critical eventer
- revoke/retry signing challenge
- blokkere remote config lookup som endpoint-policy avviser

SecurityWorkbench skal brukes som menneskelig operasjonsflate:

- se redigerte events
- se authority path og reasonCode
- kjoere autoriserte local/staging-allowlist probes
- bytte monitor/protection
- reset containment naar operatoren har vurdert situasjonen

SecurityWorkbench skal aldri vaere policy-authority. Resolver/GeneralCell,
vault og signerte contracts/proofs er fortsatt kilden til authority.

## Minimumstester

For hver sikkerhetsendring:

- allowed path
- denied path
- same UUID / wrong key
- feil eller manglende vault
- missing, expired eller replayed challenge
- feil subject, issuer, signatory eller domain i contract/proof
- event/log/public read model uten private payload-lekkasje

For shared protocol behavior skal `swift test` kjoeres foer merge.
