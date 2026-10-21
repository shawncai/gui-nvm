#!/usr/bin/env python3
"""Verify the checked-in semver inventory offline, without package managers."""

import hashlib
import json
import pathlib
import sys


def main():
    vendor = pathlib.Path(__file__).resolve().parent / "vendor"
    record = json.loads((vendor / "semver-7.7.3.provenance.json").read_text())
    package = vendor / "node-semver"
    expected = record["filesSha256"]
    actual = {}
    for candidate in package.rglob("*"):
        if candidate.is_symlink():
            raise ValueError("Unexpected symlink: " + str(candidate.relative_to(package)))
        if candidate.is_file():
            relative = str(candidate.relative_to(package))
            actual[relative] = hashlib.sha256(candidate.read_bytes()).hexdigest()
    if actual != expected:
        for name in sorted(set(actual) | set(expected)):
            if actual.get(name) != expected.get(name):
                print("MISMATCH: " + name, file=sys.stderr)
        return 1
    metadata = json.loads((package / "package.json").read_text())
    assert metadata["name"] == "semver" and metadata["version"] == "7.7.3"
    assert metadata["license"] == "ISC" and not metadata.get("dependencies")
    print("PASS: semver@7.7.3, ISC, no runtime dependencies, %d file hashes" % len(actual))
    return 0


if __name__ == "__main__":
    sys.exit(main())
