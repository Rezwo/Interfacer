"""Reject the abbreviated bindings and compact return blocks corrected in this pass."""
from pathlib import Path
import re
import sys
Root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "src"
Abbreviations = re.compile(r"\b(?:Len|OldLen|NewLen|ArrayLen|OldElems|NewVal|ValidatePos|PosOrValue|ResyncIndices|CacheN|LiveN|RowA|RowB|CurrentId|NextId)\b")
CompactReturn = re.compile(r"\b(?:then|function\b[^\n]*)[^\n]*\breturn\b[^\n]*\bend\b")
Failures = []
for Source in sorted(Root.rglob("*.luau")):
    for Number, Line in enumerate(Source.read_text(encoding="utf-8").splitlines(), 1):
        if Abbreviations.search(Line) or CompactReturn.search(Line):
            Failures.append(f"{Source.name}:{Number}: {Line.strip()}")
if Failures:
    print("\n".join(Failures))
    raise SystemExit(1)
print("STYLE PASS: verbose bindings and multiline return blocks")
