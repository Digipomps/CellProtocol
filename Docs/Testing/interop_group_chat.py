#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
"""IC-03: group chat (host + two guests) over the haven.interop-peer.v1 protocol.

Extends PyCellProtocol's interop/matrix/run_matrix.py, which only runs 1:1.
For every host language and every (guest1, guest2) pair of the peers given:

- host requires a proven invitation (Agreement condition invitationAccepted)
  and invites both guests in one call; artifacts are matched to guests by
  invitedIdentity.uuid, not by position,
- each guest signs its acceptance on its own node, hands in the proof over
  the authenticated bridge and gets a signed Agreement,
- a guest cannot use the other guest's artifact,
- all three send, all three read the same ordered thread, and the host
  attributes each message to its author,
- revoking guest1 shuts guest1 out at once while guest2 keeps reading and
  sending, and the host still sees everything.

Run (from any directory):
    python3 Docs/Testing/interop_group_chat.py \
        --matrix-dir /path/to/PyCellProtocol/interop/matrix \
        --peer python="python3 -m cellprotocol_scaffold.interop_peer" \
        --peer go=/path/to/interop-peer \
        --out TESTRESULT-group.md
Exit code 0 only when every step passes.
"""
import argparse
import itertools
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--matrix-dir", required=True, help="directory holding run_matrix.py")
    parser.add_argument("--peer", action="append", required=True, help="lang=command")
    parser.add_argument("--out", help="write the result table (Markdown) here")
    parser.add_argument("--port", type=int, default=18500)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    sys.path.insert(0, args.matrix_dir)
    from run_matrix import GUEST_GRANTS, Peer, Steps, agreed, refused  # noqa: E402

    peers = dict(p.split("=", 1) for p in args.peer)
    langs = list(peers)
    port = args.port
    table = {}
    for host_lang, (g1_lang, g2_lang) in itertools.product(langs, itertools.product(langs, repeat=2)):
        started = []
        steps = Steps()
        key = (host_lang, g1_lang, g2_lang)
        try:
            host = Peer(host_lang, peers[host_lang], "Host"); started.append(host)
            g1 = Peer(g1_lang, peers[g1_lang], "Guest1"); started.append(g1)
            g2 = Peer(g2_lang, peers[g2_lang], "Guest2"); started.append(g2)
            url = host.op("serve", port=port)["chatURL"]
            run_group(host, g1, g2, url, steps, GUEST_GRANTS, agreed, refused)
        except Exception as error:  # noqa: BLE001
            if not steps.done or steps.done[-1][1]:
                steps.check("flow ran to the end", False, f"{type(error).__name__}: {error}")
        finally:
            for peer in started:
                peer.close()
            port += 1
        passed = sum(ok for _, ok, _ in steps.done)
        table[key] = (passed, len(steps.done), steps.done)
        mark = "OK  " if passed == len(steps.done) else "FAIL"
        print(f"{mark} group host={host_lang:6} guests={g1_lang}+{g2_lang} {passed}/{len(steps.done)}")
        for name, ok, detail in steps.done:
            if args.verbose or not ok:
                print(f"       {'ok ' if ok else 'XX '} {name}" + (f"  {detail}" if detail else ""))
    all_green = all(p == n for p, n, _ in table.values())
    if args.out:
        lines = [
            "# Interop group chat (IC-03)",
            "",
            f"Run {time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime())}. Host + two guests. Each cell is steps passed / steps run.",
            "",
            "| host | guest1 | guest2 | result |",
            "|---|---|---|---|",
        ]
        for (h, a, b), (p, n, _) in table.items():
            lines.append(f"| {h} | {a} | {b} | {'✅' if p == n else '❌'} {p}/{n} |")
        failures = [(k, s) for k, (p, n, s) in table.items() if p != n]
        if failures:
            lines += ["", "## Failed steps", ""]
            for (h, a, b), done in failures:
                for name, ok, detail in done:
                    if not ok:
                        lines.append(f"- host={h} guests={a}+{b}: {name}. {detail}")
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    print("all green" if all_green else "NOT all green")
    return 0 if all_green else 1


def run_group(host, g1, g2, url, steps, guest_grants, agreed, refused):
    conditions = host.set("chat", "audience.admissionConditions", ["invitationAccepted"])
    steps.check("host requires a proven invitation", conditions == ["invitationAccepted"], conditions)
    host.set("chat", "audience.inviteIdentities", [g1.identity, g2.identity])
    artifacts = host.set("chat", "audience.generateInvitationArtifacts", True)
    by_invitee = {a["invitedIdentity"]["uuid"]: a for a in artifacts}
    steps.check("one artifact per guest", set(by_invitee) == {g1.uuid, g2.uuid}, [a.get("invitedIdentity", {}).get("uuid") for a in artifacts])
    a1, a2 = by_invitee[g1.uuid], by_invitee[g2.uuid]

    acc2 = g2.set("home", "audience.generateInvitationAcceptance", a2)
    wrong = lambda: g2.remote(url, "set", "audience.acceptInvitationArtifact", {"artifact": a1, "acceptance": acc2})  # noqa: E731
    steps.check("guest2 cannot hand in guest1's artifact", refused(wrong) or not (isinstance(wrong(), dict) and wrong().get("status") == "accepted"))

    for guest, artifact in ((g1, a1), (g2, a2)):
        acceptance = guest.set("home", "audience.generateInvitationAcceptance", artifact)
        accepted = guest.remote(url, "set", "audience.acceptInvitationArtifact", {"artifact": artifact, "acceptance": acceptance})
        steps.check(f"{guest.lang} {guest.identity.get('displayName', '')} proof accepted", isinstance(accepted, dict) and accepted.get("status") == "accepted", accepted)
        steps.check(f"{guest.lang} {guest.identity.get('displayName', '')} gets a signed Agreement", agreed(lambda: guest.op("agree", url=url, keys=guest_grants)))

    m1, m2, m3 = f"m1 fra {g1.lang}", f"m2 fra {g2.lang}", f"m3 fra {host.lang}"
    steps.check("guest1 sends", (g1.remote(url, "set", "sendMessage", m1) or {}).get("status") == "sent")
    steps.check("guest2 sends", (g2.remote(url, "set", "sendMessage", m2) or {}).get("status") == "sent")
    host.set("chat", "sendMessage", m3)
    expected = [m1, m2, m3]
    for reader in (g1, g2):
        got = reader.remote(url, "get", "messages")
        contents = [m.get("content") for m in got] if isinstance(got, list) else got
        steps.check(f"{reader.identity.get('displayName', '')} reads the same ordered thread", contents == expected, contents)
    owners = [m.get("ownerUUID") for m in host.get("chat", "messages")]
    steps.check("host attributes every message to its author", owners == [g1.uuid, g2.uuid, host.uuid], owners)

    host.set("chat", "audience.revokeInvites", [g1.uuid])
    steps.check("revoked guest1 refused to read", refused(lambda: g1.remote(url, "get", "messages")))
    steps.check("revoked guest1 refused to send", refused(lambda: g1.remote(url, "set", "sendMessage", "slipp meg inn igjen")))
    m4 = f"m4 fra {g2.lang} etter revoke"
    steps.check("guest2 still sends", (g2.remote(url, "set", "sendMessage", m4) or {}).get("status") == "sent")
    got = g2.remote(url, "get", "messages")
    contents = [m.get("content") for m in got] if isinstance(got, list) else got
    steps.check("guest2 still reads, now four messages", contents == expected + [m4], contents)
    host_contents = [m.get("content") for m in host.get("chat", "messages")]
    steps.check("host sees all four", host_contents == expected + [m4], host_contents)


if __name__ == "__main__":
    sys.exit(main())
