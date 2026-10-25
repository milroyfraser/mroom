# body.jq: how the regression label reads a pull request's body. check.sh and tools/regressions.sh both
# include it, so the check and the measures always read the same lines.

# text_lines: the lines of a PR body (the input, or null) that a reader sees as text. GitHub hides HTML
# comments, and a fenced code block shows an example, so a line inside either is not read: a PR template
# can show "Breaks: v1.2.3" in its guidance. As on GitHub, a comment or a fence that is never closed runs
# to the end of the body.
def text_lines:
  # A fence opens with three or more backticks (and no backtick later on the line) or tildes, and closes
  # with a line of at least as many of the same character.
  def opens_fence: (capture("^[ \t]*(?<f>`{3,}(?=[^`]*$)|~{3,})").f) // null;
  def closes_fence($f): test("^[ \t]*" + $f + $f[:1] + "*[ \t]*$");
  foreach ((. // "") | gsub("\r"; "") | split("\n")[]) as $line ({fence: null, comment: false};
    .text = null
    | if .fence then
        .fence as $f | if ($line | closes_fence($f)) then .fence = null else . end
      elif (.comment | not) and ($line | opens_fence) then
        .fence = ($line | opens_fence)
      else
        # A line that starts inside a comment is read as if the comment opened at its start.
        ((if .comment then "<!--" else "" end) + $line) as $s
        | .text = ($s | gsub("<!--.*?(-->|$)"; ""))
        | .comment = ($s | gsub("<!--.*?-->"; "") | test("<!--"))
      end;
    .text // empty);

# field($name): the rest of a PR body's first text line "Name: ..." (any case), trimmed, or "".
def field($name):
  first(text_lines | select(test("^\\s*" + $name + ":"; "i"))) // ""
  | sub("^[^:]*:\\s*"; "") | sub("\\s+$"; "");
