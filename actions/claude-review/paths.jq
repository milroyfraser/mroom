# paths.jq — path patterns as the app lists them (the claude-review workflow's paths and review-guide-paths
# inputs), matched the way a workflow's `on.<event>.paths` matches: `*` and `?` stay inside one folder, `**`
# crosses folders, and `docs/**` matches every file under docs. One pattern per line; blank lines and lines
# starting with # are skipped. No negation (`!`) and no character classes: `[` is a plain character.

def patterns:
  split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "" and (startswith("#") | not)));

# A pattern as an anchored regular expression. Every regex character is escaped first, so only *, ** and ?
# mean anything.
def glob_re:
  gsub("(?<c>[.+^${}()|\\[\\]\\\\])"; "\\\(.c)")
  | gsub("\\*\\*/"; "\u0001") | gsub("\\*\\*"; "\u0002")
  | gsub("\\*"; "[^/]*") | gsub("\\?"; "[^/]")
  | gsub("\u0001"; "(.*/)?") | gsub("\u0002"; ".*")
  | "^" + . + "$";

# A file path (the input) matches one of the patterns.
def matches_any($pats): . as $f | any($pats[]; . as $p | $f | test($p | glob_re));
