# Invite + chat: permutasjonsmatrise (generert 2026-11-04)

Generert av `Docs/Testing/invite_chat_permutations.py`. Reglene er dokumentert i `Docs/Testing/Invite_Chat_Testplan_2026-11-04_NO.md`.

| Mål | Verdi |
|---|---|
| Teoretisk kryssprodukt (flate × invitasjonsvei × vert × gjest × kardinalitet) | 5760 |
| Meningsfulle kombinasjoner | 139 |
| … status `klar` | 38 |
| … status `delvis` | 92 |
| … status `gap` | 9 |

## Dimensjoner

### Aktører

| Kode | Beskrivelse |
|---|---|
| K | Ekte bruker, web (Porthole, FidoUser-sesjon) |
| KN | Ekte bruker, native Binding (person-link + X-Haven-Chat-Proof) |
| P | AI-persona med web-konto (HTTP /auth/register + chat/api) |
| I | AI-persona som interop-peer (Swift/Python/Go, haven.interop-peer.v1) |
| S | Swarm VirtualUser (UserSimulationScaffold, bridge-lurker/reader) |
| D | HavenAgentD (agentidentitet, macOS-daemon) |

### Flater

| Kode | Beskrivelse |
|---|---|
| S1 | Butler Chat / Co-Pilot Chat (cell:///PersonalChatHub, web Porthole + native Binding) |
| S3 | Konferanse deltakerchat (cell:///ConferenceChatLaunch, /conference-participant) |
| S4 | Chat MVP (/chat-mvp, delt cell:///Chat, passkey + betalt inngang) |
| S5 | Arendalsuka deltakerchat (cell:///ArendalsukaParticipantChat) |
| S6 | Protokoll-ChatCell over bridgehead (CellBase ChatCell + Agreement, InteropPeer) |
| S7 | SwiftWebScaffold ChatCell (/api/cell/set med rutebevis) |
| S8 | Assistant Correspondence (agent<->menneske postkasse, /haven/api/assistant-correspondence/v1) |
| S9 | AgentConversationInbox (Binding<->HavenAgentD prompt/godkjenning) |

### Invitasjonsveier

| Kode | Beskrivelse |
|---|---|
| V1 | In-app invitasjon (chat/api/invite -> accept/decline) |
| V2 | Join-lenke (/chat/join/:token) |
| V3 | Ekstern samarbeidslenke (/personal-copilot-v1/collaborate/:token) |
| V4 | Offentlig /i/-landing med HavenInviteTicket -> kontaktforespørsel |
| V5 | ChatInvitationArtifact + Agreement admission (invitationAccepted/member) |
| V6 | Konferanse discovery.startChat / startGroupChat (+ proofChat.*) |
| V7 | Arendalsuka connect key / chat.sendRequest |
| V8 | Ingen invitasjon: betalt inngang (ensurePaidChatEntry) |
| V9 | Assistant-correspondence invite-fil (inviteID/inviteSecret) |
| V10 | Ingen invitasjon: AgentConversationInbox prompt-sløyfe |

## Flate × invitasjonsvei

| Flate | V1 | V2 | V3 | V4 | V5 | V6 | V7 | V8 | V9 | V10 |
|---|---|---|---|---|---|---|---|---|---|---|
| S1 | klar | klar | klar | delvis | – | – | – | – | – | – |
| S3 | – | – | – | – | delvis | klar | – | – | – | – |
| S4 | – | – | – | – | – | – | – | delvis | – | – |
| S5 | – | – | – | – | – | – | delvis | – | – | – |
| S6 | – | – | – | klar | klar | – | – | – | – | – |
| S7 | – | – | – | – | gap | – | – | – | – | – |
| S8 | – | – | – | – | – | – | – | – | klar | – |
| S9 | – | – | – | – | – | – | – | – | – | klar |

## Alle meningsfulle kombinasjoner

| # | Flate | Vei | Vert | Gjest | Kardinalitet | Status |
|---|---|---|---|---|---|---|
| 1 | S1 | V1 | K | K | 1:1 | klar |
| 2 | S1 | V1 | K | K | gruppe(3+) | klar |
| 3 | S1 | V1 | K | KN | 1:1 | delvis |
| 4 | S1 | V1 | K | KN | gruppe(3+) | delvis |
| 5 | S1 | V1 | K | P | 1:1 | klar |
| 6 | S1 | V1 | K | P | gruppe(3+) | klar |
| 7 | S1 | V1 | KN | K | 1:1 | delvis |
| 8 | S1 | V1 | KN | K | gruppe(3+) | delvis |
| 9 | S1 | V1 | KN | KN | 1:1 | delvis |
| 10 | S1 | V1 | KN | KN | gruppe(3+) | delvis |
| 11 | S1 | V1 | KN | P | 1:1 | delvis |
| 12 | S1 | V1 | KN | P | gruppe(3+) | delvis |
| 13 | S1 | V1 | P | K | 1:1 | klar |
| 14 | S1 | V1 | P | K | gruppe(3+) | klar |
| 15 | S1 | V1 | P | KN | 1:1 | delvis |
| 16 | S1 | V1 | P | KN | gruppe(3+) | delvis |
| 17 | S1 | V1 | P | P | 1:1 | klar |
| 18 | S1 | V1 | P | P | gruppe(3+) | klar |
| 19 | S1 | V2 | K | K | 1:1 | klar |
| 20 | S1 | V2 | K | K | gruppe(3+) | klar |
| 21 | S1 | V2 | K | KN | 1:1 | delvis |
| 22 | S1 | V2 | K | KN | gruppe(3+) | delvis |
| 23 | S1 | V2 | K | P | 1:1 | klar |
| 24 | S1 | V2 | K | P | gruppe(3+) | klar |
| 25 | S1 | V2 | KN | K | 1:1 | delvis |
| 26 | S1 | V2 | KN | K | gruppe(3+) | delvis |
| 27 | S1 | V2 | KN | KN | 1:1 | delvis |
| 28 | S1 | V2 | KN | KN | gruppe(3+) | delvis |
| 29 | S1 | V2 | KN | P | 1:1 | delvis |
| 30 | S1 | V2 | KN | P | gruppe(3+) | delvis |
| 31 | S1 | V2 | P | K | 1:1 | klar |
| 32 | S1 | V2 | P | K | gruppe(3+) | klar |
| 33 | S1 | V2 | P | KN | 1:1 | delvis |
| 34 | S1 | V2 | P | KN | gruppe(3+) | delvis |
| 35 | S1 | V2 | P | P | 1:1 | klar |
| 36 | S1 | V2 | P | P | gruppe(3+) | klar |
| 37 | S1 | V3 | K | K | 1:1 | klar |
| 38 | S1 | V3 | K | K | gruppe(3+) | klar |
| 39 | S1 | V3 | K | P | 1:1 | klar |
| 40 | S1 | V3 | K | P | gruppe(3+) | klar |
| 41 | S1 | V3 | KN | K | 1:1 | delvis |
| 42 | S1 | V3 | KN | K | gruppe(3+) | delvis |
| 43 | S1 | V3 | KN | P | 1:1 | delvis |
| 44 | S1 | V3 | KN | P | gruppe(3+) | delvis |
| 45 | S1 | V3 | P | K | 1:1 | klar |
| 46 | S1 | V3 | P | K | gruppe(3+) | klar |
| 47 | S1 | V3 | P | P | 1:1 | klar |
| 48 | S1 | V3 | P | P | gruppe(3+) | klar |
| 49 | S1 | V4 | K | K | 1:1 | delvis |
| 50 | S1 | V4 | K | K | gruppe(3+) | delvis |
| 51 | S1 | V4 | K | P | 1:1 | delvis |
| 52 | S1 | V4 | K | P | gruppe(3+) | delvis |
| 53 | S1 | V4 | KN | K | 1:1 | delvis |
| 54 | S1 | V4 | KN | K | gruppe(3+) | delvis |
| 55 | S1 | V4 | KN | P | 1:1 | delvis |
| 56 | S1 | V4 | KN | P | gruppe(3+) | delvis |
| 57 | S1 | V4 | P | K | 1:1 | delvis |
| 58 | S1 | V4 | P | K | gruppe(3+) | delvis |
| 59 | S1 | V4 | P | P | 1:1 | delvis |
| 60 | S1 | V4 | P | P | gruppe(3+) | delvis |
| 61 | S3 | V5 | K | K | 1:1 | delvis |
| 62 | S3 | V5 | K | K | gruppe(3+) | delvis |
| 63 | S3 | V5 | K | KN | 1:1 | delvis |
| 64 | S3 | V5 | K | KN | gruppe(3+) | delvis |
| 65 | S3 | V5 | K | P | 1:1 | delvis |
| 66 | S3 | V5 | K | P | gruppe(3+) | delvis |
| 67 | S3 | V5 | KN | K | 1:1 | delvis |
| 68 | S3 | V5 | KN | K | gruppe(3+) | delvis |
| 69 | S3 | V5 | KN | KN | 1:1 | delvis |
| 70 | S3 | V5 | KN | KN | gruppe(3+) | delvis |
| 71 | S3 | V5 | KN | P | 1:1 | delvis |
| 72 | S3 | V5 | KN | P | gruppe(3+) | delvis |
| 73 | S3 | V5 | P | K | 1:1 | delvis |
| 74 | S3 | V5 | P | K | gruppe(3+) | delvis |
| 75 | S3 | V5 | P | KN | 1:1 | delvis |
| 76 | S3 | V5 | P | KN | gruppe(3+) | delvis |
| 77 | S3 | V5 | P | P | 1:1 | delvis |
| 78 | S3 | V5 | P | P | gruppe(3+) | delvis |
| 79 | S3 | V6 | K | K | 1:1 | klar |
| 80 | S3 | V6 | K | K | gruppe(3+) | klar |
| 81 | S3 | V6 | K | KN | 1:1 | delvis |
| 82 | S3 | V6 | K | KN | gruppe(3+) | delvis |
| 83 | S3 | V6 | K | P | 1:1 | klar |
| 84 | S3 | V6 | K | P | gruppe(3+) | klar |
| 85 | S3 | V6 | KN | K | 1:1 | delvis |
| 86 | S3 | V6 | KN | K | gruppe(3+) | delvis |
| 87 | S3 | V6 | KN | KN | 1:1 | delvis |
| 88 | S3 | V6 | KN | KN | gruppe(3+) | delvis |
| 89 | S3 | V6 | KN | P | 1:1 | delvis |
| 90 | S3 | V6 | KN | P | gruppe(3+) | delvis |
| 91 | S3 | V6 | P | K | 1:1 | klar |
| 92 | S3 | V6 | P | K | gruppe(3+) | klar |
| 93 | S3 | V6 | P | KN | 1:1 | delvis |
| 94 | S3 | V6 | P | KN | gruppe(3+) | delvis |
| 95 | S3 | V6 | P | P | 1:1 | klar |
| 96 | S3 | V6 | P | P | gruppe(3+) | klar |
| 97 | S4 | V8 | K | K | 1:1 | delvis |
| 98 | S4 | V8 | K | K | gruppe(3+) | delvis |
| 99 | S4 | V8 | K | P | 1:1 | delvis |
| 100 | S4 | V8 | K | P | gruppe(3+) | delvis |
| 101 | S4 | V8 | P | K | 1:1 | delvis |
| 102 | S4 | V8 | P | K | gruppe(3+) | delvis |
| 103 | S4 | V8 | P | P | 1:1 | delvis |
| 104 | S4 | V8 | P | P | gruppe(3+) | delvis |
| 105 | S5 | V7 | K | K | 1:1 | delvis |
| 106 | S5 | V7 | K | P | 1:1 | delvis |
| 107 | S5 | V7 | P | K | 1:1 | delvis |
| 108 | S5 | V7 | P | P | 1:1 | delvis |
| 109 | S6 | V4 | KN | I | 1:1 | delvis |
| 110 | S6 | V4 | KN | I | gruppe(3+) | delvis |
| 111 | S6 | V4 | KN | S | 1:1 | delvis |
| 112 | S6 | V4 | KN | S | gruppe(3+) | delvis |
| 113 | S6 | V4 | KN | D | 1:1 | gap |
| 114 | S6 | V4 | KN | D | gruppe(3+) | gap |
| 115 | S6 | V4 | I | I | 1:1 | klar |
| 116 | S6 | V4 | I | I | gruppe(3+) | klar |
| 117 | S6 | V4 | I | S | 1:1 | delvis |
| 118 | S6 | V4 | I | S | gruppe(3+) | delvis |
| 119 | S6 | V4 | I | D | 1:1 | gap |
| 120 | S6 | V4 | I | D | gruppe(3+) | gap |
| 121 | S6 | V5 | KN | KN | 1:1 | delvis |
| 122 | S6 | V5 | KN | KN | gruppe(3+) | delvis |
| 123 | S6 | V5 | KN | I | 1:1 | delvis |
| 124 | S6 | V5 | KN | I | gruppe(3+) | delvis |
| 125 | S6 | V5 | KN | S | 1:1 | delvis |
| 126 | S6 | V5 | KN | S | gruppe(3+) | delvis |
| 127 | S6 | V5 | KN | D | 1:1 | gap |
| 128 | S6 | V5 | KN | D | gruppe(3+) | gap |
| 129 | S6 | V5 | I | KN | 1:1 | delvis |
| 130 | S6 | V5 | I | KN | gruppe(3+) | delvis |
| 131 | S6 | V5 | I | I | 1:1 | klar |
| 132 | S6 | V5 | I | I | gruppe(3+) | klar |
| 133 | S6 | V5 | I | S | 1:1 | delvis |
| 134 | S6 | V5 | I | S | gruppe(3+) | delvis |
| 135 | S6 | V5 | I | D | 1:1 | gap |
| 136 | S6 | V5 | I | D | gruppe(3+) | gap |
| 137 | S7 | V5 | I | I | 1:1 | gap |
| 138 | S8 | V9 | KN | D | 1:1 | klar |
| 139 | S9 | V10 | KN | D | 1:1 | klar |
