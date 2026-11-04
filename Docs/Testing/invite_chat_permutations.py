#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
"""Generates the invite + chat permutation matrix for HAVEN.

Dimensions: chat surface × invite path × host actor × guest actor × cardinality.
Each combination gets a status from the feasibility rules below, which are
taken from the source map in Docs/Testing/Invite_Chat_Testplan_2026-11-04_NO.md.
Run: python3 Docs/Testing/invite_chat_permutations.py > Docs/Testing/Invite_Chat_Permutasjonsmatrise_2026-11-04.md
"""
from itertools import product

# --- Dimensions ---------------------------------------------------------------

ACTORS = {
    "K":  "Ekte bruker, web (Porthole, FidoUser-sesjon)",
    "KN": "Ekte bruker, native Binding (person-link + X-Haven-Chat-Proof)",
    "P":  "AI-persona med web-konto (HTTP /auth/register + chat/api)",
    "I":  "AI-persona som interop-peer (Swift/Python/Go, haven.interop-peer.v1)",
    "S":  "Swarm VirtualUser (UserSimulationScaffold, bridge-lurker/reader)",
    "D":  "HavenAgentD (agentidentitet, macOS-daemon)",
}

SURFACES = {
    "S1": "Butler Chat / Co-Pilot Chat (cell:///PersonalChatHub, web Porthole + native Binding)",
    "S3": "Konferanse deltakerchat (cell:///ConferenceChatLaunch, /conference-participant)",
    "S4": "Chat MVP (/chat-mvp, delt cell:///Chat, passkey + betalt inngang)",
    "S5": "Arendalsuka deltakerchat (cell:///ArendalsukaParticipantChat)",
    "S6": "Protokoll-ChatCell over bridgehead (CellBase ChatCell + Agreement, InteropPeer)",
    "S7": "SwiftWebScaffold ChatCell (/api/cell/set med rutebevis)",
    "S8": "Assistant Correspondence (agent<->menneske postkasse, /haven/api/assistant-correspondence/v1)",
    "S9": "AgentConversationInbox (Binding<->HavenAgentD prompt/godkjenning)",
}

INVITES = {
    "V1":  "In-app invitasjon (chat/api/invite -> accept/decline)",
    "V2":  "Join-lenke (/chat/join/:token)",
    "V3":  "Ekstern samarbeidslenke (/personal-copilot-v1/collaborate/:token)",
    "V4":  "Offentlig /i/-landing med HavenInviteTicket -> kontaktforespørsel",
    "V5":  "ChatInvitationArtifact + Agreement admission (invitationAccepted/member)",
    "V6":  "Konferanse discovery.startChat / startGroupChat (+ proofChat.*)",
    "V7":  "Arendalsuka connect key / chat.sendRequest",
    "V8":  "Ingen invitasjon: betalt inngang (ensurePaidChatEntry)",
    "V9":  "Assistant-correspondence invite-fil (inviteID/inviteSecret)",
    "V10": "Ingen invitasjon: AgentConversationInbox prompt-sløyfe",
}

CARDINALITIES = ["1:1", "gruppe(3+)"]

# --- Feasibility rules -------------------------------------------------------
# Status: "klar" = eksisterende kode + eksisterende test eller sti,
# "delvis" = koden finnes, men flyten er ikke verifisert ende til ende,
# "gap" = krever ny kode (PDD-kandidat), None = meningsløs kombinasjon.

# Which invite paths lead into which surface.
SURFACE_INVITES = {
    "S1": {"V1": "klar", "V2": "klar", "V3": "klar", "V4": "delvis"},
    "S3": {"V6": "klar", "V5": "delvis"},
    "S4": {"V8": "delvis"},
    "S5": {"V7": "delvis"},
    "S6": {"V5": "klar", "V4": "klar"},
    "S7": {"V5": "gap"},
    "S8": {"V9": "klar"},
    "S9": {"V10": "klar"},
}

# Which actors can be host (inviter/owner) or guest (invitee) on each surface.
SURFACE_ACTORS = {
    #        host                              guest
    "S1": ({"K": "klar", "KN": "delvis", "P": "klar"},
           {"K": "klar", "KN": "delvis", "P": "klar"}),
    "S3": ({"K": "klar", "P": "klar", "KN": "delvis"},
           {"K": "klar", "P": "klar", "KN": "delvis"}),
    "S4": ({"K": "delvis", "P": "delvis"}, {"K": "delvis", "P": "delvis"}),
    "S5": ({"K": "delvis", "P": "delvis"}, {"K": "delvis", "P": "delvis"}),
    "S6": ({"I": "klar", "KN": "delvis"},
           {"I": "klar", "KN": "delvis", "S": "delvis", "D": "gap"}),
    "S7": ({"I": "gap"}, {"I": "gap"}),
    "S8": ({"KN": "klar"}, {"D": "klar"}),
    "S9": ({"KN": "klar"}, {"D": "klar"}),
}

# Surfaces where a group thread exists.
GROUP_OK = {"S1", "S3", "S4", "S6"}

# Invite paths that only make sense for an outsider guest (new account).
OUTSIDER_ONLY = {"V3", "V4"}

RANK = {"klar": 0, "delvis": 1, "gap": 2}


def worst(*statuses):
    return max(statuses, key=lambda s: RANK[s])


def enumerate_cases():
    cases = []
    for sid, vid, host, guest, card in product(SURFACES, INVITES, ACTORS, ACTORS, CARDINALITIES):
        vstatus = SURFACE_INVITES[sid].get(vid)
        if vstatus is None:
            continue
        hosts, guests = SURFACE_ACTORS[sid]
        if host not in hosts or guest not in guests:
            continue
        if card == "gruppe(3+)" and sid not in GROUP_OK:
            continue
        if vid in OUTSIDER_ONLY and guest == "KN":
            # KN must already hold a person-link, so it is never a cold outsider.
            continue
        status = worst(vstatus, hosts[host], guests[guest])
        cases.append((sid, vid, host, guest, card, status))
    return cases


def main():
    cases = enumerate_cases()
    theoretical = len(SURFACES) * len(INVITES) * len(ACTORS) ** 2 * len(CARDINALITIES)
    counts = {s: sum(1 for c in cases if c[5] == s) for s in RANK}
    print("# Invite + chat: permutasjonsmatrise (generert 2026-11-04)\n")
    print("Generert av `Docs/Testing/invite_chat_permutations.py`. Reglene er dokumentert i "
          "`Docs/Testing/Invite_Chat_Testplan_2026-11-04_NO.md`.\n")
    print("| Mål | Verdi |\n|---|---|")
    print(f"| Teoretisk kryssprodukt (flate × invitasjonsvei × vert × gjest × kardinalitet) | {theoretical} |")
    print(f"| Meningsfulle kombinasjoner | {len(cases)} |")
    for s in RANK:
        print(f"| … status `{s}` | {counts[s]} |")
    print()
    print("## Dimensjoner\n")
    for title, table in (("Aktører", ACTORS), ("Flater", SURFACES), ("Invitasjonsveier", INVITES)):
        print(f"### {title}\n")
        print("| Kode | Beskrivelse |\n|---|---|")
        for k, v in table.items():
            print(f"| {k} | {v} |")
        print()
    print("## Flate × invitasjonsvei\n")
    print("| Flate | " + " | ".join(INVITES) + " |")
    print("|---|" + "---|" * len(INVITES))
    for sid in SURFACES:
        row = [SURFACE_INVITES[sid].get(v, "–") for v in INVITES]
        print(f"| {sid} | " + " | ".join(row) + " |")
    print()
    print("## Alle meningsfulle kombinasjoner\n")
    print("| # | Flate | Vei | Vert | Gjest | Kardinalitet | Status |\n|---|---|---|---|---|---|---|")
    for n, (sid, vid, host, guest, card, status) in enumerate(cases, 1):
        print(f"| {n} | {sid} | {vid} | {host} | {guest} | {card} | {status} |")


if __name__ == "__main__":
    main()
