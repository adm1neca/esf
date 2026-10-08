#!/usr/bin/env python3
"""Report upstream agent releases needing compatibility review as warnings."""

import json
import os
from pathlib import Path
import sys
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]


def get_json(url):
    request = Request(url, headers={"Accept": "application/json", "User-Agent": "esf-agent-update-check"})
    with urlopen(request, timeout=20) as response:
        return json.load(response)


def main():
    inventory = json.loads((ROOT / "release/inventory.json").read_text())["dependencies"]
    actual = {
        "Unreal": get_json("https://api.github.com/repos/unreallabsai/unreal-agent/releases/latest")["tag_name"].lstrip("v"),
        "OpenCode V2": get_json("https://registry.npmjs.org/%40opencode%2Fcli")["dist-tags"]["latest"],
    }
    pinned = {"Unreal": inventory["unreal"]["release"], "OpenCode V2": inventory["opencode"]["version"]}
    changed = False
    for agent, version in actual.items():
        print(f"{agent}: pinned {pinned[agent]}, upstream {version}")
        if version != pinned[agent]:
            changed = True
    if changed:
        message = (
            "An upstream agent release needs compatibility review and new hashes; "
            "qualified pins were left unchanged. See the step log for version details."
        )
        print(f"::warning title=Agent update needs qualification::{message}")
        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_path:
            with open(summary_path, "a", encoding="utf-8") as summary:
                summary.write(
                    "### Agent update needs qualification\n\n"
                    f"{message}\n"
                )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
