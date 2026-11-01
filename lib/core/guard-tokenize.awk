# Tokeniser for lib/guard (mroom guard): splits the shell command on stdin into simple commands, one per
# output line, in linear time (awk indexes characters in O(1) after split(); bash 3.2's ${s:i:1}
# is O(n) per call, which made an earlier tokeniser in bash quadratic).
#
# Output line:  META US TOKEN US TOKEN ...
#   META is three characters: "p" or "-" for stdin piped from the previous command, "p" or "-" for
#   stdout piped to the next one, "s" or "-" for running inside $(...), `...` or <(...).
#   Newlines inside a token are written as \035, and read back as newlines on input. US is \037.
# Marker tokens (\034 + name) stand for redirections, followed by their operand where they have one:
#   R< file   R> file   HS word (here-string)   HD body (heredoc)   PS (a process substitution)
#   BL (the next token holds an unquoted brace list)   UE (a $'...' escape not decoded: \u \U \c)
# A file-descriptor number before a redirection (`2>/dev/null`, `2>&1`) is dropped with it.
# \033 marks an expansion ($X, ${X}, $(...), `...`): its value is unknown here.
# Quotes are removed, $'...' escapes are decoded, $"..." is read as "...". Heredoc bodies are read
# whichever command they belong to; the caller decides whether a body is commands or data.
# Portable awk (macOS BWK awk, gawk, mawk): no gawk-only functions, and no array named after a
# gawk built-in variable (RT, FPAT, ...).

function syncbuf() { if (NB) { TK[d] = TK[d] BUF; BUF = ""; NB = 0 } }
function addc(s) { BUF = BUF s; NB++; if (NB >= 256) syncbuf() }
function addtok(t) { T[d, ++NT[d]] = t }
function flushtok() {
  syncbuf()
  if (BL[d]) addtok(MK "BL")
  if (TK[d] != "" || HV[d]) addtok(TK[d])
  TK[d] = ""; HV[d] = 0; BO[d] = 0; BC[d] = 0; BL[d] = 0; LC[d] = ""
}
# A file-descriptor number written against a redirection (`2>`, `2>&1`) is part of it, not a word.
function dropfd() { syncbuf(); if (!HV[d] && TK[d] ~ /^[0-9]+$/) TK[d] = "" }
function emit(   r, j) {
  flushtok()
  if (NT[d] == 0) return
  r = ++R
  IN[r] = PIN[d] ? "p" : "-"
  OUT[r] = "-"
  SUBF[r] = SUB[d] ? "s" : "-"
  NRT[r] = NT[d]
  for (j = 1; j <= NT[d]; j++) RTK[r, j] = T[d, j]
  NT[d] = 0
  PIN[d] = 0
  LAST[d] = r
}
function sep() { emit(); PIN[d] = 0; LAST[d] = 0 }
function pipe() { emit(); if (LAST[d]) OUT[LAST[d]] = "p"; PIN[d] = 1 }
function push(kind) {
  syncbuf()
  d++
  NT[d] = 0; TK[d] = ""; HV[d] = 0; LAST[d] = 0; KIND[d] = kind; QRET[d] = q
  BO[d] = 0; BC[d] = 0; BL[d] = 0; LC[d] = ""
  PIN[d] = (kind == "(") ? PIN[d - 1] : 0
  SUB[d] = SUB[d - 1] || kind != "("
  q = "n"
}
function pop() { emit(); q = QRET[d]; d-- }
function readheredocs(   k, h, ln, t) {
  for (k = 1; k <= NP; k++) {
    h = PEND[k]
    while (li < NL) {
      li++
      ln = L[li]
      t = ln
      sub(/^\t+/, "", t)
      if (t == HDL[h]) break
      HB[h] = HB[h] ln "\n"
    }
  }
  NP = 0
}
function hexval(s,   v, k) {
  v = 0
  for (k = 1; k <= length(s); k++) v = v * 16 + index("0123456789abcdef", tolower(substr(s, k, 1))) - 1
  return v
}
function octval(s,   v, k) {
  v = 0
  for (k = 1; k <= length(s); k++) v = v * 8 + substr(s, k, 1)
  return v
}
function chr(v) { return (v > 0 && v < 256) ? sprintf("%c", v) : "" }

BEGIN {
  US = "\037"; NLE = "\035"; MK = "\034"; DY = "\033"
  EXP = "[A-Za-z0-9_{@*#?!$-]"
  NL = 0
  # \035 in the input is a newline written by an earlier pass (a token handed back to be checked).
  while ((getline line) > 0) {
    np = split(line, PARTS, NLE)
    if (np == 0) L[++NL] = ""
    for (k = 1; k <= np; k++) L[++NL] = PARTS[k]
  }
  d = 0; q = "n"; R = 0; NH = 0; NP = 0; BUF = ""; NB = 0
  NT[0] = 0; TK[0] = ""; HV[0] = 0; PIN[0] = 0; LAST[0] = 0; KIND[0] = ""; SUB[0] = 0

  for (li = 1; li <= NL; li++) {
    m = split(L[li], C, "")
    C[m + 1] = "\n"
    C[m + 2] = ""
    for (i = 1; i <= m + 1; i++) {
      c = C[i]
      nx = C[i + 1]

      if (q == "s") {
        if (c == "'") q = "n"; else addc(c)
        continue
      }

      if (q == "a") {
        if (c == "'") { q = "n"; continue }
        if (c != "\\") { addc(c); continue }
        i++
        e = C[i]
        if (e == "n") addc("\n")
        else if (e == "t") addc("\t")
        else if (e == "r") addc("\r")
        else if (e == "a") addc(chr(7))
        else if (e == "b") addc(chr(8))
        else if (e == "e" || e == "E") addc(chr(27))
        else if (e == "f") addc(chr(12))
        else if (e == "v") addc(chr(11))
        else if (e == "x") {
          hx = ""
          while (length(hx) < 2 && C[i + 1] ~ /^[0-9A-Fa-f]$/) { i++; hx = hx C[i] }
          addc(chr(hexval(hx)))
        } else if (e ~ /^[0-7]$/) {
          oc = e
          while (length(oc) < 3 && C[i + 1] ~ /^[0-7]$/) { i++; oc = oc C[i] }
          addc(chr(octval(oc)))
        } else if (e == "u" || e == "U" || e == "c") {
          addtok(MK "UE") # an escape not decoded here: the caller refuses the command
          addc(e)
        } else addc(e)
        continue
      }

      if (q == "d") {
        if (c == "\"") { q = "n"; continue }
        if (c == "\\") {
          if (nx == "\n") { i++; continue }
          if (nx == "$" || nx == "`" || nx == "\"" || nx == "\\") { addc(nx); i++; continue }
          addc(c)
          continue
        }
        if (c == "$" && nx == "(") { addc(DY "$()"); HV[d] = 1; i++; push("$("); continue }
        if (c == "$" && nx ~ EXP) { addc(DY "$"); continue }
        if (c == "`") { addc(DY "``"); HV[d] = 1; push("`"); continue }
        addc(c)
        continue
      }

      # Unquoted.
      if (c == "\\") {
        if (nx == "\n") { i++; continue }
        addc(nx); HV[d] = 1; i++
        continue
      }
      if (c == "'") { q = "s"; HV[d] = 1; continue }
      if (c == "\"") { q = "d"; HV[d] = 1; continue }
      if (c == "$") {
        if (nx == "'") { q = "a"; HV[d] = 1; i++; continue }
        if (nx == "\"") { q = "d"; HV[d] = 1; i++; continue }
        if (nx == "(") { addc(DY "$()"); HV[d] = 1; i++; push("$("); continue }
        if (nx ~ EXP) { addc(DY "$"); LC[d] = "$"; continue }
        addc(c)
        continue
      }
      if (c == "`") {
        if (KIND[d] == "`") { pop(); continue }
        addc(DY "``"); HV[d] = 1; push("`")
        continue
      }
      if (c == "(") { flushtok(); push("("); continue }
      if (c == ")") {
        if (d > 0 && KIND[d] != "`") pop(); else sep()
        continue
      }
      if (c == ";") { sep(); if (nx == ";") i++; continue }
      if (c == "&") {
        if (nx == ">") {
          dropfd(); flushtok(); addtok(MK "R>"); i++
          if (C[i + 1] == ">") i++
          continue
        }
        if (nx == "&") i++
        sep()
        continue
      }
      if (c == "|") {
        if (nx == "|") { i++; sep(); continue }
        if (nx == "&") i++
        pipe()
        continue
      }
      if (c == "\n") { sep(); readheredocs(); continue }
      if (c == " " || c == "\t") { flushtok(); continue }
      if (c == "<") {
        if (nx == "(") { flushtok(); addtok(MK "PS"); i++; push("<("); continue }
        if (nx == "<" && C[i + 2] == "<") { flushtok(); addtok(MK "HS"); i += 2; continue }
        if (nx == "<") {
          i += 2
          if (C[i] == "-") i++
          while (C[i] == " " || C[i] == "\t") i++
          dl = ""
          while (i <= m) {
            c2 = C[i]
            if (c2 == " " || c2 == "\t" || c2 == ";" || c2 == "&" || c2 == "|" || c2 == "(" || c2 == ")" || c2 == "<" || c2 == ">") break
            if (c2 != "'" && c2 != "\"" && c2 != "\\") dl = dl c2
            i++
          }
          i--
          NH++; HDL[NH] = dl; HB[NH] = ""; PEND[++NP] = NH
          flushtok(); addtok(MK "HD"); addtok(MK "HB" NH)
          continue
        }
        dropfd(); flushtok(); addtok(MK "R<")
        if (nx == "&" || nx == ">") i++
        continue
      }
      if (c == ">") {
        if (nx == "(") { flushtok(); addtok(MK "PS"); i++; push("<("); continue }
        dropfd(); flushtok(); addtok(MK "R>")
        while (C[i + 1] == ">" || C[i + 1] == "|" || C[i + 1] == "&") i++
        continue
      }
      if (c == "#" && TK[d] == "" && NB == 0 && !HV[d]) { i = m; continue }
      # An unquoted brace list ({a,b} or {x..y}, not ${...}): the token gets a BL marker before it.
      if (c == "{") { if (LC[d] != "$") BO[d]++ }
      else if (c == "," && BO[d]) BC[d] = 1
      else if (c == "." && BO[d] && LC[d] == ".") BC[d] = 1
      else if (c == "}" && BO[d]) { if (BC[d]) BL[d] = 1; BO[d]-- }
      LC[d] = c
      addc(c)
    }
  }
  while (d > 0) pop()
  emit()

  for (r = 1; r <= R; r++) {
    out = IN[r] OUT[r] SUBF[r]
    for (j = 1; j <= NRT[r]; j++) {
      t = RTK[r, j]
      if (substr(t, 1, 3) == MK "HB") t = HB[substr(t, 4) + 0]
      gsub("[" NLE US "]", "", t)
      gsub(/\n/, NLE, t)
      out = out US t
    }
    print out
  }
}
