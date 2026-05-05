# Assistant Profiles, Prompts og Context

## Formaal
Prompt- og context-lagring er implementert som typed Vault-dokumenter pa toppen av `VaultCell`.

## Dokumenttyper
- `AtlasPromptDocument`
- `AtlasContextDocument`
- `AtlasAssistantProfile`
- `AtlasModelProviderProfile`
- `AtlasCredentialHandleRecord`

Alle serialiseres som pretty-printed JSON i `VaultNoteRecord.content` og tagges med:
- `atlas.document`
- `atlas.kind.*`
- `atlas.scope.*`

## Scope
Stottede scopes:
- `entity`
- `assistant`
- `purpose`
- `cell`
- `session`

## Prompt-resolusjon
`AtlasPromptResolver` bygger endelig prompt/context i fast lagrekkefolge:
1. entity
2. assistant
3. purpose
4. cell
5. session override

Resultatet inneholder:
- `sections`
- `assembledText`
- `explain`

## Hvorfor Vault
Vault gir allerede:
- versjonsspor via `updatedAtEpochMs`
- menneskelesbar lagring
- tags og queries
- lenker mellom dokumenter

Dette holder Phase 1 liten og additiv.

## Begrensning
Typed Vault-dokumentene er metadata og instrukser. De er ikke et sikkert lager for secrets.
