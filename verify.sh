#!/bin/sh
# omp-orchestra verify — live-probe every model in the routing table.
#
#   ./verify.sh              # probe modelRoles + retry.fallbackChains models
#   ./verify.sh task smol    # probe only these roles (skips chain sweep)
#
# Why this exists: comma-list role fallbacks only check *provider credentials*,
# and retry.fallbackChains only trips on 429/5xx-class errors. A model that is
# plan-gated or tier-blocked fails with invalid_request_error and NOTHING falls
# back — the role just hard-fails (observed 2026-07-08 when mainline
# gpt-5.x-codex models were gated off ChatGPT accounts, and 2026-07-05 when
# Fable access was tier-blocked). Run this after provider or plan changes.
set -eu

command -v omp >/dev/null 2>&1 || { printf 'error: omp is not on PATH\n' >&2; exit 1; }

ROLES_JSON="$(omp config get modelRoles)"
CHAINS_JSON="$(omp config get retry.fallbackChains 2>/dev/null || printf '{}')"
TAB="$(printf '\t')"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# ── Collect "label<TAB>model" pairs ──────────────────────────────────────────
# modelRoles: flat JSON object of "role":"model, model, ..." pairs.
printf '%s' "$ROLES_JSON" | awk '
  { gsub(/[{}]/, "")
    n = split($0, kv, /","/)
    for (i = 1; i <= n; i++) {
      p = kv[i]; gsub(/"/, "", p)
      sep = index(p, ":")
      if (sep == 0) continue
      role = substr(p, 1, sep - 1)
      gsub(/^[ \t\n]+|[ \t\n]+$/, "", role)
      m = split(substr(p, sep + 1), models, /,/)
      for (j = 1; j <= m; j++) {
        gsub(/^ +| +$/, "", models[j])
        if (models[j] != "") printf "%s\t%s\n", role, models[j]
      }
    } }' > "$TMP"

# Role filter: positional args restrict to those roles (and skip chain sweep).
if [ "$#" -gt 0 ]; then
  FILTER="$(printf '%s\n' "$@")"
  awk -F "$TAB" -v f="$FILTER" '
    BEGIN { n = split(f, w, "\n"); for (i = 1; i <= n; i++) keep[w[i]] = 1 }
    keep[$1]' "$TMP" > "$TMP.f" && mv "$TMP.f" "$TMP"
else
  # retry.fallbackChains: harvest every "provider/model" string token.
  printf '%s' "$CHAINS_JSON" | awk '
    { while (match($0, /"[a-z0-9._-]+\/[^"]+"/)) {
        printf "chain\t%s\n", substr($0, RSTART + 1, RLENGTH - 2)
        $0 = substr($0, RSTART + RLENGTH)
      } }' >> "$TMP"
fi

# ── Probe each unique model once (thinking suffix stripped; :free kept) ──────
FAILS=0
PROBED="|"
printf '==> omp-orchestra verify\n'
while IFS="$TAB" read -r LABEL MODEL; do
  M="$(printf '%s' "$MODEL" | sed -E 's/:(xhigh|high|medium|low|minimal|auto)$//')"
  case "$PROBED" in *"|$M|"*) continue ;; esac
  PROBED="$PROBED$M|"
  if OUT="$(omp -p --model "$M" 'Reply with exactly: OK' 2>&1)"; then
    printf '    ok:   %-48s (%s)\n' "$M" "$LABEL"
  else
    FIRST="$(printf '%s' "$OUT" | head -n 1)"
    case "$FIRST" in
      # Providers are optional by design ("any subset works") — a missing
      # login/key is a skip, not a routing failure. Deliberately narrow:
      # "not authorized"/plan/tier entitlement errors MUST stay FAIL.
      *[Cc]redential*|*[Nn]ot\ logged\ in*|*[Nn]o\ API\ key*|*[Mm]issing\ API\ key*|*[Ll]og\ in\ *|*login*)
        printf '    skip: %-48s (%s) — no credentials: %s\n' "$M" "$LABEL" "$FIRST"
        ;;
      *)
        printf '    FAIL: %-48s (%s) — %s\n' "$M" "$LABEL" "$FIRST"
        FAILS=$((FAILS + 1))
        ;;
    esac
  fi
done < "$TMP"

if [ "$FAILS" -gt 0 ]; then
  printf '==> %d model(s) FAILED — fix modelRoles/chains or swap profiles\n' "$FAILS"
  exit 1
fi
printf '==> all probed models respond\n'
