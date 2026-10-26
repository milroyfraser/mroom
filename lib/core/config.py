#!/usr/bin/env python3
"""mroom config: the one reader of an app's mroom.toml and a box's box.env.

    mroom config get <dotted.key> [--json] [--default <value>]
    mroom config validate
    mroom config path [--box]
    mroom config keys
    mroom config box [<KEY>]

mroom.toml is found from $MROOM_CONFIG, or by walking up from the working directory. It is read with
python's tomllib (3.11+) and checked against SCHEMA below: a missing required key or a wrong type
fails, an unknown key warns. box.env ($MROOM_BOX_ENV, default ~/.config/mroom/box.env) is parsed line
by line, never sourced: only BOX_KEYS are allowed and any other line is refused.

Standard library only. Exit 0 on success, 1 on a config error or an unset key, 2 on a usage error.
"""

from __future__ import annotations

import difflib
import json
import os
import re
import sys

PROG = "mroom config"
CONFIG_NAME = "mroom.toml"


class ConfigError(Exception):
    """A problem with the config itself (exit 1)."""


class UsageError(Exception):
    """A problem with how the command was called (exit 2)."""


# ---- mroom.toml schema --------------------------------------------------------------------------
#
# Each key: (type, required, example line, help). Types: "str", "int" (>= 1), "list" (of strings),
# "map" (string to string), or a tuple of allowed strings (an enum).
#
# Phase 0 requires only app.name. Later phases add requirements as their commands start reading
# keys (for example qa.zone and qa.db_read_allowlist once QA environments exist in phase 2); a key
# becomes required in the phase whose command cannot run without it.

APP_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,31}$")

SCHEMA = {
    "app.name": ("str", True, 'name = "shop"',
                 "used in database names, Redis prefixes and labels: [a-z][a-z0-9_]*, at most 32"),
    "app.backend_dir": ("str", False, 'backend_dir = "."', 'the Laravel app; "." for a single app'),
    "app.frontend_dir": ("str", False, 'frontend_dir = "."',
                         '"." for Vite inside the Laravel app; "" for no separate frontend site'),
    "app.package_manager": (("npm", "pnpm"), False, 'package_manager = "npm"', "npm | pnpm"),
    "app.php": ("str", False, 'php = "8.4"', "PHP version"),
    "app.version_path": ("str", False, 'version_path = "/version"',
                         "the path that reports the running release and commit"),
    "app.build.frontend": ("str", False, 'frontend = "npm run build"', "frontend build command"),
    "app.build.frontend_env": ("map", False, 'frontend_env = { VITE_APP_KEY = "env:APP_KEY" }',
                               "environment for the frontend build"),
    "app.build.after_deploy": ("list", False, 'after_deploy = ["config:clear"]',
                               "artisan commands after a deploy"),
    "app.build.daemons": ("list", False, 'daemons = ["horizon"]', "daemons restarted after a deploy"),
    "app.build.queues": ("list", False, 'queues = ["default"]', "queues the app uses"),
    "tests.command": ("str", False, 'command = "php artisan test --compact --parallel"',
                      "the test command"),
    "tests.database_pattern": ("str", False, 'database_pattern = "{app}_{slug}_testing"',
                               "test database name; must contain {slug}"),
    "tests.suites_glob": ("str", False, 'suites_glob = "app/*/Tests"',
                          "per-suite test folders for the path-aware pre-push; empty for none"),
    "issues.tracker": (("linear", "none"), False, 'tracker = "none"', "linear | none"),
    "issues.id_pattern": ("str", False, 'id_pattern = "SHOP-[0-9]+"', "issue ids, as a regular expression"),
    "issues.url": ("str", False, 'url = "https://tracker.example.dev/issue/{id}"',
                   "issue link; must contain {id}"),
    "pr.required_checks": ("list", False, 'required_checks = ["test"]', "check names the ruleset requires"),
    "qa.zone": ("str", False, 'zone = "qa.example.dev"', "QA hosts are api-<PR>.<zone>, go-<PR>.<zone>"),
    "qa.max_envs": ("int", False, "max_envs = 5", "QA environments at once"),
    "qa.ttl_days": ("int", False, "ttl_days = 5", "days before an idle QA environment is reaped"),
    "qa.template_database": ("str", False, 'template_database = "qa_template"', "QA template database"),
    "qa.persona_domain": ("str", False, 'persona_domain = ".test"',
                          "sign-in codes are only ever read for these addresses"),
    "qa.db_read_allowlist": ("list", False, 'db_read_allowlist = ["users.email"]',
                             "tables and columns browser QA may read; required once browser QA exists"),
    "qa.parity.database": (("seeded", "snapshot"), False, 'database = "seeded"',
                           "seeded (factories) | snapshot (opt-in masked copy)"),
    "qa.parity.mail": (("catcher", "log"), False, 'mail = "catcher"',
                       "catcher (SMTP to the box's catcher) | log"),
    "qa.parity.broadcast": (("same", "log"), False, 'broadcast = "same"',
                            "same (a Reverb app per environment) | log"),
    "qa.parity.files": (("same", "local"), False, 'files = "same"',
                        "same (a bucket per environment) | local"),
    "persona.name": ("str", False, 'name = "Agent"', "the bot persona's name"),
}

# Every table that may appear, including parents of tables.
SECTIONS = {key.rsplit(".", 1)[0] for key in SCHEMA}
SECTIONS |= {s.rsplit(".", 1)[0] for s in SECTIONS if "." in s}


def find_config() -> str:
    explicit = os.environ.get("MROOM_CONFIG")
    if explicit:
        if not os.path.isfile(explicit):
            raise ConfigError(f"MROOM_CONFIG={explicit}: no such file")
        return os.path.abspath(explicit)
    start = os.getcwd()
    here = start
    while True:
        candidate = os.path.join(here, CONFIG_NAME)
        if os.path.isfile(candidate):
            return candidate
        parent = os.path.dirname(here)
        if parent == here:
            raise ConfigError(f"no {CONFIG_NAME} in {start} or any folder above it (or set MROOM_CONFIG)")
        here = parent


def load_toml(path: str) -> dict:
    if sys.version_info < (3, 11):
        found = ".".join(str(v) for v in sys.version_info[:3])
        raise ConfigError(f"reading {CONFIG_NAME} needs python3 >= 3.11 (tomllib); this is {found}")
    import tomllib  # noqa: PLC0415 - only here, so box.env works on older pythons

    try:
        with open(path, "rb") as fh:
            return tomllib.load(fh)
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"{path}: not valid TOML: {exc}") from None
    except OSError as exc:
        raise ConfigError(f"{path}: {exc.strerror}") from None


def flatten(data: dict, prefix: str = "") -> dict:
    """Leaf keys (by schema) to values; tables that are not leaves are walked."""
    out = {}
    for name, value in data.items():
        key = f"{prefix}{name}"
        if key not in SCHEMA and isinstance(value, dict):
            out.update(flatten(value, key + "."))
        else:
            out[key] = value
    return out


def type_error(key: str, kind, value) -> str | None:
    if isinstance(kind, tuple):
        if not isinstance(value, str) or value not in kind:
            return f"{key} must be one of {', '.join(kind)} (got {json.dumps(value)})"
        return None
    if kind == "str":
        return None if isinstance(value, str) else f"{key} must be a string"
    if kind == "int":
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            return f"{key} must be a whole number of at least 1"
        return None
    if kind == "list":
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
            return f"{key} must be a list of strings"
        return None
    if kind == "map":
        if not isinstance(value, dict) or not all(isinstance(v, str) for v in value.values()):
            return f"{key} must be a table of strings"
        return None
    raise AssertionError(kind)


def rule_error(key: str, value) -> str | None:
    """Checks beyond the type, for keys that other names are built from."""
    if key == "app.name" and not APP_NAME_RE.match(value):
        return f"{key} must match [a-z][a-z0-9_]* and be at most 32 characters (got {json.dumps(value)})"
    if key == "tests.database_pattern" and "{slug}" not in value:
        return f"{key} must contain {{slug}}, so each worktree gets its own database"
    if key == "issues.url" and "{id}" not in value:
        return f"{key} must contain {{id}}"
    if key == "issues.id_pattern":
        try:
            re.compile(value)
        except re.error as exc:
            return f"{key} is not a valid regular expression: {exc}"
    return None


def example(key: str) -> str:
    section = key.rsplit(".", 1)[0]
    return f"  [{section}]\n  {SCHEMA[key][2]}"


def check(path: str, data: dict) -> tuple[list[tuple[str, str]], list[str]]:
    """(key, message) errors and unknown-key warnings for a parsed mroom.toml."""
    errors, warnings = [], []
    flat = flatten(data)
    for key, value in flat.items():
        if key not in SCHEMA:
            if key in SECTIONS:
                errors.append((key, f"{key} must be a table ([{key}])"))
                continue
            hint = difflib.get_close_matches(key, SCHEMA.keys(), n=1)
            tip = f"; did you mean {hint[0]}?" if hint else ""
            warnings.append(f"unknown key {key} (ignored){tip}")
            continue
        kind = SCHEMA[key][0]
        problem = type_error(key, kind, value) or (rule_error(key, value) if kind == "str" else None)
        if problem:
            errors.append((key, problem))
    for key, (_, required, _, _) in SCHEMA.items():
        if required and key not in flat:
            errors.append(("", f"{key} is required, for example:\n{example(key)}"))
    return errors, warnings


def related(error_key: str, key: str) -> bool:
    """An error about error_key matters when reading key: the same key, a key inside it, or its table."""
    return error_key in ("", key) or error_key.startswith(key + ".") or key.startswith(error_key + ".")


def load_checked(key: str | None = None) -> tuple[str, dict]:
    """The config, checked. With a key (get), only errors that concern it, and missing required keys,
    fail, and unknown keys stay quiet; without one (validate), every error fails and every warning prints."""
    path = find_config()
    data = load_toml(path)
    errors, warnings = check(path, data)
    if key is None:
        for w in warnings:
            print(f"{PROG}: warning: {path}: {w}", file=sys.stderr)
    else:
        errors = [e for e in errors if related(e[0], key)]
    if errors:
        raise ConfigError("\n".join(f"{path}: {message}" for _, message in errors))
    return path, data


def lookup(data: dict, key: str):
    node = data
    for part in key.split("."):
        if not isinstance(node, dict) or part not in node:
            raise KeyError(key)
        node = node[part]
    return node


def scalar(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def render(value) -> str:
    """Plain output: strings raw, lists one item per line, tables of strings as KEY=value lines."""
    if isinstance(value, list):
        lines = [scalar(v) for v in value]
    elif isinstance(value, dict):
        lines = [f"{k}={scalar(v)}" for k, v in value.items()]
    else:
        lines = [scalar(value)]
    return "".join(f"{line}\n" for line in lines)


# ---- box.env ------------------------------------------------------------------------------------
#
# KEY=value lines, blank lines and # comments. A value is bare (letters, digits and _ . / : @ % + , = -),
# or wrapped in single quotes (anything but '), or in double quotes (no ", \, $ or `). Anything else,
# an unknown key or a repeated key refuses the whole file. Errors name the line and key, never the value.
# Box jobs keep their schedule in the host's scheduler, so there are no job-time keys; secrets live elsewhere.

BOX_ENVS = ("local", "devbox", "review", "debug", "custom")
BOX_KEYS = {
    "MROOM_BOX_NAME": "the box's name, as the banner shows it",
    "MROOM_FORGE_ORG": "the Forge organisation",
    "MROOM_FORGE_SERVER": "the Forge server id of this box",
    "MROOM_REPO_URL": "the app repository's clone URL",
    "MROOM_SITE_API": "the dev site's API host",
    "MROOM_SITE_WEB": "the dev site's web host",
    "MROOM_SLACK_LOG_CHANNEL": "the chat channel for box logs",
    "MROOM_ENV": "local | devbox | review | debug | custom",
    "MROOM_WATCH_MCP": "MCP servers the watchdog checks: name=https://host/path items, space-separated",
    "MROOM_APP_NAME": "the app's name (app.name in mroom.toml); QA databases and roles are <name>_qa_<N>",
    "MROOM_QA_TEMPLATE": "the Postgres database every QA environment is cloned from",
    "MROOM_QA_ZONE": "the DNS zone of QA sites: api-<N>.<zone> and go-<N>.<zone>, owned by the user <name>_qa_<N>",
    "MROOM_QA_BACKEND_DIR": "the Laravel app's folder in the repository; . (the default) for its root",
    "MROOM_QA_PHP": "the PHP binary QA sites run, such as php8.4; php by default",
    "MROOM_QA_PERSONA_DOMAIN": "the domain QA personas' addresses end in, such as .test (the default)",
    "MROOM_QA_SMTP_PORT": "the port on 127.0.0.1 where mroom's mail relay takes QA apps' mail; 1025 by default",
}
# Names the gate builds SQL from, so each is a plain Postgres identifier (design 5.1, D18), matched as a
# whole (fullmatch: "$" alone would let a trailing newline through).
APP_NAME = re.compile(r"[a-z][a-z0-9_]{0,31}")
PG_NAME = re.compile(r"[a-z][a-z0-9_]{0,62}")
# What the gate builds QA site paths and commands from (D17): a DNS zone, a folder inside the repository
# (no . or .. part), a PHP binary's name and an address suffix.
DNS_ZONE = re.compile(r"(?=.{1,200}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+")
REPO_DIR = re.compile(r"\.|(?=.{1,200}$)[A-Za-z0-9_-][A-Za-z0-9._-]*(?:/[A-Za-z0-9_-][A-Za-z0-9._-]*)*")
PHP_BINARY = re.compile(r"php(?:[0-9]+(?:\.[0-9]+)?)?")
PERSONA_DOMAIN = re.compile(r"(?=.{2,200}$)(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+")
# A persona domain is made up: under a name reserved for that (RFC 2606, 6761), or a subdomain of a domain of
# your own (three labels or more), so never a public suffix such as .com, .co.uk or .github.io, where real
# people's addresses live.
RESERVED_SUFFIXES = (".test", ".example", ".invalid", ".localhost", ".example.com", ".example.net", ".example.org")
# One MROOM_WATCH_MCP item: an optional name=, then an http(s) URL of plain characters with no query,
# fragment or credentials. A bare URL is named by its host, and no two items may share a name.
WATCH_MCP_ITEM = re.compile(
    r"^(?:([a-z0-9][a-z0-9_-]{0,39})=)?(https?://([A-Za-z0-9.-]+(?::[0-9]{1,5})?)(?:/[A-Za-z0-9._~%+:=,/-]*)?)$")
BOX_LINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
BARE = re.compile(r"^[A-Za-z0-9_./:@%+,=-]*$")


def box_path() -> str:
    explicit = os.environ.get("MROOM_BOX_ENV")
    if explicit:
        return explicit
    return os.path.join(os.path.expanduser("~"), ".config", "mroom", "box.env")


def plain_env_value(value: str) -> bool:
    """An environment override must be a value box.env could hold: no control characters, nothing a
    double-quoted box.env value refuses."""
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        return False
    return parse_box_value(f'"{value}"') is not None


def box_value_error(key: str, value: str) -> str | None:
    if key == "MROOM_ENV" and value not in BOX_ENVS:
        return f"MROOM_ENV must be one of {', '.join(BOX_ENVS)}"
    if key == "MROOM_WATCH_MCP":
        return watch_mcp_error(value)
    if key == "MROOM_APP_NAME":
        if not APP_NAME.fullmatch(value):
            return "MROOM_APP_NAME must match [a-z][a-z0-9_]{0,31}, like app.name"
        if value == "pg" or value.startswith("pg_"):
            return "MROOM_APP_NAME may not be pg or start with pg_: Postgres reserves those role names"
    if key == "MROOM_QA_TEMPLATE" and not PG_NAME.fullmatch(value):
        return "MROOM_QA_TEMPLATE must be a plain Postgres name: [a-z][a-z0-9_]{0,62}"
    if key == "MROOM_QA_ZONE" and not DNS_ZONE.fullmatch(value):
        return "MROOM_QA_ZONE must be a lowercase DNS zone, such as qa.example.dev"
    if key == "MROOM_QA_BACKEND_DIR" and not REPO_DIR.fullmatch(value):
        return "MROOM_QA_BACKEND_DIR must be . or a folder inside the repository, with no . or .. part"
    if key == "MROOM_QA_PHP" and not PHP_BINARY.fullmatch(value):
        return "MROOM_QA_PHP must be a PHP binary's name, such as php8.4"
    if key == "MROOM_QA_PERSONA_DOMAIN" and not (
            PERSONA_DOMAIN.fullmatch(value) and (value.endswith(RESERVED_SUFFIXES) or value.count(".") >= 3)):
        return ("MROOM_QA_PERSONA_DOMAIN must be a domain suffix starting with a dot: a reserved name such as .test, "
                "or a subdomain of your own such as .qa.example.com")
    if key == "MROOM_QA_SMTP_PORT" and not (value.isascii() and value.isdigit() and 1024 <= int(value) <= 65535
                                             and value == str(int(value))):
        return "MROOM_QA_SMTP_PORT must be a port number from 1024 to 65535"
    return None


def watch_mcp_error(value: str) -> str | None:
    names = []
    for item in value.split():
        match = WATCH_MCP_ITEM.match(item)
        if not match:
            return ("MROOM_WATCH_MCP must be space-separated name=https://host/path items, each URL of plain "
                    "characters with no query, fragment or credentials")
        names.append(match.group(1) or match.group(3))
    if len(names) != len(set(names)):
        return "MROOM_WATCH_MCP must name each server once; give a bare URL a name= when two share a host"
    return None


def parse_box_value(raw: str) -> str | None:
    if len(raw) >= 2 and raw[0] == raw[-1] == "'":
        inner = raw[1:-1]
        return None if "'" in inner else inner
    if len(raw) >= 2 and raw[0] == raw[-1] == '"':
        inner = raw[1:-1]
        return None if any(c in inner for c in '"\\$`') else inner
    return raw if BARE.match(raw) else None


def parse_box(text: str, source: str) -> dict:
    values, errors = {}, []
    for number, line in enumerate(text.splitlines(), 1):
        line = line.rstrip()  # a trailing \r (CRLF files) or trailing spaces are not part of a value
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped != line:
            errors.append(f"line {number}: starts with whitespace; a KEY=value line starts at the first column")
            continue
        match = BOX_LINE.match(line)
        if not match:
            errors.append(f"line {number}: not a KEY=value line")
            continue
        key, raw = match.groups()
        if key not in BOX_KEYS:
            errors.append(f"line {number}: {key} is not an allowed key")
            continue
        if key in values:
            errors.append(f"line {number}: {key} is set twice")
            continue
        value = parse_box_value(raw)
        if value is None:
            errors.append(f"line {number}: {key} has a value that is not plain, or is quoted wrongly")
            continue
        problem = box_value_error(key, value)
        if problem:
            errors.append(f"line {number}: {problem}")
            continue
        values[key] = value
    if errors:
        raise ConfigError("\n".join(f"{source}: {e}" for e in errors))
    return values


def load_box() -> dict:
    path = box_path()
    try:
        with open(path, encoding="utf-8") as fh:
            values = parse_box(fh.read(), path)
    except FileNotFoundError:
        # Only the default path may be absent: an explicit MROOM_BOX_ENV names a file that must exist.
        if os.environ.get("MROOM_BOX_ENV"):
            raise ConfigError(f"MROOM_BOX_ENV={path}: no such file") from None
        values = {}
    except (OSError, UnicodeDecodeError) as exc:
        raise ConfigError(f"{path}: cannot read: {exc}") from None
    # A box.env key set in the environment wins (design 5.2), checked like a box.env value.
    for key in BOX_KEYS:
        if key in os.environ:
            value = os.environ[key]
            if not plain_env_value(value):
                raise ConfigError(f"environment: {key} has a value that is not plain")
            problem = box_value_error(key, value)
            if problem:
                raise ConfigError(f"environment: {problem}")
            values[key] = value
    return values


# ---- commands -----------------------------------------------------------------------------------

USAGE = __doc__.split("\n\n")[1]


def coerce_default(key: str, raw: str):
    """--default as a value of the key's type: an int for an int, JSON for a list or a table."""
    if key in SECTIONS:
        raise UsageError(f"--default does not apply to a table ({key})")
    kind = SCHEMA[key][0]
    value = raw
    if kind == "int":
        try:
            value = int(raw)
        except ValueError:
            raise UsageError(f"--default for {key} must be a whole number") from None
    elif kind in ("list", "map"):
        sample = "[]" if kind == "list" else "{}"
        try:
            value = json.loads(raw)
        except ValueError:
            raise UsageError(f"--default for {key} must be JSON, for example {sample}") from None
    problem = type_error(key, kind, value) or (rule_error(key, value) if kind == "str" else None)
    if problem:
        raise UsageError(f"--default: {problem}")
    return value


def cmd_get(args: list[str]) -> int:
    as_json, default, key = False, None, None
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--json":
            as_json = True
        elif arg == "--default":
            if i + 1 >= len(args):
                raise UsageError("--default needs a value")
            default = args[i + 1]
            i += 1
        elif arg.startswith("-"):
            raise UsageError(f"unknown option {arg}")
        elif key is None:
            key = arg
        else:
            raise UsageError("get takes one key")
        i += 1
    if key is None:
        raise UsageError("get needs a key, for example: mroom config get app.name")
    if key not in SCHEMA and key not in SECTIONS:
        hint = difflib.get_close_matches(key, list(SCHEMA) + sorted(SECTIONS), n=1)
        tip = f"; did you mean {hint[0]}?" if hint else " (mroom config keys lists them)"
        raise UsageError(f"{key} is not a mroom.toml key{tip}")
    fallback = coerce_default(key, default) if default is not None else None
    path, data = load_checked(key)
    try:
        value = lookup(data, key)
    except KeyError:
        if default is None:
            print(f"{PROG}: {key} is not set in {path}", file=sys.stderr)
            return 1
        value = fallback
    if as_json:
        sys.stdout.write(json.dumps(value) + "\n")
    elif key in SECTIONS:
        raise UsageError(f"{key} is a table; use --json")
    else:
        sys.stdout.write(render(value))
    return 0


def cmd_validate(args: list[str]) -> int:
    if args:
        raise UsageError("validate takes no arguments")
    path, _ = load_checked()
    print(f"{path}: ok")
    return 0


def cmd_path(args: list[str]) -> int:
    if args == ["--box"]:
        print(box_path())
        return 0
    if args:
        raise UsageError("path takes only --box")
    print(find_config())
    return 0


def cmd_keys(args: list[str]) -> int:
    if args:
        raise UsageError("keys takes no arguments")
    for key, (kind, required, _, text) in SCHEMA.items():
        shown = "|".join(kind) if isinstance(kind, tuple) else kind
        print(f"{key:24} {shown:15} {'required' if required else 'optional':9} {text}")
    return 0


def cmd_box(args: list[str]) -> int:
    if len(args) > 1:
        raise UsageError("box takes at most one KEY")
    if args and args[0] not in BOX_KEYS:
        raise UsageError(f"{args[0]} is not a box.env key; allowed: {', '.join(BOX_KEYS)}")
    values = load_box()
    if not args:
        for key, value in values.items():
            print(f"{key}={value}")
        return 0
    if args[0] not in values:
        print(f"{PROG}: {args[0]} is not set in {box_path()}", file=sys.stderr)
        return 1
    print(values[args[0]])
    return 0


COMMANDS = {"get": cmd_get, "validate": cmd_validate, "path": cmd_path, "keys": cmd_keys, "box": cmd_box}


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("help", "-h", "--help"):
        print("usage:\n" + USAGE)
        return 0 if argv else 2
    command = COMMANDS.get(argv[0])
    try:
        if command is None:
            raise UsageError(f"unknown command {argv[0]}")
        return command(argv[1:])
    except UsageError as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        return 2
    except ConfigError as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
