#!/usr/bin/env python3
"""Host-side simulation of the NewDevice one-click chain state machine.

Mirrors the fixed semantics in NDRecordStore / NDOperationService without needing
an iOS device or Theos toolchain. Exit 0 on pass.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set


ORIGINAL = "原始机器"


@dataclass
class Profile:
    name: str
    enabled: bool = True
    latitude: float = 0.0
    longitude: float = 0.0
    idfa: str = ""


@dataclass
class Sandbox:
    data: Dict[str, str] = field(default_factory=dict)


@dataclass
class Store:
    profiles: Dict[str, Profile] = field(default_factory=dict)
    current: str = ORIGINAL
    backups: Dict[str, Dict[str, Sandbox]] = field(default_factory=dict)  # record -> bid -> sandbox
    sandboxes: Dict[str, Sandbox] = field(default_factory=dict)
    result: int = 0
    holographic: bool = True
    random_location: bool = True
    clears: List[str] = field(default_factory=list)
    terminated: List[str] = field(default_factory=list)
    notify_count: int = 0
    target_apps: List[str] = field(default_factory=lambda: ["com.example.app"])

    def ensure_original(self) -> None:
        if ORIGINAL not in self.profiles:
            self.profiles[ORIGINAL] = Profile(name=ORIGINAL, idfa="REAL-IDFA")
        if not self.current:
            self.current = ORIGINAL

    def all_names(self) -> List[str]:
        names = sorted(self.profiles.keys())
        if ORIGINAL in names:
            names.remove(ORIGINAL)
            names.insert(0, ORIGINAL)
        return names

    def notify(self) -> None:
        self.notify_count += 1

    def terminate_targets(self) -> None:
        for bid in self.target_apps:
            self.terminated.append(bid)

    def after_switch(self, previous: str, current: str) -> None:
        # Same-record must be a no-op (P0 fix).
        if previous == current:
            return
        if not self.target_apps:
            return
        if self.holographic:
            if previous and previous != ORIGINAL:
                self.backups.setdefault(previous, {})
                for bid in self.target_apps:
                    self.backups[previous][bid] = Sandbox(data=dict(self.sandboxes.get(bid, Sandbox()).data))
            if current == ORIGINAL:
                for bid in self.target_apps:
                    self.sandboxes[bid] = Sandbox()
                    self.clears.append(f"{previous}->{current}:{bid}")
            else:
                for bid in self.target_apps:
                    backed = self.backups.get(current, {}).get(bid)
                    if backed is None:
                        self.sandboxes[bid] = Sandbox()
                        self.clears.append(f"miss-backup:{current}:{bid}")
                    else:
                        self.sandboxes[bid] = Sandbox(data=dict(backed.data))
        else:
            for bid in self.target_apps:
                self.sandboxes[bid] = Sandbox()
                self.clears.append(f"clear:{bid}")

    def new_record(self) -> str:
        self.result = 2
        self.terminate_targets()
        previous = self.current
        # timestamp-like unique name
        n = 1
        while True:
            name = f"2026-08-09-00-00-{n:02d}"
            if name not in self.profiles:
                break
            n += 1
        lat, lon = (31.2, 121.5) if self.random_location else (
            self.profiles[self.current].latitude,
            self.profiles[self.current].longitude,
        )
        p = Profile(name=name, latitude=lat, longitude=lon, idfa=f"IDFA-{name}")
        self.profiles[name] = p
        self.current = name
        self.notify()
        self.after_switch(previous, name)
        self.result = 1
        return name

    def switch_to(self, name: str) -> bool:
        if name not in self.profiles:
            self.result = 0
            return False
        previous = self.current
        self.current = name
        self.notify()
        self.after_switch(previous, name)
        self.result = 1
        return True

    def next_record(self) -> bool:
        self.result = 2
        self.terminate_targets()
        previous = self.current
        names = self.all_names()
        idx = names.index(previous) if previous in names else -1
        nxt = 0 if idx < 0 else (idx + 1) % len(names)
        for n in range(len(names)):
            i = (nxt + n) % len(names)
            cand = names[i]
            p = self.profiles[cand]
            if p.enabled or cand == ORIGINAL:
                if cand == previous:
                    # only one enabled — no-op success, no after_switch wipe
                    self.result = 1
                    return True
                self.current = cand
                self.notify()
                self.after_switch(previous, cand)
                self.result = 1
                return True
        return self.switch_to(ORIGINAL)

    def delete_record(self, name: str) -> bool:
        self.result = 2
        self.terminate_targets()
        previous = self.current
        if name == ORIGINAL:
            self.result = 0
            return False
        if name not in self.profiles:
            self.result = 0
            return False
        was_current = previous == name
        del self.profiles[name]
        self.backups.pop(name, None)
        if was_current:
            self.current = ORIGINAL
            self.notify()
            self.after_switch(previous, ORIGINAL)
        self.result = 1
        return True


def assert_true(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def main() -> int:
    s = Store()
    s.ensure_original()
    s.sandboxes["com.example.app"] = Sandbox(data={"token": "orig-session"})

    # 1) nextRecord with only 原始机器 must NOT wipe sandbox
    clears_before = len(s.clears)
    assert_true(s.next_record(), "next with only original should succeed")
    assert_true(s.current == ORIGINAL, "current stays original")
    assert_true(len(s.clears) == clears_before, "same-record next must not clear sandbox")
    assert_true(s.sandboxes["com.example.app"].data.get("token") == "orig-session", "sandbox preserved")

    # 2) newRecord creates identity + clears (no holographic backup for original)
    name_a = s.new_record()
    assert_true(name_a != ORIGINAL, "new record name")
    assert_true(s.result == 1, "result success")
    assert_true(s.sandboxes["com.example.app"].data == {}, "new machine clears app data")
    assert_true(s.notify_count >= 1, "tweak reload notified")

    # Write data under record A
    s.sandboxes["com.example.app"].data["token"] = "session-A"

    # 3) second newRecord backs up A and clears for B
    name_b = s.new_record()
    assert_true(name_b != name_a, "distinct records")
    assert_true("token" in s.backups[name_a]["com.example.app"].data, "A backed up")
    assert_true(s.sandboxes["com.example.app"].data == {}, "B starts clean")

    s.sandboxes["com.example.app"].data["token"] = "session-B"

    # 4) switch back to A restores holographic data
    assert_true(s.switch_to(name_a), "switch A")
    # after_switch backs up B first then restores A
    assert_true(s.sandboxes["com.example.app"].data.get("token") == "session-A", "restored A")

    # 5) setRecord to same name is no-op for sandbox
    token = dict(s.sandboxes["com.example.app"].data)
    prev_clears = len(s.clears)
    assert_true(s.switch_to(name_a), "set same")
    assert_true(s.sandboxes["com.example.app"].data == token, "same-record set keeps data")
    assert_true(len(s.clears) == prev_clears, "no extra clear")

    # 6) delete current restores pipeline toward original (clear)
    assert_true(s.delete_record(name_a), "delete current A")
    assert_true(s.current == ORIGINAL, "pointer to original")
    assert_true(s.sandboxes["com.example.app"].data == {}, "cleared after delete current")

    # 7) randomLocation off inherits coords (including 0,0)
    s2 = Store(random_location=False)
    s2.ensure_original()
    s2.profiles[ORIGINAL].latitude = 0.0
    s2.profiles[ORIGINAL].longitude = 0.0
    name = s2.new_record()
    assert_true(s2.profiles[name].latitude == 0.0, "inherit 0 lat")
    assert_true(s2.profiles[name].longitude == 0.0, "inherit 0 lon")

    # 8) terminate always called before switch
    assert_true(len(s.terminated) >= 3, "targets terminated along chain")

    print("simulate_chain: ALL CHECKS PASSED")
    print(f"  records exercised: {[ORIGINAL, name_a, name_b]}")
    print(f"  notifies: {s.notify_count}, clears: {len(s.clears)}, terminates: {len(s.terminated)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as e:
        print(f"simulate_chain: FAIL: {e}", file=sys.stderr)
        raise SystemExit(1)
