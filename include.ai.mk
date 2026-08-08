##
## AI tools
PYTHON ?= 3.12
FLAGS ?=
SHELL := /usr/bin/env bash
WS_DIR ?= $(HOME)/ws
BIN_DIR ?= $(WS_DIR)/git/src/bin
LIB_DIR ?= $(WS_DIR)/git/src/lib
TNE_DB_DIR  ?= $(WS_DIR)/db
TNE_LOG_DIR ?= $(WS_DIR)/logs
TNE_DATA    ?= $(WS_DIR)/data
export WS_DIR BIN_DIR TNE_DB_DIR TNE_LOG_DIR

AI_USER ?= $(USER)
AI_ORG ?= tne.ai

# variables must be definte before their use so put high
MLFLOW_PORT    ?= 5001
LITELLM_PORT   ?= 4000
TEMPORAL_PORT  ?= 7233
TEMPORAL_UI_PORT ?= 8233
KTAP_PORT      ?= 8630
CCR_PORT       ?= 3456
LLS_PORT       ?= 8081
REDIS_PORT     ?= 6379
POSTGRES_PORT  ?= 5432
CLAUDE_MEM_PORT ?= 37777
# OLLAMA_SERVER_PORT ?= 11434
# OPEN_WEBUI_PORT    ?= 8080
# ALLOY_PORT         ?= 12345

# Script to push session logs to MLflow — override per-repo if needed
MLFLOW_LOG_SCRIPT ?= $(WS_DIR)/git/src/sys/tne-plugins/plugins/tne/skills/cai-opt5-install-ai-stack/scripts/push-logs-to-mlflow.py
# Default: ~/.config/litellm/config.yaml (XDG standard).
# install-ai.sh copies tne-plugins/litellm_config.yaml here on setup.
LITELLM_CFG  ?= $(HOME)/.config/litellm/config.yaml
MLFLOW_DIR   ?= $(TNE_DB_DIR)
KTAP_DIR     ?= $(WS_DIR)/git/src/demo/demo-do178c
TEMPORAL_DB  ?= $(TNE_DB_DIR)/temporal/temporal.db
export TEMPORAL_DB
LITELLM_DB   ?= litellm
LITELLM_DB_URL ?= postgresql://$(USER)@localhost/$(LITELLM_DB)
# Monthly budget cap in USD — LiteLLM hard-stops when exceeded
LITELLM_BUDGET ?= 200
# Stamp file: prisma generate only runs when absent (r-cdo98 Principle II)
PRISMA_STAMP ?= $(HOME)/.local/share/make-ai/.stamp-prisma-generated

## debug: environment troubleshooting
.PHONY: debug
debug:
	echo "OSTYPE=$(shell uname -msr)"
	echo "LITELLM_PORT=$(LITELLM_PORT) MLFLOW_PORT=$(MLFLOW_PORT)"

# ## rclone: rclone sync the Linux clone of Google Drive back up
# .PHONY: rclone
# rclone:
# 	mkdir -p "$(OPEN_WEBUI_DATA_DIR)"
# 	rclone bisync --resync --interactive "$(OPEN_WEBUI_DATA_DIR)" "app:open-webui-data/$(AI_USER)"

# Use the simplest pattern that works for the sidecar type (r-cto-dev108):
#   start_server        — native binaries (Go, C, Node, Java): nohup + </dev/null
#   start_server_double_fork — Python ASGI/WSGI (Uvicorn/Gunicorn): required, not optional
#   start_server_brew   — brew-managed services: let brew own the lifecycle
#   start_server_self   — self-managing daemons: binary handles its own daemonization
SETSID ?= $(or $(shell which setsid 2>/dev/null),/opt/homebrew/opt/util-linux/bin/setsid)
start_server = if ! $(call port_ready,$(1)); then \
    nohup bash -c "$(2) $(3) $(4) $(5) $(6) $(7) $(8) $(9) $(10) \
                   </dev/null >>$(TNE_LOG_DIR)/sidecar-$(1).log 2>&1 &" &>/dev/null; fi
# Uvicorn/Gunicorn detect terminal group membership — double-fork required; nohup is not enough.
# If something holds the LISTEN socket but is not yet accepting connections (zombie), warn and
# skip — do not auto-kill. Run `make $(1).stop` to clear the port first.
start_server_double_fork = if $(call port_ready,$(1)); then \
    true; \
  elif lsof -ti :$(1) -sTCP:LISTEN &>/dev/null 2>&1; then \
    echo "⚠️  port $(1) is held by a zombie process — run: make $(1).stop"; \
  else \
    ($(SETSID) bash -c "$(2) $(3) $(4) $(5) $(6) $(7) $(8) $(9) $(10) \
                        </dev/null >>$(TNE_LOG_DIR)/sidecar-$(1).log 2>&1 &"); fi
start_server_brew = brew services start $(2) 2>/dev/null || true
start_server_self = $(2) $(3) $(4) $(5) $(6) $(7) $(8) $(9) $(10) || true

# usage: $(call open_server,port of service, url_suffix)
open_server = if $(call port_ready,$(1)); then open -a "Google Chrome" "http://localhost:$(1)$(2)"; fi &

# usage: $(call check_port,port) — poll until ready (HTTP /health/readiness first, TCP fallback)
# /health/readiness is unauthenticated on litellm/mlflow. /health requires the master key
# and returns 401 even when healthy — do not use it for readiness checks.
# gRPC services (temporal) and raw TCP (redis) use nc fallback.
# 90s timeout: litellm cold-start (prisma init + model load) routinely takes 30-45s;
# 60s was too tight and caused false "not ready" reports on first launch.
check_port = timeout=90; until curl -sf http://localhost:$(1)/health/readiness >/dev/null 2>&1 \
               || nc -z localhost $(1) 2>/dev/null; do \
    sleep 2; timeout=$$((timeout-2)); \
    [ $$timeout -eq 44 ] && echo "  still waiting for port $(1)..."; \
    [ $$timeout -gt 0 ] || { echo "⚠️  port $(1) did not become ready after 90s"; exit 0; }; \
  done && echo "✓ port $(1) ready"

# usage: $(call port_ready,port) — true if something is listening on port
port_ready = nc -z localhost $(1) 2>/dev/null

## %.ps: process status for any service (e.g. make litellm.ps)
%.ps:
	if ! pgrep -fl $*; then echo "$* not running"; fi

## [service].stop: graceful stop — SIGTERM first, SIGKILL fallback after 5s
# Belts-and-suspenders: name-based stop also kills the associated port so
# double-forked processes (PPID=1) that survive pkill are caught by lsof.
# SERVICE_PORTS maps service names → ports for the port-kill fallback.
SERVICE_PORTS := litellm:$(LITELLM_PORT) mlflow:$(MLFLOW_PORT) temporal:$(TEMPORAL_PORT) \
                 redis:$(REDIS_PORT) postgres:$(POSTGRES_PORT) ccr:$(CCR_PORT) ktap:$(KTAP_PORT)
%.stop:
	@declare -A _ports=( $(foreach p,$(SERVICE_PORTS),[$(word 1,$(subst :, ,$(p)))]=$(word 2,$(subst :, ,$(p)))) ); \
	for signal in "" "-9"; do \
		if echo "$*" | grep -qE '^[0-9]+$$'; then \
			lsof -ti :$* -sTCP:LISTEN 2>/dev/null | xargs -r kill $$signal 2>/dev/null || true; \
		else \
			pgrep -fl "$*" | grep -vE '^[0-9]+ make|pgrep' | awk '{print $$1}' | xargs -r kill $$signal 2>/dev/null || true; \
			_port="$${_ports[$*]:-}"; \
			[ -n "$$_port" ] && lsof -ti :$$_port -sTCP:LISTEN 2>/dev/null | xargs -r kill $$signal 2>/dev/null || true; \
		fi; \
		sleep 3; \
	done


# note never use brew for status very slow
	# brew services start postgresql@17 2>/dev/null || brew services start postgresql 2>/dev/null || true
## postgres: start PostgreSQL via brew services (needed for LiteLLM spend tracking)
.PHONY: postgres
postgres:
	POSTGRES_PORT=$(POSTGRES_PORT) LITELLM_DB=$(LITELLM_DB) $(BIN_DIR)/start-postgres.sh

## redis: start Redis via brew services (needed for LiteLLM response caching)
.PHONY: redis
redis:
	REDIS_PORT=$(REDIS_PORT) $(BIN_DIR)/start-redis.sh

## mlflow: start MLflow tracking server at http://localhost:$(MLFLOW_PORT)
## mlflow has no Homebrew formula — install chain is: uv tool install → uvx (ephemeral).
## uv tool install puts the binary in ~/.local/bin which may not be in Make's PATH,
## so we resolve at runtime with `command -v mlflow || echo uvx mlflow`.
## mlflow-start: fire mlflow in background without waiting — overlaps with postgres/redis startup
.PHONY: mlflow-start
mlflow-start:
	MLFLOW_PORT=$(MLFLOW_PORT) MLFLOW_DIR=$(MLFLOW_DIR) TNE_LOG_DIR=$(TNE_LOG_DIR) $(BIN_DIR)/start-mlflow.sh

## mlflow: wait for mlflow to be ready (call mlflow-start first to overlap with postgres/redis)
.PHONY: mlflow
mlflow: mlflow-start
	$(call check_port,$(MLFLOW_PORT))

## Pin litellm to a known-good version. Unpin by setting LITELLM_VERSION=latest.
## WHY: litellm has shipped broken UI builds (HTML/JS chunk hash mismatch in 1.83.x)
## that cause a blank "gigantic zero" dashboard. Pinning ensures a tested coherent build.
## 1.84.0 was the first fixed version; 1.86.2 tested and confirmed good (2026-06-01).
LITELLM_VERSION ?= 1.86.2

## litellm: start LiteLLM proxy at http://localhost:$(LITELLM_PORT)
## no_auth mode: LiteLLM accepts all requests without key validation (localhost dev only).
## Claude Code uses OAuth keychain (no ANTHROPIC_API_KEY) — claudeai-mcp stays enabled.
## Claude Max plan: OAuth Bearer forwarded to Anthropic via forward_client_headers_to_llm_api.
## Alt providers: LiteLLM uses litellm_params.api_key; client Bearer NOT forwarded to backends.
## litellm binary also lives in ~/.local/bin (uv tool install) — same PATH fix as mlflow.
## litellm-install: install or upgrade litellm to the pinned LITELLM_VERSION
.PHONY: litellm-install
litellm-install:
	LITELLM_VERSION=$(LITELLM_VERSION) $(BIN_DIR)/litellm-install.sh

## litellm-fix-ui: patch login/index.html hash mismatch (1.85.x packaging bug)
## login/index.html ships with stale chunk hashes; overwrite with login.html which is correct.
.PHONY: litellm-fix-ui
litellm-fix-ui:
	LITELLM_VERSION=$(LITELLM_VERSION) $(BIN_DIR)/litellm-install.sh --fix-ui


## litellm-check-version: verify installed litellm matches LITELLM_VERSION; fix if not
## Called automatically by make litellm before startup.
.PHONY: litellm-check-version
litellm-check-version:
	LITELLM_VERSION=$(LITELLM_VERSION) $(BIN_DIR)/litellm-install.sh --check

## litellm.stop / 4000.stop: kill ALL litellm processes (port kill + pkill sweep for zombies)
## WHY bin/litellm not litellm: postgres names its worker processes after the database.
## Since the litellm database is named "litellm", pkill -f "litellm" matches and tries
## to kill postgres workers — those kills fail (permission or zombie), pkill exits non-zero,
## the || true masks it, and the actual Python process may survive if the port kill also
## missed. Matching "bin/litellm" targets only the Python CLI binary, not postgres.
.PHONY: litellm.stop 4000.stop
litellm.stop 4000.stop:
	LITELLM_PORT=$(LITELLM_PORT) $(BIN_DIR)/litellm-stop.sh

## litellm: start LiteLLM proxy with automatic Prisma client regeneration
##
## WHY venv Python for prisma generate (not system prisma):
##   LiteLLM uses Prisma Client Python (prisma==0.15.0) installed inside its
##   own pipx venv. `prisma generate` writes the query-engine bindings into
##   whichever Python environment owns the `prisma` binary. If you run the
##   system/uv-tool prisma binary it writes to *that* env, not to the litellm
##   venv — litellm never sees the updated client and crashes with
##   FieldNotFoundError on every `pipx upgrade litellm` that adds DB columns.
##   Solution: always call $$_venv/bin/python -m prisma generate so the
##   generated client lands in the litellm venv. Do NOT install prisma as a
##   standalone uv tool or pipx app — those create a separate env that
##   shadows the litellm venv's client and causes the same mismatch.
##
## Prisma stamp ($(PRISMA_STAMP)) stores the md5 hash of schema.prisma.
## On every run: hash the current schema → compare to stamp → if different
## (or stamp absent), regenerate the Prisma client AND push schema to DB,
## then update the stamp. Covers both client codegen and DB migrations in one step.
## This means `pipx upgrade litellm` automatically triggers regeneration
## on the next `make litellm` — no manual intervention needed.
## To force regeneration: rm $(PRISMA_STAMP)
.PHONY: litellm
litellm: litellm-check-version
	LITELLM_PORT=$(LITELLM_PORT) LITELLM_CFG=$(LITELLM_CFG) MLFLOW_PORT=$(MLFLOW_PORT) PRISMA_STAMP=$(PRISMA_STAMP) LITELLM_DB_URL=$(LITELLM_DB_URL) $(BIN_DIR)/litellm-start.sh
# ── Harness + model variables ─────────────────────────────────────────────────
# HARNESS: the AI coding assistant CLI. Swap without changing targets.
#   make ai                        # claude (default)
#   make ai HARNESS=aider          # aider
#   make ai HARNESS=codex          # codex CLI (plan provider via CLIProxyAPI)
# MODEL: any model_name from $(LITELLM_CFG). Run 'make ai-models' to list all.
#   make ai-run MODEL=kimi-k2.6         # Kimi K2 via Alibaba MaaS Team Edition (PLAN)
#   make ai-run MODEL=gemini-2.5-flash  # Gemini Flash (PAYG)
#   make ai-run MODEL=lls/qwen/qwen3.6-27b  # local GPU via llama-server
#
# WHY --model accepts non-claude names:
#   Claude Code normally validates --model against Anthropic's allowlist.
#   Two things disable that check here:
#     1. ANTHROPIC_BASE_URL points to LiteLLM (localhost:4000), not api.anthropic.com.
#        When a custom base URL is set, Claude Code skips the model name allowlist —
#        it forwards whatever string you give to the endpoint as-is.
#     2. LiteLLM maps the model_name you pass to the real provider and model behind it.
#        "kimi-k2.6" → Alibaba MaaS token-plan endpoint (ALIBABA_PLAN_KEY)
#        "lls/google/gemma-4-e2b" → llama-server (localhost:8081) → local GGUF
#   So any model_name registered in config.yaml (~/.config/litellm/config.yaml) works.
#   Run 'make ai-models' to list all available names.
#
# HARNESS_ARGS: extra flags forwarded to the harness binary.
#   make ai HARNESS_ARGS="--continue"
HARNESS            ?= claude
HARNESS_ARGS       ?=
MODEL              ?=

# ── Run-only targets (servers already up) ─────────────────────────────────────
# ONE-MECHANISM RULE: ai-run / ai-p are the sole model selectors.
# Set MODEL= here; engine batch jobs inherit ANTHROPIC_BASE_URL via os.environ.
# All providers route through LiteLLM at :$(LITELLM_PORT) — no per-tool config needed.
# Auth must already be set up (make ai-auth) — subscription bridges need valid OAuth tokens.
# OTEL: CLAUDE_CODE_ENABLE_TELEMETRY=1 sends traces to MLflow experiment tne-training (id=2).
# tne-training = conversation traces (prompts, tool calls) — fine-tuning corpus.
# tne-costs    = LiteLLM per-call metrics (model, tokens, spend) — cost/billing analysis.
## ai-run: launch interactive AI harness with LiteLLM routing
##
## Billing legend:
##   [PLAN] flat-rate subscription — no per-token cost once subscribed
##   [PAYG] pay-as-you-go per token — watch spend; no flat-rate plan available
##   [FREE] local GPU — zero cloud cost
##
## Provider billing model:
##   Anthropic : PLAN  — Max plan OAuth token forwarded by LiteLLM; no api_key = no PAYG billing
##   Kimi      : PLAN  — Alibaba MaaS Team Edition (ALIBABA_PLAN_KEY); ccproxy deprecated
##   Gemini    : PLAN  — Google One AI Premium OAuth via cliproxyapi bridge (:8317)
##   Z.AI/GLM  : PLAN  — same API key routes to coding plan quota via api.z.ai/api/anthropic
##   MiniMax   : PLAN  — Token Plan ~$10/mo; MINIMAX_PLAN_KEY routes to plan quota
##   Qwen      : PLAN  — Alibaba Plan key (ALIBABA_PLAN_KEY) via dashscope-intl endpoint
##   DeepSeek  : PAYG  — no flat-rate plan exists; cheap ($0.14/1M tokens for flash)
##   OpenRouter: PAYG  — markup on underlying models; use for models with no direct plan
##
##   make ai-run                               # claude via Max plan (default)   [PLAN]
##   make ai-run MODEL=kimi-k2.6              # Kimi K2.6 Alibaba MaaS Team Edition    [PLAN]
##   make ai-run MODEL=glm-5.1               # GLM-5.1 Z.AI coding plan         [PLAN]
##   make ai-run MODEL=minimax-m2.7          # MiniMax M2.7 Token Plan          [PLAN]
##   make ai-run MODEL=gpt-5.5               # ChatGPT/Codex plan (auth: make ai-auth PROVIDER=codex) [PLAN]
##   make ai-run MODEL=gpt-5.4-mini          # ChatGPT/Codex plan — mini (auth: make ai-auth PROVIDER=codex) [PLAN]
##   make ai-run MODEL=deepseek-v4-flash     # DeepSeek V4 Flash                [PAYG]
##   make ai-run MODEL=deepseek-v4-pro       # DeepSeek V4 Pro                  [PAYG]
##   make ai-run MODEL=or-nemotron-nano-30b         # Nemotron 30B via OpenRouter       [FREE]
##   make ai-run MODEL=or-nemotron-nano-30b-reasoning # Nemotron 30B reasoning          [FREE]
##   make ai-run MODEL=or-nemotron-super-120b       # Nemotron 120B 1M ctx             [FREE]
##   make ai-run MODEL=or-qwen3-coder               # Qwen3 Coder 1M ctx               [FREE]
##   make ai-run MODEL=or-qwen3-coder-30b           # Qwen3 Coder 30B                  [PAYG]
##   make ai-run MODEL=or-qwen3-235b                # Qwen3 235B (cheap)               [PAYG]
##   make ai-run MODEL=or-qwen3.6-35b               # Qwen3.6 35B MoE                  [PAYG]
##   make ai-run MODEL=lls/qwen/qwen3.6-27b  # local GPU (llama-server router)  [FREE]
##   make ai-run MODEL=lms/qwen/qwen3.6-27b  # local GPU (LM Studio — legacy)   [FREE]
##   make ai-run HARNESS=aider               # swap harness, same model
# Auth modes (MODEL gates everything):
#   MODEL=<empty>    → default Claude Max path. OAuth keychain auth, full Claude UX.
#                      LiteLLM forwards the Bearer to Anthropic (Max plan passthrough)
#                      via model_group_settings.forward_client_headers_to_llm_api.
#   MODEL=<provider> → alt-provider via LiteLLM. OAuth keychain still used (no
#                      ANTHROPIC_API_KEY set) so claudeai-mcp stays enabled for all
#                      models. LiteLLM no_auth=true accepts OAuth Bearer without key
#                      validation. Non-Anthropic backends use their own api_key from
#                      litellm_params (forward_client_headers_to_llm_api: false).
.PHONY: ai-run
ai-run:
	MODEL=$(MODEL) HARNESS=$(HARNESS) LITELLM_PORT=$(LITELLM_PORT) MLFLOW_PORT=$(MLFLOW_PORT) \
		$(BIN_DIR)/run-ai.sh $(HARNESS_ARGS)

## ai-p: run a single claude -p batch invocation via LiteLLM routing
## Same env as ai-run — engine invoker.py inherits ANTHROPIC_BASE_URL via os.environ.
##   make ai-p MODEL=kimi-k2.5 PROMPT='summarize foo.md'
##   make ai-p MODEL=gemini-2.5-flash AI_P_ARGS='--output-format json' PROMPT='classify: ...'
PROMPT ?=
AI_P_ARGS ?=
.PHONY: ai-p
ai-p:
	MODEL=$(MODEL) LITELLM_PORT=$(LITELLM_PORT) MLFLOW_PORT=$(MLFLOW_PORT) AI_P_ARGS="$(AI_P_ARGS)" \
		$(BIN_DIR)/run-ai.sh --batch "$(PROMPT)"

# ── Public entry points ───────────────────────────────────────────────────────

## ai: start full sidecar stack — cloud + local GPU + routing, all models available
## See all available models (cloud + local) after start: make ai-help
## Covers all stack variants: use MODEL= to select provider (codex, routellm, kimi, etc.)
## (ai-local, ai-cli, ai-auto merged here — one unified stack)
.PHONY: ai
ai: mlflow-start postgres redis mlflow litellm temporal set-gpu-max-memory lls-start ai-open
	@$(MAKE) --no-print-directory ai-help
	@$(MAKE) --no-print-directory ai-warn-bridges

## ai-help: show available models — live cloud cache + dynamic lls/ollama
## Cloud models come from ~/.cache/tne/model-ids.yaml (refresh: make ai-refresh-models)
.PHONY: ai-help
ai-help:
	@echo ""
	@echo "  Stack ready. Run your AI harness (MODEL= optional):"
	@echo ""
	@echo "  ── Cloud (API keys — refresh: make ai-refresh-models) ───────────────────"
	@echo "    make ai-run                               # claude Max plan (default)"
	@yq '.model_list[].model_name' "$(LITELLM_CFG)" 2>/dev/null \
		| grep -v '^lms/\|^lls/' | sort -u \
		| while IFS= read -r name; do \
			case "$$name" in \
			claude*)   tag="PLAN -- Anthropic Max" ;; \
			kimi*)     tag="PLAN -- Kimi MaaS Team Edition" ;; \
			glm*)      tag="PLAN -- Z.AI coding plan" ;; \
			qwen*)     tag="PLAN -- Alibaba plan (ALIBABA_PLAN_KEY)" ;; \
			minimax*)  tag="PLAN -- MiniMax token plan" ;; \
			gemini*)   tag="PLAN -- Google CLI sub" ;; \
			deepseek*) tag="PAYG -- no flat-rate plan" ;; \
			routellm*) tag="PLAN+PLAN -- auto-router" ;; \
			*)         tag="PAYG" ;; \
			esac; \
			printf "    make ai-run MODEL=%-36s# %s\n" "$$name" "$$tag"; \
		done \
		|| echo "    (litellm config not found — run make ai-install)"
	@echo ""
	@echo "  ── Local GPU (llama-server) ─────────────────────────────────────────────"
	@if nc -z localhost $(LLS_PORT) 2>/dev/null; then \
		curl -sf http://localhost:$(LLS_PORT)/v1/models 2>/dev/null \
		| yq -p json '.data[].id' 2>/dev/null \
		| while IFS= read -r id; do printf '    make ai-run MODEL=lls/%-28s # FREE\n' "$$id"; done \
		|| echo "    (lls running but models unavailable)"; \
	else \
		yq '.model_list[].model_name' "$(LITELLM_CFG)" 2>/dev/null | grep '^lls' | sort \
		| while IFS= read -r name; do printf '    make ai-run MODEL=%-36s # FREE (lls offline)\n' "$$name"; done; \
		[ -z "$$(yq '.model_list[].model_name' "$(LITELLM_CFG)" 2>/dev/null | grep -c '^lls')" ] \
		  && echo "    (lls not running — start with: make lls-start)"; \
	fi
	@echo ""
	@echo "  ── Ollama ───────────────────────────────────────────────────────────────"
	@if nc -z localhost 11434 2>/dev/null; then \
		curl -sf http://localhost:11434/api/tags 2>/dev/null \
		| yq -p json '.models[].name' 2>/dev/null \
		| while IFS= read -r name; do printf '    make ai-run MODEL=ollama/%-28s # FREE\n' "$$name"; done \
		|| echo "    (ollama running — run: ollama list)"; \
	else \
		echo "    (ollama not running — start with: ollama serve)"; \
	fi
	@echo ""
	@echo "  ── Batch (claude -p) ────────────────────────────────────────────────────"
	@echo "    make ai-p MODEL=<model> PROMPT='<prompt>'   # single batch invocation"
	@echo "    make ai-run HARNESS=aider                   # swap harness"
	@echo ""

## ai-warn-bridges: start subscription bridges if not running; warn to auth if they stay down
## Called automatically by make ai. Non-interactive — never prompts for credentials.
## If a bridge needs first-time auth, run: make ai-auth PROVIDER=kimi|gemini|codex
##   kimi         — Alibaba MaaS endpoint (no local proxy needed)
##   gemini/codex — CLIProxyAPI        :8317  starts automatically if already authenticated
.PHONY: ai-warn-bridges
ai-warn-bridges:
	@$(LIB_DIR)/scripts/ai-warn-bridges.sh


## ai-auth: log in to all AI providers (run once per machine or after token expiry)
##   make ai-auth              # all providers
##   make ai-auth PROVIDER=claude   # claude /login
##   make ai-auth PROVIDER=kimi     # (no longer required — uses ALIBABA_PLAN_KEY)
##   make ai-auth PROVIDER=gemini   # cliproxyapi -login  (Google OAuth → ~/.cli-proxy-api/)
##   make ai-auth PROVIDER=codex    # cliproxyapi -codex-login
PROVIDER ?=
.PHONY: ai-auth
ai-auth:
	@$(BIN_DIR)/install-ai-auth.sh $(if $(PROVIDER),-p $(PROVIDER))


# ── Supporting sidecars ───────────────────────────────────────────────────────

## cliproxyapi: CLIProxyAPI — wraps codex/gemini CLI auth as OpenAI-compatible API
## Install: brew install cliproxyapi  Login: codex login  or  gemini auth login
## Config is managed by chezmoi (~/.local/share/chezmoi/dot_config/cliproxyapi/config.yaml.tmpl)
## which resolves the API key from 1Password at apply time (r-cto-dev105 Law IV Pattern B).
CLIPROXYAPI_PORT ?= 8317
.PHONY: cliproxyapi
cliproxyapi:
	CLIPROXYAPI_PORT=$(CLIPROXYAPI_PORT) TNE_LOG_DIR=$(TNE_LOG_DIR) $(BIN_DIR)/start-cliproxyapi.sh

## routellm: RouteLLM difficulty-routing server
ROUTELLM_PORT ?= 6060
ROUTELLM_CFG  ?= $(HOME)/.config/routellm/config.yaml
.PHONY: routellm
routellm:
	ROUTELLM_PORT=$(ROUTELLM_PORT) ROUTELLM_CFG=$(ROUTELLM_CFG) TNE_LOG_DIR=$(TNE_LOG_DIR) $(BIN_DIR)/start-routellm.sh

## ai-open: open service UIs in Chrome — once per session (stamp in /tmp, resets on reboot)
## Skips any port not yet listening. Safe to call multiple times — no duplicate tabs.
AI_OPEN_STAMP ?= /tmp/.make-ai-open-$(shell id -u)
.PHONY: ai-open
ai-open:
	LITELLM_PORT=$(LITELLM_PORT) MLFLOW_PORT=$(MLFLOW_PORT) TEMPORAL_UI_PORT=$(TEMPORAL_UI_PORT) CCR_PORT=$(CCR_PORT) KTAP_PORT=$(KTAP_PORT) LLS_PORT=$(LLS_PORT) AI_OPEN_STAMP=$(AI_OPEN_STAMP) $(BIN_DIR)/open-ai.sh

## ai-open-force: open all service UIs unconditionally (clears once-per-session guard)
.PHONY: ai-open-force
ai-open-force:
	@rm -f "$(AI_OPEN_STAMP)"
	@$(MAKE) -f $(firstword $(MAKEFILE_LIST)) ai-open

## ai-status: health check for all sidecars
.PHONY: ai-status
ai-status:
	$(BIN_DIR)/start-ai.sh --status

## ai-models: list available models with make invocation examples
.PHONY: ai-models
ai-models:
	LITELLM_CFG=$(LITELLM_CFG) LLS_PORT=$(LLS_PORT) $(BIN_DIR)/help-ai.sh

## ai-keys: show which env vars are required for each PLAN provider and where to get them
## Sources:
##   Z.AI:    https://z.ai/subscribe → account → API Keys (regular key, no special prefix)
##   MiniMax: https://platform.minimax.io/subscribe/token-plan — Token Plan $10-20/mo
##   Alibaba: https://bailian.console.aliyun.com/ → API Keys → ALIBABA_PLAN_KEY
##   Gemini:  make ai-auth PROVIDER=gemini — Google OAuth via cliproxyapi
##   Kimi:    claude-code-proxy handles auth — no extra key needed
.PHONY: ai-keys
ai-keys:
	$(BIN_DIR)/show-keys.sh
## ai-logs: push Claude Code session logs to MLflow
.PHONY: ai-logs
ai-logs:
	$(BIN_DIR)/logs-push.sh

## push-logs: alias for ai-logs (clearer name)
.PHONY: push-logs
push-logs:
	$(BIN_DIR)/logs-push.sh

## ai-log: tail all sidecar logs from TNE_LOG_DIR (Ctrl-C to stop)
.PHONY: ai-log
ai-log:
	TNE_LOG_DIR=$(TNE_LOG_DIR) LITELLM_PORT=$(LITELLM_PORT) MLFLOW_PORT=$(MLFLOW_PORT) KTAP_PORT=$(KTAP_PORT) $(BIN_DIR)/logs-watch.sh

## watch-logs: alias for ai-log (clearer name)
.PHONY: watch-logs
watch-logs:
	TNE_LOG_DIR=$(TNE_LOG_DIR) LITELLM_PORT=$(LITELLM_PORT) MLFLOW_PORT=$(MLFLOW_PORT) KTAP_PORT=$(KTAP_PORT) $(BIN_DIR)/logs-watch.sh

## ai-test: canonical end-to-end check for the ai-* stack
##   Runs all three phases unconditionally — bias toward complete since ai-test
##   is invoked rarely (after `make ai` startup, not on every change):
##     Phase 1: tools, config, sidecars (no model calls) — ai-test-infra
##     Phase 2: live round-trip to every cloud model     — ai-test-models
##     Phase 3: quality probe ("2+2") on one per backend  — ai-test-quality
##   Reports ✓/✗ per check; exits 1 if Phase 3 quality probe regresses.
##   Sub-targets above are runnable individually for debugging.
.PHONY: ai-test
ai-test: ai-test-infra ai-test-models ai-test-quality

.PHONY: ai-test-infra
ai-test-infra:
	@$(LIB_DIR)/scripts/ai-test.sh infra

.PHONY: ai-test-models
ai-test-models:
	@$(LIB_DIR)/scripts/ai-test.sh models

## ai-test-quality: Phase 3 of `make ai-test` — quality probe per backend
##   Sends a specific prompt ("2+2") and checks output matches expected pattern.
##   Uses one representative model per backend (override via AI_QUALITY_MODELS).
##   Exits 1 if any model misses — turns ai-test into a real CI pre-flight.
AI_QUALITY_MODELS ?= qwen-max gpt-5.4-mini gemini-2.5-flash deepseek-v4-pro kimi-k2.6 minimax-m2.7 glm-4.7-flash or-nemotron-super-120b
.PHONY: ai-test-quality
ai-test-quality:
	@$(LIB_DIR)/scripts/ai-test.sh quality

## ai-test-restart: cold-start idempotency check (r-cto-ops92)
##   Stops the full AI stack, restarts it, then runs infra check.
##   Catches regressions that only appear on cold start:
##     - temporal running in-memory (no --db-filename)
##     - prisma not connected at startup
##     - port conflicts between old + new processes
##   Run after any change to start-ai.sh, temporal-dev, or litellm formulas.
.PHONY: ai-test-restart
ai-test-restart:
	@echo "==> ai-test-restart: stop → start → infra check"
	@$(BIN_DIR)/start-ai.sh --stop
	@$(BIN_DIR)/start-ai.sh
	@$(LIB_DIR)/scripts/ai-test.sh infra

## ai-sync: write-back sync — upsert new models from live provider catalogs into LITELLM_CFG
##   Currently syncs CLIProxyAPI :$(CLIPROXYAPI_PORT) (gemini + codex/gpt-5 subscriptions).
##   Add-only: existing entries are preserved; nothing is removed.
##   After sync: restart LiteLLM to activate new entries (make litellm).
##   Extend: add ai-sync-<provider> targets and list them as prerequisites here.
.PHONY: ai-sync ai-sync-cliproxyapi
## ai-sync: sync provider model names into LITELLM_CFG (delegates to install-litellm-sync.sh)
ai-sync:
	$(BIN_DIR)/install-litellm-sync.sh $(FLAGS)

## ai-sync-force: bypass 7-day cache and query live provider APIs
.PHONY: ai-sync-force
ai-sync-force:
	$(BIN_DIR)/install-litellm-sync.sh -f $(FLAGS)


## ai-latest-models: list models from each provider + what is in LITELLM_CFG
##   Delegates to install-litellm-sync.sh --list
.PHONY: ai-latest-models
ai-latest-models:
	$(BIN_DIR)/install-litellm-sync.sh -l $(FLAGS)

## ai-test-ui: playwright smoke test — verify each service UI renders correctly
##   Requires: make ai (sidecars up). Saves failure screenshots to /tmp.
.PHONY: ai-test-ui
ai-test-ui:
	@echo "==> AI sidecar UI smoke tests (playwright)"
	@python3 $(dir $(abspath $(lastword $(MAKEFILE_LIST))))../bin/check-ai-ui.py

## ai-test-ui-litellm: check only LiteLLM Admin UI
.PHONY: ai-test-ui-litellm
ai-test-ui-litellm:
	@python3 $(dir $(abspath $(lastword $(MAKEFILE_LIST))))../bin/check-ai-ui.py --service litellm

## ai-test-ui-mlflow: check only MLflow UI
.PHONY: ai-test-ui-mlflow
ai-test-ui-mlflow:
	@python3 $(dir $(abspath $(lastword $(MAKEFILE_LIST))))../bin/check-ai-ui.py --service mlflow

## ai-ps: process status of all sidecars
.PHONY: ai-ps
ai-ps: mlflow.ps litellm.ps temporal.ps ccr.ps
	brew services list | grep -E "postgresql|redis" | awk '{printf "%-10s %s\n", $$1, $$2}'

## ai-stop: stop all sidecars (brew services stop for postgres/redis, SIGTERM for others)
## Stops local GPU inference (lms) if running, and releases GPU memory limit.
.PHONY: ai-stop
ai-stop: $(MLFLOW_PORT).stop litellm.stop $(TEMPORAL_PORT).stop $(CCR_PORT).stop
	brew services stop temporal 2>/dev/null || true
	brew services stop redis 2>/dev/null || true
	brew services stop postgresql@17 2>/dev/null || brew services stop postgresql 2>/dev/null || true
	command -v lms >/dev/null 2>&1 && lms server stop 2>/dev/null || true
	sudo sysctl iogpu.wired_limit_mb=0 2>/dev/null || true

## ai-install: install AI stack (brew + uv + services) via bin/install-ai.sh
## Delegates to bin/install-ai.sh — single source of truth (r-cto-dev98, r-cto-dev109)
## After install: make ai-status to verify | make ai to launch
.PHONY: ai-install
ai-install:
	$(BIN_DIR)/install-ai.sh -v
## set-gpu-max-memory: allocate maximum RAM to GPU (needed for large local models)
.PHONY: set-gpu-max-memory
set-gpu-max-memory:
	$(BIN_DIR)/set-gpu-max-memory.sh

## lms-server: start LM Studio local inference server
.PHONY: lms-server
lms-server:
	lms server start

## lls-start: start llama-server router (llama.cpp b9200+ native multi-model swap)
## Uses ~/.config/litellm/llama-presets.ini — add new models there after downloading via LM Studio.
## One model loaded at a time (--models-max 1); swaps automatically on model field change.
## Port 8081 (8080 is reserved for CLIProxyAPI/Gemini).
.PHONY: lls-start
lls-start:
	LLS_PORT=$(LLS_PORT) LLS_PRESETS=$(LLS_PRESETS) LITELLM_CFG=$(LITELLM_CFG) LLS_CTX=$(LLS_CTX) $(BIN_DIR)/start-lls.sh

## lls-stop: stop llama-server router
.PHONY: lls-stop
lls-stop:
	LLS_PORT=$(LLS_PORT) $(BIN_DIR)/start-lls.sh --stop

## lls-sync: sync lls/* litellm entries + llama-presets.ini from lms ls --json (GGUF only)
## Setup: open LM Studio → Browse → Staff Picks → download GGUF variants → run make lls-sync
## Discovers all GGUF LLMs via `lms ls --json`; skips safetensors (llama-server can't load them).
## lls/<vendor>/<model> → openai/<gguf-basename> in litellm; preset pinned to ctx=100000, kv=q8_0.
## lls/auto = largest (most capable) GGUF; fallback chain escalates down to smallest.
## Run after adding/removing models; safe to re-run (idempotent).
LLS_CTX ?= 100000
LLS_PRESETS ?= $(HOME)/.config/litellm/llama-presets.ini
.PHONY: lls-sync
lls-sync:
	LITELLM_CFG=$(LITELLM_CFG) LLS_PRESETS=$(LLS_PRESETS) LLS_PORT=$(LLS_PORT) LLS_CTX=$(LLS_CTX) $(BIN_DIR)/sync-lls.sh
## lms-sync: sync litellm config model_names with lms ls output
## Removes all lms/* entries and re-adds them as lms/<vendor>/<model> to match lms ls IDs.
## Also writes local-only fallbacks (smallest → next-smallest) so ai-local never leaks to cloud.
## Run after installing new models in LM Studio.
.PHONY: lms-sync
lms-sync:
	LITELLM_CFG=$(LITELLM_CFG) $(BIN_DIR)/sync-lms.sh
# ── Commented-out stacks ──────────────────────────────────────────────────────

## temporal: Temporal workflow server at http://localhost:$(TEMPORAL_PORT)
##   Uses a custom brew services plist so --db-filename + --ui-port are honored
##   across reboots and brew lifecycle (vanilla brew plist has no flags → in-memory
##   mode; launchctl auto-respawns the unflagged process so start_server skips).
##   See TNE-CONTEXT/cco/bug-fix-brief-temporal-in-memory-startup.md for full RCA.
TEMPORAL_PLIST ?= $(TNE_DB_DIR)/temporal/homebrew.mxcl.temporal-tne.plist
.PHONY: temporal
temporal:
	TEMPORAL_PORT=$(TEMPORAL_PORT) TEMPORAL_UI_PORT=$(TEMPORAL_UI_PORT) TEMPORAL_DB=$(TEMPORAL_DB) TEMPORAL_PLIST=$(TEMPORAL_PLIST) TNE_DB_DIR=$(TNE_DB_DIR) TNE_LOG_DIR=$(TNE_LOG_DIR) $(BIN_DIR)/start-temporal.sh
# ktap is tne-plugin-only — override in project Makefile if needed
# ## ktap: KTAP knowledge graph viewer at http://localhost:$(KTAP_PORT)
# .PHONY: ktap
# ktap:
# 	cd "$(KTAP_DIR)" && $(call start_server,$(KTAP_PORT),python3 ktap.py viz --port $(KTAP_PORT))
# 	$(call check_port,$(KTAP_PORT))

## ccr: Claude Code Router at http://localhost:$(CCR_PORT)
# BUG(2026-05-10): ccr start exits with code 1 even on success — daemon runs fine, launcher
# has wrong exit convention. Track: github.com/musistudio/claude-code-router/issues/544
# CHECK: 2026-06-10 — if fixed upstream, remove || true from start_server_self call.
.PHONY: ccr
ccr:
	CCR_PORT=$(CCR_PORT) TNE_LOG_DIR=$(TNE_LOG_DIR) $(BIN_DIR)/start-ccr.sh

## Kimi ccproxy bridge — legacy; kimi-k2.6 now uses Alibaba MaaS (no local proxy needed).
## Use: make ai-run MODEL=kimi-k2.6   (canonical path — routes through LiteLLM :4000 → Alibaba MaaS)
## Auth: make ai-auth PROVIDER=kimi   (one-time OAuth login)
KIMI_CLAUDE_PROXY_PORT ?= 3457
KIMI_CLAUDE_PROVIDER   ?= kimi

# ── Commented-out local inference stacks ─────────────────────────────────────

# ## ollama: Ollama local inference at http://localhost:11434
# OLLAMA_CONTEXT_LENGTH ?= 131072
# OLLAMA_FLASH_ATTENTION ?= 1
# OLLAMA_KV_CACHE_TYPE   ?= q4_0
# OLLAMA_BASE_URL        ?= http://localhost:$(OLLAMA_SERVER_PORT)
# define start_ollama
# 	$(call start_server,$(2),OLLAMA_CONTEXT_LENGTH=$(OLLAMA_CONTEXT_LENGTH) \
# 		OLLAMA_HOST=$(3) OLLAMA_FLASH_ATTENTION=$(OLLAMA_FLASH_ATTENTION) \
# 		OLLAMA_KV_CACHE_TYPE=$(OLLAMA_KV_CACHE_TYPE) $(1) serve)
# 	$(call check_port,$(2))
# endef
# .PHONY: ollama
# ollama:
# 	$(call start_ollama,ollama,$(OLLAMA_SERVER_PORT),127.0.0.1:$(OLLAMA_SERVER_PORT))
# .PHONY: ollama-ls
# ollama-ls:
# 	ollama ls | sort -k3 -hr

# ## open-webui: Open WebUI frontend for Ollama
# .PHONY: open-webui
# open-webui:
# 	-export OLLAMA_BASE_URL="$(OLLAMA_BASE_URL)" DATA_DIR="$(OPEN_WEBUI_DATA_DIR)" && \
# 		$(call start_server,$(OPEN_WEBUI_PORT),open-webui serve --port $(OPEN_WEBUI_PORT))
# 	$(call check_port,$(OPEN_WEBUI_PORT))

## llama-server: llama.cpp inference server at $(LLAMA_SERVER_PORT)
# Note: does not support Mistral or Gemma architecture models
LLAMA_SERVER_PORT ?= 8082
OLLAMA_MODEL  ?= $(HOME)/.ollama/models/blobs
PHI4-14B-GGUF ?= sha256-fd7b6731c33c57f61767612f56517460ec2d1e2e5a3f0163e0eb3d8d8cb5df20
.PHONY: llama-server
llama-server:
	$(call start_server,$(LLAMA_SERVER_PORT),llama-server \
		--ctx-size 131072 --port $(LLAMA_SERVER_PORT) --flash-attn --split-mode row \
		-m "$(OLLAMA_MODEL)/$(PHI4-14B-GGUF)" \
		--cache-type-k q8_0 --cache-type-v q8_0)
	$(call check_port,$(LLAMA_SERVER_PORT))

## mlx: MLX inference server (Apple Silicon) at $(MLX_PORT)
MLX_PORT        ?= 9000
HF_HUB_CACHE    ?= $(HOME)/.cache/huggingface/hub
GLM-4.5-AIR-4BIT ?= models--mlx-community--GLM-4.5-Air-4bit/snapshots/60837794f3caafc4682dd1a9188a82c55a9100ef
.PHONY: mlx
mlx:
	$(call start_server,$(MLX_PORT),mlx_lm.server --port $(MLX_PORT) \
		--model "$(HF_HUB_CACHE)/$(GLM-4.5-AIR-4BIT)")
	$(call check_port,$(MLX_PORT))

## tika: Apache Tika document extraction server at port 9998
TIKA_VERSION ?= 2.9.2
TIKA_JAR     ?= tika-server-standard-$(TIKA_VERSION).jar
.PHONY: tika
tika:
	$(call start_server,9998,java -jar "$$HOME/jar/$(TIKA_JAR)")
	$(call check_port,9998)

## comfy: start ComfyUI Desktop
.PHONY: comfy
comfy:
	open -a "ComfyUI.app"

LIB_AI      ?= $(WS_DIR)/git/src/lib/lib-ai.sh
LIB_SECRETS ?= $(WS_DIR)/git/src/lib/lib-secrets.sh
LIB_UTIL    ?= $(WS_DIR)/git/src/lib/lib-util.sh

## ai-check-keys: curl each AI provider's /v1/models — reports valid/expired/unreachable
.PHONY: ai-check-keys
ai-check-keys:
	@bash -c 'source "$(LIB_UTIL)" && source "$(LIB_AI)" && ai_check_api_keys'


# ## mcpo: MCP → OpenAPI adapter (exposes MCP servers as REST endpoints)
# MCPO_PORT    ?= 8001
# MCPO_CONFIG  ?= $(HOME)/.config/mcp/claude-desktop.json
# MCPO_API_KEY ?= secret_mcpo_api_key
# .PHONY: mcpo
# mcpo:
# 	$(call start_server,$(MCPO_PORT),uvx mcpo --port "$(MCPO_PORT)" \
# 		--api-key "$(MCPO_API_KEY)" --config "$(MCPO_CONFIG)")
