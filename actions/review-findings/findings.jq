# findings.jq — reading Claude review comments (actions/claude-review), for the review findings check
# (evaluate.jq) and, later, the PR status notes. Pure jq, no API calls.

# A line without its leading markdown: quote, heading and list markers, bold.
def bare: sub("^(\\s|>|#|[-*+]\\s|[0-9]+[.)]\\s|\\*\\*|__)*"; "");
def item: test("^\\s*(>\\s*)?([-*+]|[0-9]+[.)])\\s");
# A finding line's marker: the first emoji after the quote, heading and list markers and an optional
# bold label (`- ❌ …`, `**🔴 Blocking**`, `1. **`a.php:3`**: ✅ …`); null when the line doesn't start
# with one. Emoji later in the line are prose ("❌ still open, was ✅ before" is still open).
def lead:
  sub("^(\\s|>|#|[-*+]\\s|[0-9]+[.)]\\s)*"; "")
  | first(capture("^(\\*\\*[^*]*\\*\\*|__[^_]*__)?\\s*:?\\s*(\\*\\*|__)?\\s*(?<e>✅|💬|❌|🟡|🟣|🔴)").e) // null;

# Open blocking findings in a Claude review comment (actions/claude-review), or
# null when the comment's format isn't recognised. A full review lists them under a 🔴 heading or
# marks each with 🔴; a follow-up marks each earlier one ✅ fixed, 💬 settled (both count 0) or ❌
# still open, and may add new 🔴 ones. Each line counts by its leading marker only (lead), except
# that in a follow-up (one that uses ✅, ❌ or 💬 at all) an item's status marker wins over a leading
# 🔴: "🔴 `a.php` — ✅ fixed" is fixed. Counting under a 🔴 Blocking heading stops at the next heading.
def heading: test("^\\s*(>\\s*)?#{1,6}\\s") or ((item | not) and (bare | test("^(🔴|🟡|🟣)?\\s*(\\*\\*[^*]+\\*\\*|__[^_]+__)\\s*:?\\s*$")));
def blocking_count:
  (split("\n") | map(select(test("\\S")))) as $lines
  | (any($lines[]; test("✅|❌|💬"))) as $followup
  | if $lines[0:3] | any(bare | test("^No blocking findings"; "i")) then 0
    else
      reduce $lines[] as $l ({in: false, n: 0, seen: false};
        ($l | lead) as $lead
        | (if $lead == "🔴" and $followup then (first($l | match("✅|❌|💬").string) // "🔴") else $lead end) as $e
        | if $e == "✅" or $e == "💬" then .seen = true
          elif $e == "❌" then .n += 1 | .seen = true
          elif $e == "🟡" or $e == "🟣" then .in = false | .seen = true
          elif $l | bare | test("^🔴\\s*(\\*\\*)?Blocking(\\*\\*)?\\s*:?\\s*$"; "i") then .in = true | .seen = true
          elif $l | heading then .in = false
          elif $e == "🔴" then .n += 1 | .seen = true
          elif .in and ($l | item) then .n += 1
          else . end)
      | if .n > 0 then .n elif .seen then 0 else null end
    end;
