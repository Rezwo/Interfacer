"""Verify the compact Git distribution without historical local checkpoints."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--luau", default=os.environ.get("LUAU_CLI") or shutil.which("luau"))
    parser.add_argument("--hashes-only", action="store_true")
    args = parser.parse_args()
    package = Path(__file__).resolve().parent
    manifest = json.loads((package / "verification/DISTRIBUTION.json").read_text())
    for relative, expected in manifest["sha256"].items():
        target = (package / relative).resolve()
        if not target.is_relative_to(package):
            raise SystemExit("Invalid manifest path: " + relative)
        actual = hashlib.sha256(target.read_bytes()).hexdigest()
        if actual != expected:
            raise SystemExit("Hash mismatch: " + relative)
    print("HASHES PASS:", len(manifest["sha256"]), "distribution files", flush=True)
    if args.hashes_only:
        print("Runtime tests NOT RUN (--hashes-only)")
        return
    if not args.luau:
        parser.error("provide --luau or LUAU_CLI; hashes alone do not pass runtime gates")
    cli = str(Path(args.luau).resolve())
    print("CLI SHA256:", hashlib.sha256(Path(cli).read_bytes()).hexdigest(), flush=True)
    for script, required in [
        ("test/spec.client.luau", ["253 passed", "0 failed", "78 skipped"]),
        ("verification/CoreCounts.luau", ["COUNTS PASS: 9"]),
    ]:
        command = [cli, "-O2", script]
        result = subprocess.run(command, cwd=package, capture_output=True, text=True,
                                encoding="utf-8", errors="replace")
        print(json.dumps({"command": command, "cwd": str(package),
                          "stdout": result.stdout, "stderr": result.stderr,
                          "exit_status": result.returncode}, indent=2), flush=True)
        if result.returncode or not all(text in result.stdout for text in required):
            raise SystemExit("Verification failed: " + script)
    print("DISTRIBUTION PASS: hashes, headless behavior and exact counts; no timing/native run")


if __name__ == "__main__":
    main()
