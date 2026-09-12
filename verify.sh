#!/bin/sh
# omp-orchestra verify — validate routing, installed-config drift, and live models.
#
#   ./verify.sh              # all checks
#   ./verify.sh --static     # no network
#   ./verify.sh --no-drift   # omit install.sh comparison
#   ./verify.sh task smol    # probe only these roles
#   ./verify.sh --profile codex
set -eu

command -v omp >/dev/null 2>&1 || { printf 'FAIL: omp is not on PATH\n' >&2; exit 1; }

PROFILE=
STATIC=false
NO_DRIFT=false
FILTERS=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --static) STATIC=true ;;
    --no-drift) NO_DRIFT=true ;;
    --profile)
      shift
      [ "$#" -gt 0 ] || { printf 'FAIL: --profile requires a name\n' >&2; exit 1; }
      PROFILE=$1
      ;;
    --profile=*) PROFILE=${1#--profile=} ;;
    --*) printf 'FAIL: unknown option: %s\n' "$1" >&2; exit 1 ;;
    *) FILTERS="${FILTERS}${FILTERS:+\n}$1" ;;
  esac
  shift
done

TAB="$(printf '\t')"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

fail() {
  printf 'FAIL: %s\n' "$1"
  FAILS=$((FAILS + 1))
}

# Flat JSON records used by omp config are strings.  Preserve commas in values;
# splitting is deliberately deferred to the routing/probe consumers.
json_pairs() {
  awk '
    { gsub(/[{}]/, "")
      n = split($0, kv, /","/)
      for (i = 1; i <= n; i++) {
        p = kv[i]; gsub(/"/, "", p)
        sep = index(p, ":")
        if (sep == 0) continue
        key = substr(p, 1, sep - 1)
        value = substr(p, sep + 1)
        gsub(/^[ \t\n]+|[ \t\n]+$/, "", key)
        gsub(/^[ \t\n]+|[ \t\n]+$/, "", value)
        if (key != "") printf "%s\t%s\n", key, value
      }
    }'
}

ROLES_JSON="$(omp config get modelRoles)"
OVERRIDES_JSON="$(omp config get task.agentModelOverrides)"
CHAINS_JSON="$(omp config get retry.fallbackChains 2>/dev/null || printf '{}')"
printf '%s' "$ROLES_JSON" | tr -d '\n' | json_pairs > "$TMP/roles"
printf '%s' "$OVERRIDES_JSON" | tr -d '\n' | json_pairs > "$TMP/overrides"
# retry.fallbackChains is a record of arrays, not a flat string record.
# Keep each array intact, then strip its brackets while retaining its commas.
printf '%s' "$CHAINS_JSON" | tr -d '\n' | awk '
  { gsub(/[{}"]/, "")
    n = split($0, fields, /],/)
    for (i = 1; i <= n; i++) {
      field = fields[i]
      sep = index(field, ":")
      if (sep == 0) continue
      key = substr(field, 1, sep - 1)
      value = substr(field, sep + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      gsub(/^[ \t]*\[|][ \t]*$/, "", value)
      if (key != "") printf "%s\t%s\n", key, value
    }
  }' > "$TMP/chains"

role_value() {
  awk -F "$TAB" -v role="$1" '$1 == role { print substr($0, length($1) + 2); exit }' "$TMP/roles"
}

override_value() {
  awk -F "$TAB" -v role="$1" '$1 == role { print substr($0, length($1) + 2); exit }' "$TMP/overrides"
}

strip_level() {
  printf '%s\n' "$1" | awk '{ sub(/:(xhigh|high|medium|low|minimal|auto)$/, ""); print }'
}
# receives a concrete provider/model, or a non-zero result for a bad route.
resolve() {
  selector=$(strip_level "$1")
  depth=${2:-0}
  case "$selector" in
    @*)
      [ "$depth" -lt 5 ] || return 1
      name=${selector#@}
      value=$(role_value "$name")
      [ -n "$value" ] || return 1
      first=$(printf '%s' "$value" | awk -F ',' '{ gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1 }')
      resolve "$first" $((depth + 1))
      ;;
    */*) printf '%s\n' "$selector" ;;
    *) return 1 ;;
  esac
}

vendor() {
  resolved=$(resolve "$1") || return 1
  printf '%s\n' "${resolved%%/*}"
}

check_aliases() {
  aliases=$(awk '
    { text = substr($0, index($0, "\t") + 1)
      while (match(text, /@[A-Za-z0-9_-]+(:[A-Za-z]+)?/)) {
        print substr(text, RSTART, RLENGTH)
        text = substr(text, RSTART + RLENGTH)
      }
    }' "$TMP/roles" "$TMP/overrides" | sort -u)
  bad=
  for alias in $aliases; do
    resolve "$alias" >/dev/null 2>&1 || bad="${bad}${bad:+, }$alias"
  done
  if [ -n "$bad" ]; then fail "aliases resolve ($bad)"; else printf 'ok: aliases resolve\n'; fi
}

check_vendor_relation() {
  label=$1
  left=$2
  operator=$3
  right=$4
  lv=$(vendor "$left" 2>/dev/null || printf '')
  rv=$(vendor "$right" 2>/dev/null || printf '')
  if [ -z "$lv" ] || [ -z "$rv" ]; then
    fail "$label (unresolvable role)"
  elif [ "$operator" = '=' ] && [ "$lv" = "$rv" ]; then
    printf 'ok: %s\n' "$label"
  elif [ "$operator" = '!' ] && [ "$lv" != "$rv" ]; then
    printf 'ok: %s\n' "$label"
  else
    fail "$label ($lv vs $rv)"
  fi
}

check_cheap_chains() {
  bad=$(awk -F "$TAB" '
    $1 == "tiny" || $1 == "commit" || $1 == "smol" {
      n = split($2, values, /,/) 
      for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", values[i])
        if (values[i] !~ /^google-antigravity\// &&
            values[i] !~ /^openrouter\// &&
            values[i] != "openai-codex/gpt-5.6-luna")
          printf "%s=%s ", $1, values[i]
      }
    }' "$TMP/chains")
  if [ -n "$bad" ]; then fail "cheap fallback chains ($bad)"; else printf 'ok: cheap fallback chains\n'; fi
}

printf '==> static routing\n'
check_aliases
check_vendor_relation 'default vendor equals plan' @default = @plan
check_vendor_relation 'default vendor differs from slow' @default '!' @slow
check_vendor_relation 'default vendor differs from advisor' @default '!' @advisor
# Tester is the only required agent-model override.
tester=$(override_value Tester)
if [ -z "$tester" ]; then
  fail 'task vendor differs from Tester override (missing Tester override)'
else
  check_vendor_relation 'task vendor differs from Tester override' @task '!' "$tester"
fi
check_cheap_chains

printf '==> drift\n'
INSTALL="$(dirname "$0")/install.sh"
if [ "$NO_DRIFT" = true ]; then
  printf 'skip: drift (--no-drift)\n'
elif [ ! -f "$INSTALL" ]; then
  printf 'skip: drift (install.sh not found)\n'
else
  if [ -n "$PROFILE" ]; then
    sh "$INSTALL" --print "$PROFILE" > "$TMP/expected"
  else
    sh "$INSTALL" --print > "$TMP/expected"
  fi
  while IFS="$TAB" read -r key expected; do
    [ -n "$key" ] || continue
    live=$(omp config get "$key" 2>/dev/null) || live='<unset>'
    compact_live=$(printf '%s' "$live" | tr -d ' \t\n')
    compact_expected=$(printf '%s' "$expected" | tr -d ' \t\n')
    if [ "$compact_live" = "$compact_expected" ]; then
      printf 'ok: drift %s\n' "$key"
    else
      sorted_live=$(printf '%s' "$compact_live" | fold -w1 | sort | tr -d '\n')
      sorted_expected=$(printf '%s' "$compact_expected" | fold -w1 | sort | tr -d '\n')
      if [ "$sorted_live" = "$sorted_expected" ]; then
        printf 'ok: drift %s (reordered)\n' "$key"
      else
        fail "drift $key (live=$live expected=$expected)"
      fi
    fi
  done < "$TMP/expected"
fi

printf '==> live probe\n'
if [ "$STATIC" = true ]; then
  printf 'skip: live probe (--static)\n'
else
  : > "$TMP/probes"
  # Expand role values recursively.  An alias expands its complete list here,
  # unlike resolve(), whose first-entry semantics define role vendor.
  expand() {
    value=$1
    depth=${2:-0}
    [ "$depth" -lt 5 ] || return 1
    printf '%s' "$value" | awk -F ',' '{ for (i = 1; i <= NF; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i); print $i } }' |
    while IFS= read -r entry; do
      entry=$(strip_level "$entry")
      case "$entry" in
        @*)
          target=$(role_value "${entry#@}")
          [ -n "$target" ] || return 1
          expand "$target" $((depth + 1))
          ;;
        */*) printf '%s\n' "$entry" ;;
        *) return 1 ;;
      esac
    done
  }
  if [ -n "$FILTERS" ]; then
    printf '%b\n' "$FILTERS" | while IFS= read -r role; do
      value=$(role_value "$role")
      if [ -z "$value" ]; then
        printf 'FAIL: probe role %s not found\n' "$role" >&2
        exit 1
      fi
      expand "$value"
    done > "$TMP/probes" || { fail 'selected probe role is invalid'; }
  else
    while IFS="$TAB" read -r role value; do expand "$value"; done < "$TMP/roles" > "$TMP/probes" || fail 'modelRoles contains an invalid route'
    awk -F "$TAB" '{ n = split($2, values, /,/); for (i = 1; i <= n; i++) { gsub(/^[ \t]+|[ \t]+$/, "", values[i]); print values[i] } }' "$TMP/chains" >> "$TMP/probes"
  fi
  # Fallback must be off for the probe: otherwise a dead primary silently
  # answers from its chain and the probe reports the wrong model as healthy.
  printf 'retry:\n  modelFallback: false\n  usageAwareFallback: false\n' > "$TMP/probe.yml"
  sort -u "$TMP/probes" | while IFS= read -r model; do
    [ -n "$model" ] || continue
    if output=$(omp -p --config "$TMP/probe.yml" --model "$model" 'Reply with exactly: OK' 2>&1 </dev/null); then
      printf 'ok: probe %s\n' "$model"
    else
      first=$(printf '%s\n' "$output" | awk '$0 != "" && $0 != "Working..." { print; exit }')
      case "$first" in
        *[Cc]redential*|*[Nn]ot\ logged\ in*|*[Nn]o\ API\ key*|*[Mm]issing\ API\ key*|*[Ll]og\ in\ *|*login*)
          printf 'skip: probe %s (no credentials: %s)\n' "$model" "$first"
          ;;
        # Quota walls are what fallback chains exist for; only permanent
        # (entitlement/invalid_request/billing) failures count against the config.
        *429*|*RESOURCE_EXHAUSTED*|*[Rr]ate\ limit*|*[Rr]etry\ budget\ exhausted*)
          printf 'rate: probe %s (transient quota: %s)\n' "$model" "$first"
          ;;
        *)
          printf 'FAIL: probe %s (%s)\n' "$model" "$first"
          printf '%s\n' "$model" >> "$TMP/probe-failures"
          ;;
      esac
    fi
  done
  if [ -f "$TMP/probe-failures" ]; then
    count=$(awk 'END { print NR }' "$TMP/probe-failures")
    FAILS=$((FAILS + count))
  fi
fi

if [ "$FAILS" -gt 0 ]; then
  printf '==> %d check(s) FAILED\n' "$FAILS"
  exit 1
fi
printf '==> all checks passed\n'
