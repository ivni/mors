#!/usr/bin/env python3
"""Fetch missing upstream notices by exact revision and decoded SHA-256."""

import argparse
import base64
from importlib import import_module
import json
from pathlib import Path
import urllib.request

inputs = import_module("naiveproxy-inputs")
LOCK = inputs.ROOT / "builder/entware/naiveproxy-notices.json"


def download(cache):
    lock = json.loads(LOCK.read_text())
    cache.mkdir(parents=True, exist_ok=True)
    if cache.is_symlink():
        raise ValueError("Unsafe notices cache")
    for name, item in lock["downloads"].items():
        if Path(name).name != name or not item["url"].startswith("https://"):
            raise ValueError("Invalid notices lock")
        dest = cache / name
        if dest.exists() or dest.is_symlink():
            inputs.checked_file(dest, item["sha256"])
            continue
        with urllib.request.urlopen(item["url"], timeout=60) as response:
            data = response.read()
        if item.get("encoding") == "base64":
            data = base64.b64decode(b"".join(data.split()), validate=True)
        elif item.get("encoding") is not None:
            raise ValueError("Unknown notice encoding")
        if inputs.sha256(data) != item["sha256"]:
            raise ValueError(f"Notice digest mismatch: {name}")
        with dest.open("xb") as stream:
            stream.write(data)
        print(f"Verified upstream notice: {name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cache", type=Path)
    download(parser.parse_args().cache)
