#!/bin/sh
# omp-orchestra — tiered model orchestration for Oh My Pi (omp)
#
# Concrete model ids live only in the frontier_a, frontier_b, strong_a,
# strong_b, worker, tester, scout, and micro tiers below.
# To adopt a new model, edit one tier line instead of every functional role.
# Fallback chains must remain concrete: omp does not accept @aliases there,
# and an unknown entry silently breaks the role.
#
# Applies every setting through `omp config set` (schema-validated), leaving
# unrelated settings untouched. Existing config.yml is backed up first.
set -eu

say()  { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

PRINT=0
PROFILE="${OMP_ORCHESTRA_PROFILE:-claude}"
PROFILE_ARG=0
for ARG in "$@"; do
  case "$ARG" in
    --print)
      PRINT=1
      ;;
    claude|codex)
      [ "$PROFILE_ARG" -eq 0 ] || fail "multiple profiles specified"
      PROFILE="$ARG"
      PROFILE_ARG=1
      ;;
    *)
      fail "unknown profile '$ARG' (valid: claude, codex)"
      ;;
  esac
done

case "$PROFILE" in
  claude|codex) ;;
  *) fail "unknown profile '$PROFILE' (valid: claude, codex)" ;;
esac

if [ "$PRINT" -eq 0 ]; then
  command -v omp >/dev/null 2>&1 || fail "omp is not installed (or not on PATH).
Install Oh My Pi first, then re-run this script."
fi

# ── Tier table ────────────────────────────────────────────────────────────────
ANTH_FRONTIER="anthropic/claude-fable-5-1, anthropic/claude-opus-4-8"
ANTH_STRONG="anthropic/claude-sonnet-5"
ANTH_CHAIN_FRONTIER='["google-antigravity/claude-opus-4-6","openrouter/deepseek/deepseek-v4-pro"]'
ANTH_CHAIN_STRONG='["google-antigravity/claude-sonnet-4-6","openrouter/deepseek/deepseek-v4-pro"]'
OAI_FRONTIER="openai-codex/gpt-6-astra, openai-codex/gpt-5.6-sol"
OAI_STRONG="openai-codex/gpt-5.6-terra"
OAI_CHAIN_FRONTIER='["openai-codex/gpt-5.6-sol","openai-codex/gpt-5.6-terra","openrouter/deepseek/deepseek-v4-pro"]'
OAI_CHAIN_STRONG='["openai-codex/gpt-5.6-luna","google-antigravity/gemini-3.1-pro","openrouter/deepseek/deepseek-v4-pro"]'

case "$PROFILE" in
  claude)
    SIDE_A_FRONTIER="$ANTH_FRONTIER"
    SIDE_A_STRONG="$ANTH_STRONG"
    SIDE_A_CHAIN_FRONTIER="$ANTH_CHAIN_FRONTIER"
    SIDE_A_CHAIN_STRONG="$ANTH_CHAIN_STRONG"
    SIDE_B_FRONTIER="$OAI_FRONTIER"
    SIDE_B_STRONG="$OAI_STRONG"
    SIDE_B_CHAIN_FRONTIER="$OAI_CHAIN_FRONTIER"
    SIDE_B_CHAIN_STRONG="$OAI_CHAIN_STRONG"
    ;;
  codex)
    SIDE_A_FRONTIER="$OAI_FRONTIER"
    SIDE_A_STRONG="$OAI_STRONG"
    SIDE_A_CHAIN_FRONTIER="$OAI_CHAIN_FRONTIER"
    SIDE_A_CHAIN_STRONG="$OAI_CHAIN_STRONG"
    SIDE_B_FRONTIER="$ANTH_FRONTIER"
    SIDE_B_STRONG="$ANTH_STRONG"
    SIDE_B_CHAIN_FRONTIER="$ANTH_CHAIN_FRONTIER"
    SIDE_B_CHAIN_STRONG="$ANTH_CHAIN_STRONG"
    ;;
esac

WORKER="openai-codex/gpt-5.6-terra, anthropic/claude-sonnet-5"
TESTER="anthropic/claude-sonnet-5, openai-codex/gpt-5.6-luna"
SCOUT="google-antigravity/gemini-3.5-flash, openai-codex/gpt-5.6-luna"
MICRO="google-antigravity/gemini-3.5-flash-lite, google-antigravity/gemini-3.1-flash-lite"
CHAIN_TASK='["openai-codex/gpt-5.6-luna","openrouter/deepseek/deepseek-v4-pro","openrouter/deepseek/deepseek-v4-flash"]'
CHAIN_SMOL='["google-antigravity/gemini-3.1-flash-lite","openai-codex/gpt-5.6-luna","openrouter/deepseek/deepseek-v4-flash"]'
CHAIN_TINY='["google-antigravity/gemini-3.1-flash-lite","openrouter/deepseek/deepseek-v4-flash"]'
CHAIN_COMMIT='["google-antigravity/gemini-3.1-flash-lite","openrouter/deepseek/deepseek-v4-flash"]'
CHAIN_VISION='["anthropic/claude-sonnet-5","openrouter/deepseek/deepseek-v4-pro"]'

# Build each config value once. Keep JSON compact: --print is a machine contract.
V_MODEL_ROLES='{"frontier_a":"'"$SIDE_A_FRONTIER"'","frontier_b":"'"$SIDE_B_FRONTIER"'","strong_a":"'"$SIDE_A_STRONG"'","strong_b":"'"$SIDE_B_STRONG"'","worker":"'"$WORKER"'","tester":"'"$TESTER"'","scout":"'"$SCOUT"'","micro":"'"$MICRO"'","default":"@strong_a:medium","plan":"@frontier_a:high","slow":"@frontier_b:xhigh","advisor":"@strong_b:high","task":"@worker:medium","smol":"@scout","tiny":"@micro","commit":"@micro","designer":"@strong_a:medium","vision":"google-antigravity/gemini-3.1-pro, @strong_a"}'
V_MODEL_PROVIDER_ORDER='["anthropic","openai-codex","google-antigravity","openrouter"]'
V_DEFAULT_THINKING_LEVEL='auto'
V_CHAINS='{"default":'"$SIDE_A_CHAIN_STRONG"',"designer":'"$SIDE_A_CHAIN_STRONG"',"plan":'"$SIDE_A_CHAIN_FRONTIER"',"slow":'"$SIDE_B_CHAIN_FRONTIER"',"advisor":'"$SIDE_B_CHAIN_STRONG"',"task":'"$CHAIN_TASK"',"smol":'"$CHAIN_SMOL"',"tiny":'"$CHAIN_TINY"',"commit":'"$CHAIN_COMMIT"',"vision":'"$CHAIN_VISION"'}'
V_USAGE_AWARE_FALLBACK='true'
V_USAGE_RESERVE_PCT='10'
V_USAGE_RESERVE_POLICY='auto'
V_ADVISOR_ENABLED='true'
V_ADVISOR_SYNC_BACKLOG='3'
V_TASK_AGENT_MODEL_OVERRIDES='{"Tester":"@tester:medium"}'
V_TASK_SHOW_RESOLVED_MODEL_BADGE='true'
V_TASK_ENABLE_LSP='true'
V_TASK_EAGER='preferred'

apply_or_print() {
  for KEY in modelRoles modelProviderOrder defaultThinkingLevel retry.fallbackChains retry.usageAwareFallback retry.usageReservePct retry.usageReservePolicy advisor.enabled advisor.syncBacklog task.agentModelOverrides task.showResolvedModelBadge task.enableLsp task.eager; do
    case "$KEY" in
      modelRoles) VALUE="$V_MODEL_ROLES" ;;
      modelProviderOrder) VALUE="$V_MODEL_PROVIDER_ORDER" ;;
      defaultThinkingLevel) VALUE="$V_DEFAULT_THINKING_LEVEL" ;;
      retry.fallbackChains) VALUE="$V_CHAINS" ;;
      retry.usageAwareFallback) VALUE="$V_USAGE_AWARE_FALLBACK" ;;
      retry.usageReservePct) VALUE="$V_USAGE_RESERVE_PCT" ;;
      retry.usageReservePolicy) VALUE="$V_USAGE_RESERVE_POLICY" ;;
      advisor.enabled) VALUE="$V_ADVISOR_ENABLED" ;;
      advisor.syncBacklog) VALUE="$V_ADVISOR_SYNC_BACKLOG" ;;
      task.agentModelOverrides) VALUE="$V_TASK_AGENT_MODEL_OVERRIDES" ;;
      task.showResolvedModelBadge) VALUE="$V_TASK_SHOW_RESOLVED_MODEL_BADGE" ;;
      task.enableLsp) VALUE="$V_TASK_ENABLE_LSP" ;;
      task.eager) VALUE="$V_TASK_EAGER" ;;
    esac
    if [ "$PRINT" -eq 1 ]; then
      printf '%s\t%s\n' "$KEY" "$VALUE"
    else
      omp config set "$KEY" "$VALUE"
      say "    ok: $KEY"
    fi
  done
}

if [ "$PRINT" -eq 1 ]; then
  apply_or_print
  exit 0
fi

AGENT_DIR="$(omp config path 2>/dev/null)" || AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
[ -n "$AGENT_DIR" ] || fail "could not resolve the omp agent directory"

say "==> omp-orchestra installer"
say "    agent dir: $AGENT_DIR"
say "    profile:   $PROFILE"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKED_UP=0
if [ -f "$AGENT_DIR/config.yml" ]; then
  cp "$AGENT_DIR/config.yml" "$AGENT_DIR/config.yml.orchestra-bak.$STAMP"
  say "    backup:    config.yml.orchestra-bak.$STAMP"
  BACKED_UP=1
fi

apply_or_print

if [ -f "$AGENT_DIR/WATCHDOG.md" ]; then
  cp "$AGENT_DIR/WATCHDOG.md" "$AGENT_DIR/WATCHDOG.md.orchestra-bak.$STAMP"
  say "    backup:    WATCHDOG.md.orchestra-bak.$STAMP"
fi
cat > "$AGENT_DIR/WATCHDOG.md" <<'WATCHDOG'
# Watchdog notes

You are the quality gate over a cost-tiered pipeline: cheaper models implement, you validate. Assume competence, verify correctness.

Especially watch for:

- Logic errors, wrong or hallucinated APIs, off-by-one boundaries — correctness over style.
- Silent scope-shrink: the agent solving an easier problem than the user asked for.
- Stubs presented as done: `TODO`, mocked returns, empty catch blocks, fake fallbacks.
- Edits that break callers: renamed/removed exports without updating every callsite.
- Deleted or bypassed error handling; swallowed exceptions; suppressed warnings instead of fixes.
- Tests that assert plumbing or restate the implementation instead of defending behavior.
- Claims of verification without an actual run of the relevant test or command.

Interrupt (`concern`/`blocker`) only for material risk or wasted-work trajectories. Otherwise stay silent — silence is the correct expression of "no concerns".
WATCHDOG
say "    ok: WATCHDOG.md"

say ""
say "==> Done. New sessions pick this up automatically."
say ""
say "    Provider logins (roles degrade to the next chain entry if one is missing):"
say "      omp   ->  /login  ->  Anthropic (Claude), OpenAI Codex (ChatGPT plan),"
say "                            Google Antigravity (free tier), OpenRouter (API key)"
if [ "$BACKED_UP" = 1 ]; then
  say ""
  say "    Restore your previous config:"
  say "      cp \"$AGENT_DIR/config.yml.orchestra-bak.$STAMP\" \"$AGENT_DIR/config.yml\""
fi
