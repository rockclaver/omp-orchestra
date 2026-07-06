#!/bin/sh
# omp-orchestra — cost-tiered model orchestration for Oh My Pi (omp)
#
#   curl -fsSL https://raw.githubusercontent.com/rockclaver/omp-orchestra/main/install.sh | sh
#
# Applies every setting through `omp config set` (schema-validated), so your
# unrelated settings — theme, keybindings, approvals — are left untouched.
# Your existing config.yml is backed up first. No secrets are read or written.
set -eu

say()  { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v omp >/dev/null 2>&1 || fail "omp is not installed (or not on PATH).
Install Oh My Pi first, then re-run this script."

AGENT_DIR="$(omp config path 2>/dev/null)" || AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
[ -n "$AGENT_DIR" ] || fail "could not resolve the omp agent directory"

say "==> omp-orchestra installer"
say "    agent dir: $AGENT_DIR"

# ── Backup ────────────────────────────────────────────────────────────────────
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKED_UP=0
if [ -f "$AGENT_DIR/config.yml" ]; then
  cp "$AGENT_DIR/config.yml" "$AGENT_DIR/config.yml.orchestra-bak.$STAMP"
  say "    backup:    config.yml.orchestra-bak.$STAMP"
  BACKED_UP=1
fi

# ── Model roles ───────────────────────────────────────────────────────────────
# Comma lists are availability fallback chains: first model whose provider has
# credentials wins. Missing providers degrade gracefully to the next entry.
omp config set modelRoles '{
  "default":  "anthropic/claude-opus-4-8, openai-codex/gpt-5.5",
  "slow":     "openai-codex/gpt-5.5:xhigh",
  "plan":     "anthropic/claude-opus-4-8:high, openai-codex/gpt-5.5:high",
  "task":     "openai-codex/gpt-5.3-codex:medium, anthropic/claude-sonnet-5:medium",
  "smol":     "google-antigravity/gemini-3.5-flash, openai-codex/gpt-5.4-mini, anthropic/claude-haiku-4-5",
  "tiny":     "google-antigravity/gemini-3.1-flash-lite, google-antigravity/gemini-2.5-flash-lite",
  "commit":   "google-antigravity/gemini-3.5-flash",
  "designer": "anthropic/claude-sonnet-5:medium, google-antigravity/gemini-3.1-pro",
  "vision":   "google-antigravity/gemini-3.1-pro, anthropic/claude-sonnet-5",
  "advisor":  "openai-codex/gpt-5.5:high"
}'
say "    ok: modelRoles"

# Prefer subscription/free providers when a canonical model id is ambiguous;
# openrouter (per-token billed) resolves last.
omp config set modelProviderOrder '["anthropic","openai-codex","google-antigravity","openrouter"]'
say "    ok: modelProviderOrder"

# Free tiny model classifies per-prompt thinking depth; trivial turns stop
# burning frontier high-thinking tokens. Revert: omp config set defaultThinkingLevel high
omp config set defaultThinkingLevel auto
say "    ok: defaultThinkingLevel=auto"

# ── Runtime quota resilience ──────────────────────────────────────────────────
# When a role's model 429s, retry walks this chain and reverts on cooldown
# expiry. The "default" chain applies to any role without its own chain.
omp config set retry.fallbackChains '{
  "default": ["openai-codex/gpt-5.5","anthropic/claude-sonnet-5","openai-codex/gpt-5.4","google-antigravity/claude-sonnet-4-6","openrouter/deepseek/deepseek-v4-pro"],
  "task":    ["openai-codex/gpt-5.3-codex-spark","anthropic/claude-sonnet-5","google-antigravity/claude-sonnet-4-6","openrouter/deepseek/deepseek-v4-pro","openrouter/deepseek/deepseek-v4-flash:free"],
  "slow":    ["openai-codex/gpt-5.4","anthropic/claude-opus-4-8","google-antigravity/gemini-3.1-pro"],
  "advisor": ["google-antigravity/gemini-3.1-pro","openai-codex/gpt-5.4"],
  "smol":    ["openai-codex/gpt-5.4-mini","google-antigravity/gemini-3.1-flash-lite","openrouter/deepseek/deepseek-v4-flash","openrouter/deepseek/deepseek-v4-flash:free"]
}'
say "    ok: retry.fallbackChains"

# ── Advisor: frontier second-opinion on every completed turn ─────────────────
omp config set advisor.enabled true
omp config set advisor.subagents false
omp config set advisor.syncBacklog 3
say "    ok: advisor (gpt-5.5 reviews every turn)"

# ── Subagent behavior ────────────────────────────────────────────────────────
# Tester on a different vendor than the implementer; show resolved models;
# give workers LSP diagnostics; bias the orchestrator toward delegation.
omp config set task.agentModelOverrides '{"Tester":"anthropic/claude-sonnet-5:medium"}'
omp config set task.showResolvedModelBadge true
omp config set task.enableLsp true
omp config set task.eager preferred
say "    ok: task.* (delegation, Tester cross-vendor, LSP)"

# ── Advisor watchdog guidance ────────────────────────────────────────────────
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
