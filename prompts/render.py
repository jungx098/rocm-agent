#!/usr/bin/env python3
"""Replace {{KEY}} placeholders in a UTF-8 template using _PROMPT_<KEY> environment variables."""
from __future__ import annotations

import os
import sys


def main() -> None:
    if len(sys.argv) < 3:
        print("Usage: render.py TEMPLATE_PATH KEY [KEY ...]", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]
    keys = sys.argv[2:]
    with open(path, encoding="utf-8") as f:
        text = f.read()
    for k in keys:
        val = os.environ.get("_PROMPT_" + k, "")
        text = text.replace("{{" + k + "}}", val)
    # Env values from bash may contain surrogate code points (POSIX
    # surrogateescape for non-UTF-8 bytes). Those are not valid UTF-8.
    sys.stdout.buffer.write(text.encode("utf-8", errors="replace"))


if __name__ == "__main__":
    main()
