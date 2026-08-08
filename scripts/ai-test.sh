#!/usr/bin/env bash
# ai-test.sh — unified AI stack test: infra + models + quality
# Usage: ai-test.sh [infra|models|quality|all]  (default: all)
# Called by: make ai-test, make ai-test-infra, make ai-test-models, make ai-test-quality
set -o pipefail

SECTION="${1:-all}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_CFG="${LITELLM_CFG:-$HOME/.config/litellm/config.yaml}"
MLFLOW_PORT="${MLFLOW_PORT:-5001}"
TEMPORAL_PORT="${TEMPORAL_PORT:-7233}"
TEMPORAL_DB="${TEMPORAL_DB:-${WS_DIR:-$HOME/ws}/db/temporal/temporal.db}"
CCR_PORT="${CCR_PORT:-3456}"
KIMI_PORT="${KIMI_CLAUDE_PROXY_PORT:-3457}"
CLIPROXY_PORT="${CLIPROXYAPI_PORT:-8317}"
ROUTELLM_PORT="${ROUTELLM_PORT:-6060}"
AI_QUALITY_MODELS="${AI_QUALITY_MODELS:-qwen-max gpt-flash gemini-flash deepseek-v4-pro kimi minimax glm or-nemotron-super-120b}"

port_ready() { nc -z localhost "$1" 2>/dev/null; }

# ── Section: infra ────────────────────────────────────────────────────────────
run_infra() {
	echo "══ make ai (base stack) ══════════════════════════════"
	command -v litellm >/dev/null 2>&1 || uvx litellm --version >/dev/null 2>&1 &&
		echo "✓ litellm installed" || echo "✗ litellm missing — run: make ai-install"
	command -v mlflow >/dev/null 2>&1 || uvx mlflow --version >/dev/null 2>&1 &&
		echo "✓ mlflow installed" || echo "✗ mlflow missing — run: make ai-install"
	command -v temporal >/dev/null 2>&1 &&
		echo "✓ temporal installed" || echo "✗ temporal missing — brew install temporal"
	test -f "$LITELLM_CFG" &&
		echo "✓ litellm config: $LITELLM_CFG" || echo "✗ litellm config missing — run: make ai-install"

	echo "  ports:"
	port_ready 5432 && echo "  ✓ postgres  :5432" || echo "  ✗ postgres  :5432 stopped"
	port_ready 6379 && echo "  ✓ redis     :6379" || echo "  ✗ redis     :6379 stopped"
	port_ready "$MLFLOW_PORT" && echo "  ✓ mlflow    :$MLFLOW_PORT" || echo "  ✗ mlflow    :$MLFLOW_PORT stopped"
	port_ready "$LITELLM_PORT" && echo "  ✓ litellm   :$LITELLM_PORT" || echo "  ✗ litellm   :$LITELLM_PORT stopped → make ai"
	port_ready "$TEMPORAL_PORT" && echo "  ✓ temporal  :$TEMPORAL_PORT" || echo "  ✗ temporal  :$TEMPORAL_PORT stopped → make ai"
	port_ready "$CCR_PORT" && echo "  ✓ ccr       :$CCR_PORT" || echo "  ✗ ccr       :$CCR_PORT stopped"

	if port_ready "$TEMPORAL_PORT"; then
		_tpid=$(pgrep -f "temporal server start-dev" | head -1)
		# Check brew var/ path first (temporal-dev formula), then legacy TEMPORAL_DB path
		_brew_db="/opt/homebrew/var/temporal/temporal.db"
		if [[ -n "$_tpid" ]] && lsof -p "$_tpid" 2>/dev/null | grep -qE "temporal\.db"; then
			_db=$(lsof -p "$_tpid" 2>/dev/null | grep -E "temporal\.db" | awk "{print \$NF}" | head -1)
			echo "  ✓ temporal DB: ${_db:-$_brew_db} (persistent)"
		else
			echo "  ✗ temporal DB: in-memory (workflows lost on restart) — brew services restart temporal-dev"
		fi
	fi

	echo ""
	echo "══ subscription bridges (started by make ai) ══════════"
	command -v claude-code-proxy >/dev/null 2>&1 &&
		echo "✓ claude-code-proxy installed" || echo "✗ claude-code-proxy missing — run: install-ai.sh"
	yq e '.model_list[] | select(.model_name=="kimi-k2.6") | .litellm_params.api_base' "$LITELLM_CFG" 2>/dev/null |
		grep -q "localhost:$KIMI_PORT" &&
		echo "✓ litellm kimi-k2.6 → claude-code-proxy :$KIMI_PORT" ||
		echo "⚠ litellm kimi-k2.6 not routed through :$KIMI_PORT — run: install-litellm-sync.sh"
	port_ready "$KIMI_PORT" && echo "  ✓ kimi proxy :$KIMI_PORT" || echo "  ✗ kimi proxy :$KIMI_PORT stopped → make ai"
	command -v cliproxyapi >/dev/null 2>&1 &&
		echo "✓ cliproxyapi installed" || echo "✗ cliproxyapi missing — run: install-ai.sh"
	port_ready "$CLIPROXY_PORT" && echo "  ✓ cliproxyapi :$CLIPROXY_PORT" || echo "  ✗ cliproxyapi :$CLIPROXY_PORT stopped → make ai"
	port_ready "$ROUTELLM_PORT" && echo "  ✓ routellm :$ROUTELLM_PORT" || echo "  – routellm :$ROUTELLM_PORT not running (optional)"

	echo ""
	echo "══ AI auth status ════════════════════════════════════"
	command -v claude >/dev/null 2>&1 &&
		echo "  ✓ claude CLI present" || echo "  ✗ claude CLI missing — run: install-ai.sh"
	port_ready "$KIMI_PORT" &&
		echo "  ✓ kimi proxy up (auth confirmed by models test)" ||
		echo "  ⚠ kimi not running — make ai (auto-starts) or: make ai-auth PROVIDER=kimi"
	if port_ready "$CLIPROXY_PORT" && [[ -n "${CLIPROXYAPI_KEY:-}" ]]; then
		_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
			"http://localhost:$CLIPROXY_PORT/v1/models" \
			-H "Authorization: Bearer ${CLIPROXYAPI_KEY}" 2>/dev/null || echo "000")
		case "$_code" in
		200) echo "  ✓ cliproxyapi auth OK" ;;
		401 | 403) echo "  ✗ cliproxyapi auth EXPIRED — run: make ai-auth PROVIDER=gemini" ;;
		*) echo "  ⚠ cliproxyapi probe HTTP $_code" ;;
		esac
	elif ! port_ready "$CLIPROXY_PORT"; then
		echo "  ⚠ cliproxyapi not running — run: make ai"
	fi

	echo ""
	echo "══ config + command smoke ═════════════════════════════"
	yq e '.' "$LITELLM_CFG" >/dev/null 2>&1 &&
		echo "✓ litellm config valid YAML" || echo "✗ litellm config invalid YAML"
	port_ready "$LITELLM_PORT" &&
		curl -sf "http://localhost:$LITELLM_PORT/health/readiness" >/dev/null 2>&1 &&
		echo "✓ LiteLLM /health/readiness" || echo "✗ LiteLLM /health/readiness failed"
}

# ── Section: models ───────────────────────────────────────────────────────────
run_models() {
	port_ready "$LITELLM_PORT" || {
		echo "✗ LiteLLM not running — run: make ai"
		exit 1
	}
	local _key="${LITELLM_MASTER_KEY:?missing — source .envrc}"
	[[ "$_key" == op://* ]] && {
		echo "ERROR: LITELLM_MASTER_KEY unresolved op:// literal — direnv did not run (r-coo92 Principle VIII)" >&2
		exit 1
	}

	echo "═══ live model round-trips via LiteLLM :$LITELLM_PORT ══"
	local pass=0 fail=0
	while IFS= read -r model; do
		[[ "$model" =~ ^lms/|^lls/ ]] && continue
		case "$model" in
		claude-*)
			echo "  – $model: skipped (Max plan OAuth — validated via Claude Code session)"
			continue
			;;
		gpt-image-*)
			echo "  – $model: skipped (image-generation model — only supports /v1/images/generations, not chat/completions)"
			continue
			;;
		*-proxy)
			reply=$(curl -sf --max-time 30 -X POST \
				"http://localhost:$LITELLM_PORT/v1/chat/completions" \
				-H "Content-Type: application/json" \
				-H "Authorization: Bearer $_key" \
				-d "{\"model\":\"$model\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"reply with the single word: pong\"}],\"max_tokens\":200}" \
				2>/dev/null |
				python3 -c '
import sys,json
chunks=[l for l in sys.stdin if l.startswith("data:") and l.strip()!="data: [DONE]"]
content="".join(
  json.loads(c[5:])["choices"][0]["delta"].get("content","")
  for c in chunks if json.loads(c[5:]).get("choices",[{}])[0].get("delta",{}).get("content")
)
if not content.strip():
  content="".join(
    json.loads(c[5:])["choices"][0]["delta"].get("reasoning_content","")
    for c in chunks if json.loads(c[5:]).get("choices",[{}])[0].get("delta",{}).get("reasoning_content")
  )
print(content.strip()[:60])
' 2>/dev/null)
			;;
		*)
			reply=$(curl -sf --max-time 30 -X POST \
				"http://localhost:$LITELLM_PORT/v1/chat/completions" \
				-H "Content-Type: application/json" \
				-H "Authorization: Bearer $_key" \
				-d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with the single word: pong\"}],\"max_tokens\":200}" \
				2>/dev/null |
				python3 -c 'import sys,json; r=json.load(sys.stdin); m=r["choices"][0]["message"]; print((m.get("content") or m.get("reasoning_content","")).strip()[:60])' 2>/dev/null)
			;;
		esac
		if [[ -n "$reply" ]]; then
			echo "  ✓ $model: $reply"
			((pass++)) || true
		else
			echo "  ✗ $model: no reply"
			((fail++)) || true
		fi
	done < <(yq '.model_list[].model_name' "$LITELLM_CFG" 2>/dev/null)
	echo ""
	echo "==> $pass passed / $fail failed"
}

# ── Section: quality ──────────────────────────────────────────────────────────
run_quality() {
	port_ready "$LITELLM_PORT" || {
		echo "✗ LiteLLM not running — run: make ai"
		exit 1
	}
	local _key="${LITELLM_MASTER_KEY:?missing — source .envrc}"
	[[ "$_key" == op://* ]] && {
		echo "ERROR: LITELLM_MASTER_KEY unresolved op:// literal — direnv did not run (r-coo92 Principle VIII)" >&2
		exit 1
	}

	echo "══ quality gate (2+2=4 probe) ════════════════════════"
	local pass=0 fail=0
	for model in $AI_QUALITY_MODELS; do
		reply=$(curl -sf --max-time 45 -X POST \
			"http://localhost:$LITELLM_PORT/v1/chat/completions" \
			-H "Content-Type: application/json" \
			-H "Authorization: Bearer $_key" \
			-d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 2+2? Reply with just the digit.\"}],\"max_tokens\":512}" \
			2>/dev/null |
			python3 -c 'import sys,json; d=json.load(sys.stdin); m=d["choices"][0]["message"]; print((m.get("content") or m.get("reasoning_content","")).strip())' 2>/dev/null)
		# Grep the FULL reply for the expected digit — thinking models emit the
		# answer after reasoning, so never truncate before the check. Display a
		# one-line preview only. max_tokens=512 gives reasoning models room to
		# reach the digit (max_tokens=10 cut them off mid-thought).
		preview=$(printf '%s' "$reply" | tr '\n' ' ' | cut -c1-60)
		if echo "$reply" | grep -q "4"; then
			echo "  ✓ $model: '$preview'"
			((pass++)) || true
		else
			echo "  ✗ $model: expected '4', got '$preview'"
			((fail++)) || true
		fi
	done
	echo ""
	echo "==> quality gate: $pass passed / $fail failed"
	[[ "$fail" -eq 0 ]] || exit 1
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$SECTION" in
infra) run_infra ;;
models) run_models ;;
quality) run_quality ;;
all)
	run_infra
	echo ""
	run_models
	echo ""
	run_quality
	;;
*)
	echo "Usage: ai-test.sh [infra|models|quality|all]"
	exit 1
	;;
esac
