#!/usr/bin/env python3
"""Audit Localization/en.lproj/Localizable.strings against the sources.

Two directions get checked, because the table drifts both ways:

* **dead keys** — table entries no source references any more. A feature that goes
  away leaves its strings behind, and a stale table makes it look like those surfaces
  still exist. Reported as a failure: `exit 1`.
* **untranslated literals** (informational) — English literals in the sources with no
  table entry. Harmless today (the table is English, so the key *is* the display text),
  but it is the list a real translation pass has to cover.

Keys whose text contains Swift source (`\(expr)`) are inert rather than dead: SwiftUI
derives the lookup key of an interpolated literal from the interpolation *types*
(`"%lld rpm"`), never from the source text, so such an entry is never consulted. They
are reported separately.

Usage:
    tools/strings-audit/audit.py            # gate: fails on dead keys
    tools/strings-audit/audit.py --quiet    # only the verdict lines
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TABLE = os.path.join(ROOT, "Localization", "en.lproj", "Localizable.strings")
SKIP_DIRS = {".build", ".git", ".pi", ".pi-glla", ".zvec-grep", "dist", "node_modules"}
KEY_LINE = re.compile(r'^\s*"(.+)"\s*=\s*".*";\s*$')
# Literals that become LocalizedStringKey / NSLocalizedString lookups at runtime.
CALL_SITE = re.compile(
    r'(?:Text|Button|Toggle|Label|Picker|Menu|L10n\.text|L10n\.format|\.help|\.navigationTitle|'
    r'SetupCard|settingsRow)\s*\(\s*"((?:[^"\\]|\\.)*)"')

quiet = "--quiet" in sys.argv

sources = {}
for root, dirs, files in os.walk(ROOT):
    dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
    for name in files:
        if name.endswith(".swift"):
            path = os.path.join(root, name)
            sources[path] = open(path, encoding="utf-8").read()


def strip_comments(src):
    """Remove `//`, `///` and `/* */` comments, leaving string literals intact.

    A key is "referenced" when the *code* names it. Prose that merely quotes the
    phrase — a comment explaining why a row was deleted, for instance — is not a
    lookup site, and a substring test over the raw source would accept it, so a
    dead key can hide behind a comment about its own removal. Swift nests block
    comments, so the depth is tracked; `"//"` inside a string must not be treated
    as a comment, so quote state is tracked too.
    """
    out = []
    i, n = 0, len(src)
    in_str = False
    while i < n:
        c = src[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:      # escape: take the next char verbatim
                out.append(src[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            depth, i = 1, i + 2
            while i < n and depth:
                if src[i] == "/" and i + 1 < n and src[i + 1] == "*":
                    depth, i = depth + 1, i + 2
                elif src[i] == "*" and i + 1 < n and src[i + 1] == "/":
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


# The substring test runs over code only; comments are stripped first.
code = "\n".join(strip_comments(s) for s in sources.values())

rows = []
with open(TABLE, encoding="utf-8") as handle:
    for lineno, line in enumerate(handle, 1):
        match = KEY_LINE.match(line.rstrip("\n"))
        if match:
            rows.append((lineno, match.group(1)))

# The table escapes inner quotes; Swift source keeps them bare inside an interpolation.
unescaped = lambda key: key.replace('\\"', '"')

# Every literal the sources actually look up, for the missing-literal list below.
# Note this regex is deliberately narrower than the dead-key test: it finds SwiftUI
# literals that have *no* table entry yet, which is a different question.
lookup_sites = {m.group(1) for src in sources.values() for m in CALL_SITE.finditer(src)}

dead, inert, alive = [], [], []
for lineno, key in rows:
    text = unescaped(key)
    if "\\(" in text:
        inert.append((lineno, text))
    elif text in code:
        alive.append(text)
    else:
        dead.append((lineno, text))

# Literals in code with no table entry (informational, deduped).
referenced = set(alive)
missing = sorted({m.group(1) for src in sources.values() for m in CALL_SITE.finditer(src)
                  # Interpolated literals key by specifier, and an empty literal (a blank
                  # TextField prompt) is not a string to translate.
                  if m.group(1) and "\\(" not in m.group(1) and unescaped(m.group(1)) not in referenced})

if not quiet:
    print(f"table: {TABLE[len(ROOT) + 1:]}  ({len(rows)} keys, {len(alive)} referenced)")
    for lineno, key in dead:
        print(f"  DEAD line {lineno}: {key[:100]}")
    for lineno, key in inert:
        print(f"  INERT line {lineno} (interpolated literal, never looked up): {key[:80]}")
    if missing:
        print(f"  {len(missing)} literal(s) in sources with no table entry "
              f"(fine while the table is English; the work list for a translation pass):")
        for key in missing[:15]:
            print(f"    - {key[:100]}")
        if len(missing) > 15:
            print(f"    … {len(missing) - 15} more")

if dead:
    print(f"STRINGS AUDIT FAIL: {len(dead)} dead key(s) — delete them or restore the code that uses them")
    sys.exit(1)
print(f"STRINGS AUDIT OK: {len(alive)} keys, all referenced"
      + (f"; {len(inert)} inert entry(ies) could be deleted" if inert else ""))
