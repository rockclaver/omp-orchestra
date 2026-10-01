# omp-orchestra

**Tier-based model routing for [Oh My Pi](https://github.com/oh-my-pi) (`omp`).** Concrete model ids live in one small tier table, so swapping the smartest model is a one-line change. A shared Anthropic + OpenAI worker pool handles implementation volume; frontier models handle decisions; `verify.sh` structurally enforces cross-vendor validation.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/rockclaver/omp-orchestra/main/install.sh | sh
curl -fsSL https://raw.githubusercontent.com/rockclaver/omp-orchestra/main/install.sh | sh -s -- codex
OMP_ORCHESTRA_PROFILE=codex curl -fsSL https://raw.githubusercontent.com/rockclaver/omp-orchestra/main/install.sh | sh
```

Profiles are `claude` (default) and `codex`. The installer only uses `omp config set`, backs up `config.yml`, and writes `WATCHDOG.md` plus the worker-pool extension `extensions/omp-orchestra-worker-pool.ts`.

## Why the orchestrator is NOT the frontier model

On subscription plans, cost is the quota window, not a per-token price. The orchestrator resends full history every turn, making it the highest-volume session. Frontier capacity belongs in `plan` (architect) and `slow` (reviewer): short, high-leverage jobs. The advisor uses a strong mid-tier model. Promote a model into a tier only for better quality in the same quota class, never because it is novel.

## Routing table

| Tier | `claude` profile value | `codex` profile value | Job |
|---|---|---|---|
| `frontier_a` | `anthropic/claude-fable-5-1, anthropic/claude-opus-5-5` | `openai-codex/gpt-6-astra, openai-codex/gpt-6.1-sol` | Primary frontier side |
| `frontier_b` | `openai-codex/gpt-6-astra, openai-codex/gpt-6.1-sol` | `anthropic/claude-fable-5-1, anthropic/claude-opus-5-5` | Independent frontier side |
| `strong_a` | `anthropic/claude-sonnet-5-5` | `openai-codex/gpt-6.1-sol` | Primary strong side |
| `strong_b` | `openai-codex/gpt-6.1-sol` | `anthropic/claude-sonnet-5-5` | Independent strong side |
| `worker_a` | `anthropic/claude-sonnet-5-5, openai-codex/gpt-6.1-sol, openai-codex/gpt-6-luna, openrouter/deepseek/deepseek-v4-pro, openrouter/deepseek/deepseek-v4-flash` | same | Implementer pool, Anthropic lane (`task` agent) |
| `worker_b` | `openai-codex/gpt-6.1-sol, anthropic/claude-sonnet-5-5, openai-codex/gpt-6-luna, openrouter/deepseek/deepseek-v4-pro, openrouter/deepseek/deepseek-v4-flash` | same | Implementer pool, OpenAI lane (`task` agent) |
| `executor_a` | `anthropic/claude-haiku-4-5, openai-codex/gpt-6-luna, google-antigravity/gemini-3.5-flash, openrouter/deepseek/deepseek-v4-flash` | same | Executor pool, Anthropic lane (`sonic` agent) |
| `executor_b` | `openai-codex/gpt-6-luna, anthropic/claude-haiku-4-5, google-antigravity/gemini-3.5-flash, openrouter/deepseek/deepseek-v4-flash` | same | Executor pool, OpenAI lane (`sonic` agent) |
| `tester` | `anthropic/claude-sonnet-5-5, openai-codex/gpt-6-luna` | `anthropic/claude-sonnet-5-5, openai-codex/gpt-6-luna` | Tester agent |
| `scout` | `google-antigravity/gemini-3.5-flash, openai-codex/gpt-6-luna` | `google-antigravity/gemini-3.5-flash, openai-codex/gpt-6-luna` | High-volume exploration |
| `micro` | `google-antigravity/gemini-3.5-flash-lite, google-antigravity/gemini-3.1-flash-lite` | `google-antigravity/gemini-3.5-flash-lite, google-antigravity/gemini-3.1-flash-lite` | Background work |

| Role | Mapping | Job |
|---|---|---|
| `default` | `@strong_a:medium` | Orchestrator |
| `plan` | `@frontier_a:high` | Architect |
| `slow` | `@frontier_b:xhigh` | Reviewer |
| `advisor` | `@strong_b:high` | Per-turn second opinion |
| `task` | `@worker_a:medium` | Implementer (pooled, see below) |
| `smol` | `@scout` | Scout |
| `tiny` | `@micro` | Titles and classification |
| `commit` | `@micro` | Commit messages |
| `designer` | `@strong_a:medium` | Design work |
| `vision` | `google-antigravity/gemini-3.1-pro, @strong_a` | Vision work |

Agent overrides (`task.agentModelOverrides`): `Tester` → `@tester:medium`, `sonic` → `@executor_a:medium`.

## Worker pool

omp resolves a role to its first available model, so one role alone can't spread workers across vendors. The installed extension `omp-orchestra-worker-pool.ts` hooks `before_subagent_spawn` and alternates each pooled spawn between lane `_a` (Anthropic-first) and lane `_b` (OpenAI-first):

- `task` agents alternate `@worker_a` / `@worker_b`: a batch of four runs two `claude-sonnet-5-5` and two `gpt-6.1-sol` workers at once.
- `sonic` executors alternate `@executor_a` / `@executor_b`: `claude-haiku-4-5` and `gpt-6-luna`.
- The rotation is per agent type and process-wide, and it keeps the role's thinking suffix (`:medium`). Spawns with an explicit model (for example `^`-tagged `m1` agents) carry no role and are left alone.
- Without the extension, every pooled spawn takes lane `_a`.

## Adopting a new model

Edit one tier line in `install.sh`, or make a live change with `omp config set modelRoles.<tier> ...`, then run `./verify.sh`. `~provider/x-latest` aliases exist only on OpenRouter; subscription providers require concrete ids.

## Fallback chains

Chains are per-role and contain concrete ids: omp does not accept `@aliases` in chains, and an unknown entry silently breaks the role. They preserve vendors where needed, so a reviewer remains on the other vendor after a 429. Cheap `tiny`, `commit`, and `smol` roles never fall to frontier or strong models. `retry.usageAwareFallback` pre-empts the quota wall with a 10% reserve.

Subagents are different: when an agent's alias expands to several models, omp falls back only through the rest of that list and ignores `retry.fallbackChains.<role>`. Each worker and executor lane therefore carries its full fallback sequence inline, crossing to the other vendor and then DeepSeek, and has no chain entry.

| Role | Fallback chain |
|---|---|
| `default`, `designer` | `claude`: `google-antigravity/claude-sonnet-4-6` → `openrouter/deepseek/deepseek-v4-pro`; `codex`: `openai-codex/gpt-6-luna` → `google-antigravity/gemini-3.1-pro` → `openrouter/deepseek/deepseek-v4-pro` |
| `plan` | `claude`: `google-antigravity/claude-opus-4-6` → `openrouter/deepseek/deepseek-v4-pro`; `codex`: `openai-codex/gpt-6.1-sol` → `openai-codex/gpt-6-sol` → `openrouter/deepseek/deepseek-v4-pro` |
| `slow` | `claude`: `openai-codex/gpt-6.1-sol` → `openai-codex/gpt-6-sol` → `openrouter/deepseek/deepseek-v4-pro`; `codex`: `google-antigravity/claude-opus-4-6` → `openrouter/deepseek/deepseek-v4-pro` |
| `advisor` | `claude`: `openai-codex/gpt-6-luna` → `google-antigravity/gemini-3.1-pro` → `openrouter/deepseek/deepseek-v4-pro`; `codex`: `google-antigravity/claude-sonnet-4-6` → `openrouter/deepseek/deepseek-v4-pro` |
| `smol` | `google-antigravity/gemini-3.1-flash-lite` → `openai-codex/gpt-6-luna` → `openrouter/deepseek/deepseek-v4-flash` |
| `tiny`, `commit` | `google-antigravity/gemini-3.1-flash-lite` → `openrouter/deepseek/deepseek-v4-flash` |
| `vision` | `anthropic/claude-sonnet-5-5` → `openrouter/deepseek/deepseek-v4-pro` |

## Invariants and verification

- `vendor(default) == vendor(plan) != vendor(slow)`.
- `vendor(default) != vendor(advisor)`.
- `vendor(worker_a) != vendor(worker_b)` and `vendor(executor_a) != vendor(executor_b)`, so the pool always spans both vendors. Lanes fall back to the other vendor, so during failover both lanes can land on one vendor.
- The `sonic` override is `@executor_a:medium` (the role the pool keys on), and the worker-pool extension is installed.
- No chain entry of `tiny`/`commit`/`smol` may be an `anthropic/` or `openai-codex/` frontier or strong model; their entries are limited to `google-antigravity/*`, `openai-codex/gpt-6-luna`, and `openrouter/*`.

```sh
./verify.sh
./verify.sh --static
./verify.sh --no-drift
./verify.sh --profile codex
./verify.sh task
```

The drift check compares `install.sh --print` with live config and `install.sh --print-extension` with the installed extension, so the repository cannot silently diverge from the install. The live probe runs each model with `retry.modelFallback` off, so a dead primary cannot answer from its chain and pass. Role names filter the probe.

## Requirements

- [omp](https://github.com/oh-my-pi) installed.
- Credentials for Anthropic, OpenAI Codex, Google Antigravity, and optionally OpenRouter.
- `slow` and `advisor` hard-fail without side-B credentials for the selected profile. `tiny`, `commit`, and `scout` need Google Antigravity or fall to their chains.

## Customization

- Swap a tier with one line in `install.sh`, then run `./verify.sh`.
- Disable the advisor: `omp config set advisor.enabled false`.
- Add `.omp/config.yml` for project-specific overrides.

## Uninstall / restore

Restore the backup created next to the live config:

```sh
AGENT_DIR="$(omp config path)"
cp "$AGENT_DIR/config.yml.orchestra-bak.<stamp>" "$AGENT_DIR/config.yml"
rm "$AGENT_DIR/extensions/omp-orchestra-worker-pool.ts"
```

## License

[MIT](LICENSE)
