#!/usr/bin/env python3
"""Two real Network processes; only a synthetic, unresolvable invitation is broadcast."""
import argparse
import base64
import json
import pathlib
import secrets
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--binary", required=True, type=pathlib.Path)
args = parser.parse_args()
binary = str(args.binary.resolve())
offer = dict(schema="haven.nearby-link-offer.v1", origin="https://staging.haven.digipomps.org",
             offerID=secrets.token_hex(32), expiresAt=int(time.time()) + 25)
link = "haven://nearby-link?offer=" + base64.urlsafe_b64encode(json.dumps(offer).encode()).decode().rstrip("=")
with tempfile.TemporaryDirectory(prefix="haven-nearby-smoke-") as directory:
    path = pathlib.Path(directory) / "synthetic-offer.txt"
    path.write_text(link)
    inspected = subprocess.run([binary, "inspect", "--offer-file", str(path)], capture_output=True, text=True, timeout=5, check=True)
    assert json.loads(inspected.stdout) == offer
    advertiser = subprocess.Popen([binary, "advertise", "--offer-file", str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        browser = subprocess.run([binary, "browse", "--seconds", "10"], capture_output=True, text=True, timeout=15)
        assert browser.returncode == 0, browser.stderr
        offers = [json.loads(line) for line in browser.stdout.splitlines() if line.strip()]
        assert offer in offers, "Synthetic offer was not discovered; check local-network permission / Bonjour."
        assert advertiser.poll() is None, "Advertiser stopped before expiry."
        # Let the actual advertiser expire, then a fresh process must not discover it.
        advertiser.communicate(timeout=30)
        assert advertiser.returncode == 0
        later = subprocess.run([binary, "browse", "--seconds", "2"], capture_output=True, text=True, timeout=6, check=True)
        assert offer["offerID"] not in later.stdout, "Expired offer remains visible."
        print(json.dumps({"test": "network-two-process-discovery", "discovered": True,
                          "expiryRejected": True, "identityAuthorityTested": False}))
    finally:
        if advertiser.poll() is None:
            advertiser.terminate()
            advertiser.communicate(timeout=5)
