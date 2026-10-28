#!/usr/bin/env python3
"""render.py <template> <mroom.toml> [name=value ...] - a CI template with its placeholders filled.

The tests' stand-in for what `mroom init` will do, following the README's "CI templates" rules: each
<<key>> from `mroom config get` (through bin/mroom, so the real reader and its checks run), the derived
ones (<<tests.database>>, <<pm.*>>, <<default_branch>>), and each <<fill:name>> from a name=value
argument. A folder of "." followed by "/" renders as nothing, so <<app.backend_dir>>/vendor is vendor.
Exits 1 naming any placeholder left unfilled.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

PM = {
    "npm": {"pm.lockfile": "package-lock.json", "pm.install": "npm ci", "pm.exec": "npx",
            "pm.store_path": "npm config get cache"},
    "pnpm": {"pm.lockfile": "pnpm-lock.yaml", "pm.install": "pnpm install --frozen-lockfile",
             "pm.exec": "pnpm exec", "pm.store_path": "pnpm store path --silent"},
}


def get(config, key, default=None):
    command = [os.path.join(ROOT, "bin", "mroom"), "config", "get", key]
    if default is not None:
        command += ["--default", default]
    env = dict(os.environ, MROOM_CONFIG=config)
    return subprocess.run(command, env=env, check=True, capture_output=True, text=True).stdout.rstrip("\n")


def values(config, fills):
    out = {key: get(config, key) for key in
           ("app.name", "app.backend_dir", "app.frontend_dir", "app.package_manager", "app.php", "tests.command")}
    frontend = out["app.frontend_dir"]
    if frontend == "":
        # The templates need a Node folder; with no frontend they would build paths from the root.
        raise SystemExit('app.frontend_dir = "": the CI templates do not support an app with no frontend yet')
    out["app.build.frontend_dist"] = get(config, "app.build.frontend_dist",
                                         "public/build" if frontend == "." else "dist")
    pattern = get(config, "tests.database_pattern")
    out["tests.database"] = pattern.replace("{app}", out["app.name"]).replace("{slug}", "ci")
    out.update(PM[out["app.package_manager"]])
    out["default_branch"] = fills.pop("default_branch", "main")
    out.update({f"fill:{name}": value for name, value in fills.items()})
    return out


def render(text, table):
    def one(match):
        name, slash = match.group(1), match.group(2)
        if name not in table:
            return match.group(0)
        value = table[name]
        if slash and name in ("app.backend_dir", "app.frontend_dir") and value == ".":
            return ""
        return value + slash

    return re.sub(r"<<([a-z0-9_.:]+)>>(/?)", one, text)


def main():
    template, config, *pairs = sys.argv[1:]
    fills = dict(pair.split("=", 1) for pair in pairs)
    with open(template, encoding="utf-8") as fh:
        text = render(fh.read(), values(config, fills))
    left = sorted(set(re.findall(r"<<[^<>\s]*>>", text)))
    if left:
        print(f"{template}: unfilled: {' '.join(left)}", file=sys.stderr)
        sys.exit(1)
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
