#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: write-runtime-checksums.py <target-dir>", file=sys.stderr)
        return 1

    target_dir = Path(sys.argv[1]).resolve()
    if not target_dir.is_dir():
        print(f"target directory not found: {target_dir}", file=sys.stderr)
        return 1

    lines: list[str] = []
    for path in sorted(path for path in target_dir.rglob("*") if path.is_file()):
        relative_path = path.relative_to(target_dir)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines.append(f"{digest}  {relative_path.as_posix()}")

    (target_dir / "checksums.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
