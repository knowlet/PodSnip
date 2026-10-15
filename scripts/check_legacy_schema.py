#!/usr/bin/env python3
"""Static fixture-provenance guard. This is NOT a SwiftData migration test."""
from __future__ import annotations

import hashlib
import sys
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE_COMMIT = "8d72603772330660f12638c75691656e597a5fc2"
LEGACY_BLOB = "5bac94f227dfeddbcd40831335c1312ffb6c5284"
START = "// BEGIN FROZEN LEGACY MODELS\n"
END = "// END FROZEN LEGACY MODELS\n"


def check() -> None:
    tests = (ROOT / "Tests/RegressionTests.swift").read_text(encoding="utf-8")
    if tests.count(START) != 1 or tests.count(END) != 1:
        raise ValueError("Expected exactly one frozen legacy model block")
    frozen = textwrap.dedent(tests.split(START, 1)[1].split(END, 1)[0])
    original = ("import Foundation\nimport SwiftData\n\n" + frozen).encode("utf-8")
    header = f"blob {len(original)}\0".encode("ascii")
    actual = hashlib.sha1(header + original).hexdigest()
    if actual != LEGACY_BLOB:
        raise ValueError(f"Legacy model drift: expected {LEGACY_BLOB}, got {actual}")

    # Intentionally constrain this regression to the reviewed aiError change.
    # Future schema changes must add their own migration coverage, not silently
    # edit the old model until a test stops exercising a real upgrade.
    current = (ROOT / "PodSnip/Models.swift").read_bytes()
    property_line = b"    var aiError: String?\n"
    initializer_line = b"        self.aiError = nil\n"
    if current.count(property_line) != 1 or current.count(initializer_line) != 1:
        raise ValueError("Expected one optional aiError property and nil initializer")
    previous_shape = current.replace(property_line, b"").replace(initializer_line, b"")
    if previous_shape != original:
        raise ValueError("Current model changes exceed the reviewed optional aiError addition")

    # Verify the known app-startup path invokes the same factory as the tests.
    app = (ROOT / "PodSnip/PodSnipApp.swift").read_text(encoding="utf-8")
    if "return try PodSnipPersistence.makeContainer()" not in app:
        raise ValueError("App startup no longer uses the migration-tested factory")
    if app.count("return try ModelContainer(for: schema, configurations: [config])") != 1:
        raise ValueError("Review persistent-container initialization paths")
    print(f"PASS: frozen legacy source matches {BASE_COMMIT} (blob {LEGACY_BLOB})")
    print("PASS: production model delta is only optional Snip.aiError and its nil initializer")
    print("PASS: app startup uses the shared throwing persistent-container factory")
    print("STATIC CHECK ONLY: no SwiftData macro expansion, type-check, SQLite fixture, or migration executed")


if __name__ == "__main__":
    try:
        check()
    except (OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
