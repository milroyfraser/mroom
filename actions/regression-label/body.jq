# body.jq: how the regression label reads a pull request's body. check.sh and tools/regressions.sh both
# include it, so the check and the measures always read the same lines.

# text_lines: the lines of a PR body (the input, or null) that a reader sees as text, close to how GitHub
# shows them:
# - A fenced code block is an example, so its lines are skipped. A fence may follow a list marker, and one
#   that is never closed runs to the end of the body.
# - A comment that starts a line, a list item or a quote hides everything up to the next "-->", or to the
#   end of the body, as GitHub's sanitiser does. A comment inside a line hides up to a "-->" on that line;
#   without one it is text, as GitHub shows it (for example `<!--` in inline code).
# Not recognised: indented code blocks, <pre> and fences inside quotes, whose lines count.
def text_lines:
  # A fence is three or more backticks (with no backtick later on the line) or tildes. It closes on a line
  # of at least as many of the same character and nothing else.
  def opens_fence: (capture("^[ \t]*(?:(?:[-*+]|[0-9]+[.)])[ \t]+)?(?<f>`{3,}(?=[^`]*$)|~{3,})").f) // null;
  def closes_fence($f):
    (capture("^[ \t]*(?<c>`+|~+)[ \t]*$").c // "") | .[:1] == $f[:1] and length >= ($f | length);
  def starts_comment: test("^[ \t]*(?:(?:[-*+]|[0-9]+[.)]|>)[ \t]*)*<!--");
  # A whole comment: <!-- ... -->, or the empty <!--> or <!--->.
  def whole_comment: "<!--(?:-?>|.*?-->)";
  # A line of raw HTML (one that starts or ends a comment): its text without comments, and whether a
  # comment is still open at its end, which hides the lines after it.
  def raw_html:
    {text: gsub(whole_comment + "|<!--.*$"; ""), comment: (gsub(whole_comment; "") | test("<!--"))};
  foreach ((. // "") | split("\n")[] | rtrimstr("\r")) as $line ({fence: null, comment: false};
    .text = null
    | if .fence then
        .fence as $f | if ($line | closes_fence($f)) then .fence = null else . end
      elif .comment then
        # Only "-->" ends a comment; what follows it on the line is raw HTML too.
        if ($line | test("-->")) then . + ($line | sub("^.*?-->"; "") | raw_html) else . end
      elif ($line | opens_fence) then
        .fence = ($line | opens_fence)
      elif ($line | starts_comment) then
        . + ($line | raw_html)
      else
        .text = ($line | gsub(whole_comment; ""))
      end;
    .text // empty);

# field($name): the value of a PR body's first text line "Name: value" (any case), trimmed, or "". A line
# with no value, such as a template's "Breaks:" left empty, is passed over.
def field($name):
  first(text_lines | capture("^\\s*" + $name + ":\\s*(?<v>.*\\S)"; "i").v) // "";
