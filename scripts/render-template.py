#!/usr/bin/env python3
"""
slm-forge/scripts/render-template.py — simple {{var}} template renderer.

Usage:
  render-template.py <template-path> <json-vars> > <output>

Behavior:
  - Reads the template file.
  - Parses JSON vars from argv[2] or stdin if argv[2] == '-'.
  - Substitutes {{var}} with str(value) for every key in vars.
  - Left-alone any {{unknown}} (helps debugging template bugs).
  - No conditionals, no loops, no escapes. Keep it stupid.
"""
import json
import re
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: render-template.py <template> <json|->", file=sys.stderr)
        return 64
    tmpl_path = sys.argv[1]
    json_arg = sys.argv[2]

    with open(tmpl_path) as f:
        tmpl = f.read()

    if json_arg == "-":
        vars_ = json.loads(sys.stdin.read())
    else:
        vars_ = json.loads(json_arg)

    def replace(match: re.Match) -> str:
        key = match.group(1).strip()
        if key in vars_:
            return str(vars_[key])
        return match.group(0)  # leave unknown placeholders as-is

    out = re.sub(r"\{\{([^{}]+)\}\}", replace, tmpl)
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
