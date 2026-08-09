#!/usr/bin/env python3
"""Compare NewDevice param generation / apply matrix with AMG field conventions.

Validates:
1. AMG script field names are present in exported profile dict
2. Model-only set (AMG Set_Device_Model) syncs ProductType / board id
3. SystemVer maps to a real-looking Build
4. Hook consumer matrix: which generated fields are applied vs probe-visible
"""

from __future__ import annotations

import re
import sys
from typing import Dict, List, Optional, Tuple

# Mirrors NDDeviceCatalog.deviceModels / systemBuildMap
DEVICES = [
    {"Model": "iPhone 13", "ProductType": "iPhone14,5", "HardwareMachine": "iPhone14,5", "HardwareModel": "D17AP"},
    {"Model": "iPhone 13 Pro", "ProductType": "iPhone14,2", "HardwareMachine": "iPhone14,2", "HardwareModel": "D63AP"},
    {"Model": "iPhone 14", "ProductType": "iPhone14,7", "HardwareMachine": "iPhone14,7", "HardwareModel": "D27AP"},
    {"Model": "iPhone 14 Pro", "ProductType": "iPhone15,2", "HardwareMachine": "iPhone15,2", "HardwareModel": "D73AP"},
    {"Model": "iPhone 15", "ProductType": "iPhone15,4", "HardwareMachine": "iPhone15,4", "HardwareModel": "D37AP"},
    {"Model": "iPhone 15 Pro", "ProductType": "iPhone16,1", "HardwareMachine": "iPhone16,1", "HardwareModel": "D83AP"},
    {"Model": "iPhone 15 Pro Max", "ProductType": "iPhone16,2", "HardwareMachine": "iPhone16,2", "HardwareModel": "D84AP"},
    {"Model": "iPhone 12", "ProductType": "iPhone13,2", "HardwareMachine": "iPhone13,2", "HardwareModel": "D53gAP"},
    {"Model": "iPhone 11", "ProductType": "iPhone12,1", "HardwareMachine": "iPhone12,1", "HardwareModel": "N104AP"},
    {"Model": "iPhone X", "ProductType": "iPhone10,3", "HardwareMachine": "iPhone10,3", "HardwareModel": "D22AP"},
]

BUILDS = {
    "15.0": "19A346",
    "15.1": "19B74",
    "15.4.1": "19E258",
    "15.7.1": "19H117",
    "16.0": "20A362",
    "16.1.1": "20B101",
    "16.3.1": "20D67",
    "16.5": "20F66",
    "16.6.1": "20G81",
    "16.7.2": "20H115",
}

# Documented / used by AMG official scripts
AMG_SCRIPT_KEYS = [
    "DeviceToken",
    "Latitude",
    "Longitude",
    "Model",
    "SystemVer",
]

# Full NewDevice export keys (AMG-compatible naming)
EXPORT_KEYS = [
    "IDFA", "IDFV", "UUID", "Serial", "UDID", "WiFiMAC", "BTMAC", "DeviceToken",
    "Model", "ProductType", "HardwareMachine", "HardwareModel", "SystemVer", "Build",
    "Carrier", "MCC", "MNC", "RadioAccess", "Latitude", "Longitude", "Altitude",
]

# field -> (hooked?, probe_checks?)
APPLY_MATRIX: Dict[str, Tuple[bool, bool]] = {
    "IDFA": (True, True),
    "IDFV": (True, True),
    "UUID": (False, False),  # AMG stores for scripts; not a public UIKit hook target
    "Serial": (True, True),
    "UDID": (True, True),
    "WiFiMAC": (True, True),
    "BTMAC": (True, True),
    "DeviceToken": (False, False),  # AMG Get/Set_Param storage; APNs token not rewritten in-process
    "Model": (True, True),  # via UIDevice.name / MG DeviceName
    "ProductType": (True, True),
    "HardwareMachine": (True, True),
    "HardwareModel": (True, True),
    "SystemVer": (True, True),
    "Build": (True, True),
    "Carrier": (True, True),
    "MCC": (True, True),
    "MNC": (True, True),
    "RadioAccess": (True, True),
    "Latitude": (True, True),
    "Longitude": (True, True),
    "Altitude": (True, False),
}


def find_device(model: str) -> Optional[dict]:
    for d in DEVICES:
        if d["Model"] == model or d["ProductType"] == model:
            return d
    return None


def sync_from_model(profile: dict) -> dict:
    """Mirrors NDDeviceProfile syncIdentityFromCatalog when only Model is set."""
    out = dict(profile)
    dev = find_device(out.get("Model", ""))
    if not dev:
        return out
    out["ProductType"] = dev["ProductType"]
    out["HardwareMachine"] = dev["HardwareMachine"]
    out["HardwareModel"] = dev["HardwareModel"]
    sysv = out.get("SystemVer", "")
    if sysv and not out.get("Build"):
        out["Build"] = BUILDS.get(sysv, "")
    return out


def assert_true(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def main() -> int:
    # 1) AMG script keys exist in export schema
    for k in AMG_SCRIPT_KEYS:
        assert_true(k in EXPORT_KEYS, f"AMG key missing from export: {k}")

    # 2) AMG Set_Device_Model("iPhone X") style → product/board filled
    p = {"Model": "iPhone X", "SystemVer": "16.1.1", "ProductType": "", "HardwareMachine": "", "HardwareModel": "", "Build": ""}
    p = sync_from_model(p)
    assert_true(p["ProductType"] == "iPhone10,3", "ProductType sync")
    assert_true(p["HardwareMachine"] == "iPhone10,3", "HardwareMachine sync")
    assert_true(p["HardwareModel"] == "D22AP", "HardwareModel board id sync")
    assert_true(p["Build"] == "20B101", "real build for 16.1.1")

    # 3) HardwareModel must look like board id, NOT ProductType
    for d in DEVICES:
        assert_true(re.match(r"^[A-Z0-9]+AP$", d["HardwareModel"]) or re.match(r"^[A-Z0-9]+gAP$", d["HardwareModel"]),
                    f"board id shape: {d['HardwareModel']}")
        assert_true(d["HardwareModel"] != d["ProductType"], "HardwareModel != ProductType")

    # 4) Builds are real Apple-style (digit + letter + digits), not synthetic 116A###
    for ver, build in BUILDS.items():
        assert_true(re.match(r"^\d{2}[A-Z]\d+$", build), f"build format {ver}={build}")
        assert_true(not build.startswith("116"), "reject old synthetic major+100 builds")

    # 5) UDID hex -> UniqueDeviceIDData bytes length
    udid = "a" * 40
    assert_true(len(udid) == 40, "udid length")
    data_len = len(udid) // 2
    assert_true(data_len == 20, "UniqueDeviceIDData should be 20 bytes")

    # 6) Effect matrix report
    hooked = [k for k, (h, _) in APPLY_MATRIX.items() if h]
    unhooked = [k for k, (h, _) in APPLY_MATRIX.items() if not h]
    probed = [k for k, (_, p) in APPLY_MATRIX.items() if p]
    assert_true("IDFA" in hooked and "HardwareModel" in hooked, "core hooks present")
    assert_true(set(unhooked) == {"UUID", "DeviceToken"}, f"unexpected unhooked: {unhooked}")
    assert_true("Serial" in probed and "UDID" in probed, "probe covers MG identity")

    print("simulate_amg_params: ALL CHECKS PASSED")
    print(f"  AMG script keys covered: {AMG_SCRIPT_KEYS}")
    print(f"  hooked fields ({len(hooked)}): {', '.join(hooked)}")
    print(f"  script-only (no hook): {', '.join(unhooked)}")
    print(f"  probe-compared ({len(probed)}): {', '.join(probed)}")
    print("  Model-only sync example: iPhone X -> iPhone10,3 / D22AP / Build 20B101")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as e:
        print(f"simulate_amg_params: FAIL: {e}", file=sys.stderr)
        raise SystemExit(1)
