#!/usr/bin/env python3
"""Offline simulation of NewDevice AMG Venmo import (no device / SecItem)."""
from __future__ import annotations

import argparse
import base64
import json
import plistlib
import re
import shutil
import tarfile
import tempfile
from pathlib import Path


def looks_cipher(s: object) -> bool:
    if not isinstance(s, str) or len(s) < 16:
        return False
    if not re.fullmatch(r"[A-Za-z0-9+/= \n]+", s):
        return False
    return ("+" in s) or ("/" in s)


def redact(obj):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            ks = str(k).lower()
            if any(x in ks for x in ("token", "secret", "password", "refresh", "access")):
                if isinstance(v, str):
                    out[k] = f"<redacted len={len(v)}>"
                else:
                    out[k] = f"<redacted {type(v).__name__}>"
            else:
                out[k] = redact(v)
        return out
    if isinstance(obj, list):
        return [redact(x) for x in obj[:6]]
    return obj


def find_record_root(extracted: Path) -> Path:
    for p in extracted.rglob("net.kortina.labs.Venmo"):
        if p.is_dir():
            return p.parent
    raise SystemExit("Venmo folder not found in archive")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("archive", type=Path)
    args = ap.parse_args()

    tmp = Path(tempfile.mkdtemp(prefix="nd-sim-"))
    try:
        with tarfile.open(args.archive, "r:*") as tf:
            tf.extractall(tmp)
        root = find_record_root(tmp)
        venmo_src = root / "net.kortina.labs.Venmo"
        stage = tmp / "Records" / "sim"
        dst = stage / "apps" / "net.kortina.labs.Venmo"
        dst.mkdir(parents=True)
        for sub in ("Documents", "Library"):
            if (venmo_src / sub).exists():
                shutil.copytree(venmo_src / sub, dst / sub)
        akc_path = dst / "Documents" / "akc.plist"
        faker = plistlib.loads((root / "faker.plist").read_bytes())
        akc = plistlib.loads(akc_path.read_bytes())

        items = []
        for k, v in akc.items():
            if not isinstance(v, dict):
                continue
            vd = v.get("v_Data")
            if not isinstance(vd, (bytes, bytearray)) or not vd:
                continue
            items.append(
                {
                    "label": k,
                    "account": v.get("acct"),
                    "service": v.get("svce"),
                    "accessGroup": v.get("agrp"),
                    "pdmn": v.get("pdmn"),
                    "data": base64.b64encode(vd).decode(),
                }
            )
        plistlib.dump(items, (dst / "keychain-full.plist").open("wb"), fmt=plistlib.FMT_XML)

        cipher_hits = sum(1 for v in faker.values() if looks_cipher(v))
        token_key = next((k for k in akc if "identity.token" in k), None)
        fp = akc.get("VenmoKit_com.venmo.VenmoKit.DeviceFingerprint", {}).get("v_Data")
        enc = akc.get("Encryption_symmetricKey", {}).get("v_Data")
        remembered = venmo_src / "Library/Preferences/RememberedStateStorage.plist"
        account_profile_encrypted = False
        if remembered.exists():
            rp = plistlib.loads(remembered.read_bytes())
            ap = rp.get("accountProfile")
            account_profile_encrypted = isinstance(ap, (bytes, bytearray)) and len(ap) > 16

        print("=== NewDevice AMG Venmo import simulation ===")
        print(f"record_root: {root.name}")
        print(f"staged Documents KB: {sum(p.stat().st_size for p in (dst/'Documents').rglob('*') if p.is_file())//1024}")
        print(f"staged Library KB: {sum(p.stat().st_size for p in (dst/'Library').rglob('*') if p.is_file())//1024}")
        print(f"akc entries: {len(akc)} convertible: {len(items)}")
        print(f"has AuthenticatedAccount: {'VenmoKit_AuthenticatedAccount' in akc}")
        print(f"has identity.token: {bool(token_key)}")
        print(f"has Encryption_symmetricKey: {isinstance(enc, (bytes, bytearray)) and len(enc)==32}")
        print(f"DeviceFingerprint: {fp.decode() if isinstance(fp,(bytes,bytearray)) else None}")
        print(f"faker ciphertext-like values: {cipher_hits}/{len(faker)}")
        print(f"RememberedStateStorage.accountProfile encrypted blob: {account_profile_encrypted}")
        print()
        print("FAILURE MODES THIS PACK HITS ON NEWDEVICE:")
        print("1) faker.plist is AMG at-rest ciphertext → identity randomized unless seeded")
        print("2) accountProfile blob needs Encryption_symmetricKey in Venmo keychain BEFORE first UI read")
        print("3) Keychain must be written in-process (access group 6DEPQ9SPDK.net.kortina.labs.Venmo)")
        if token_key:
            tok = json.loads(akc[token_key]["v_Data"].decode())
            print("token fields:", sorted(redact(tok).keys()))
        auth = json.loads(akc["VenmoKit_AuthenticatedAccount"]["v_Data"].decode())
        user = auth.get("user") or {}
        print(f"cached user: id={user.get('id')} phone={user.get('phone')} status={auth.get('status')}")
        print()
        print("EXPECTED DEVICE CHECKS AFTER IMPORT:")
        print("- Documents/akc.plist present in live Venmo container")
        print("- Documents/nd-akc-ok.txt with ok>0 (written by tweak at launch)")
        print("- Documents/nd-restore-ok.txt marker from restoreHolo")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
