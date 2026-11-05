#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2250
# lib/freeride.sh — single source of truth for the freeride free-tier LLM
# provider catalog and the helpers built on it.
#
# Sourced by:
#   - bin/jc            (agent runtime: builds the freeride jcode profiles,
#                        rotates providers, injects per-provider thinking)
#   - lib/boucle.sh     (triage's no-key guard via has_llm_config)
#   - bin/doctor        (--audit: freeride-aware main blocker)
#   - bin/setup         (the LLM-mode step: seed/inspect provider keys)
#   - bin/describe-images (freeride-aware vision-routing guard)
#
# Keeping the catalog here means a provider is described exactly ONCE.
# Before this file existed, bin/jc held the catalog and lib/boucle.sh kept a
# hand-copied key list that drifted the moment a provider was added.
#
# Mode priority: Legacy (BOUCLE_LLM_BASE_URL + BOUCLE_LLM_API_KEY) >
# Freeride (BOUCLE_<PROVIDER>_API_KEY) > No-key (triage posts help).
# The legacy pair WINS on purpose: is_freeride_mode() returns false when it
# is set, so a consumer switching to freeride MUST remove the legacy pair.
#
# Catalog format: name|base_url|key_env|code_model|reasoning_model|thinking
#   worker/reviewer/retro-impl → code_model
#   triage/e2e/retro           → reasoning_model
#   any other role             → code_model
#   BOUCLE_<PROVIDER>_MODEL overrides the resolved model per provider.
#   cloudflare is skipped without BOUCLE_CLOUDFLARE_ACCOUNT_ID (its base_url
#   embeds the account id; the key alone cannot resolve it).
#
# Model IDs are each provider's own, NOT the ollama-cloud names the agent
# files carry — they track what the provider actually serves, so the two
# DeepSeek entries name different generations on purpose. The HF router
# serves DeepSeek-V4.1-Flash (via Novita, 272K context cap, not the model's
# native 1M). NVIDIA's hosted API documents deepseek-v4-flash and
# deepseek-v4-flash-0731 only; its V4.1 page is NeMo AutoModel (fine-tuning
# coverage), which is a different product from integrate.api.nvidia.com —
# so that entry stays on V4. Re-check both against /models before bumping:
# a name this catalog gets wrong fails the free-tier path silently.

# freeride_catalog — print the FULL catalog, one provider per line, in the
# order providers are tried. Independent of which keys are set (setup needs
# the whole list to prompt/seed; the runtime filters with freeride_providers).
freeride_catalog() {
  printf '%s\n' \
    'nvidia|https://integrate.api.nvidia.com/v1|BOUCLE_NVIDIA_API_KEY|deepseek-ai/deepseek-v4-flash|deepseek-ai/deepseek-v4-pro|high' \
    'groq|https://api.groq.com/openai/v1|BOUCLE_GROQ_API_KEY|qwen/qwen3-32b|openai/gpt-oss-120b|high' \
    'cerebras|https://api.cerebras.ai/v1|BOUCLE_CEREBRAS_API_KEY|gpt-oss-120b|zai-glm-4.7|none' \
    'zhipu|https://open.bigmodel.cn/api/paas/v4|BOUCLE_ZHIPU_API_KEY|glm-4.5-flash|glm-4.7-flash|thinking' \
    'cloudflare|https://api.cloudflare.com/client/v4/accounts/__CF_ACCOUNT__/ai/v1|BOUCLE_CLOUDFLARE_API_KEY|@cf/meta/llama-3.3-70b-instruct-fp8-fast|@cf/zai-org/glm-4.7-flash|none' \
    'huggingface|https://router.huggingface.co/v1|BOUCLE_HUGGINGFACE_API_KEY|deepseek-ai/DeepSeek-V4.1-Flash|moonshotai/Kimi-K2.6|none' \
    'mistral|https://api.mistral.ai/v1|BOUCLE_MISTRAL_API_KEY|devstral-latest|magistral-medium-latest|none'
}

# freeride_providers <role> — print the USABLE providers (key set, and for
# cloudflare a resolvable account id), one per line, in the catalog's order:
#   name|base_url|key_env|resolved_model|thinking
# Empty when no provider is usable (no freeride config).
freeride_providers() {
  local role="${1:-}"
  local entry name base_url key_env code_model reasoning_model thinking key_val model override_var
  while IFS='|' read -r name base_url key_env code_model reasoning_model thinking; do
    [ -n "$name" ] || continue
    eval "key_val=\${${key_env}:-}"
    [ -n "$key_val" ] || continue
    if [ "$name" = "cloudflare" ] && [ -z "${BOUCLE_CLOUDFLARE_ACCOUNT_ID:-}" ]; then
      continue
    fi
    base_url="${base_url/__CF_ACCOUNT__/${BOUCLE_CLOUDFLARE_ACCOUNT_ID:-}}"
    case "$role" in
      worker | reviewer | retro-impl) model="$code_model" ;;
      triage | e2e | retro) model="$reasoning_model" ;;
      *) model="$code_model" ;;
    esac
    override_var="BOUCLE_$(echo "$name" | tr '[:lower:]' '[:upper:]')_MODEL"
    eval "model=\${${override_var}:-$model}"
    echo "${name}|${base_url}|${key_env}|${model}|${thinking}"
  done < <(freeride_catalog)
}

# has_llm_config — 0 if any LLM configuration is available: the legacy pair
# or at least one freeride provider key. Used by triage's no-key guard.
has_llm_config() {
  [ -n "${BOUCLE_LLM_BASE_URL:-}" ] && [ -n "${BOUCLE_LLM_API_KEY:-}" ] && return 0
  [ -n "$(freeride_providers "${ROLE:-}" 2> /dev/null)" ] && return 0
  return 1
}

# is_freeride_mode — 0 when freeride is the ACTIVE mode. The legacy pair
# wins (returns 1), so freeride keys sitting alongside it are inert.
is_freeride_mode() {
  [ -n "${BOUCLE_LLM_BASE_URL:-}" ] && [ -n "${BOUCLE_LLM_API_KEY:-}" ] && return 1
  [ -n "$(freeride_providers "${ROLE:-}" 2> /dev/null)" ] && return 0
  return 1
}

# inject_freeride_thinking <thinking> — map a provider's thinking hint onto
# the jcode env knobs ("high" → reasoning effort; "thinking" → extra body).
inject_freeride_thinking() {
  local thinking="$1"
  case "$thinking" in
    high)
      export JCODE_OPENAI_REASONING_EFFORT=high
      ;;
    thinking)
      local extra="${JCODE_OPENAI_EXTRA_BODY:-}"
      if [ -n "$extra" ] && echo "$extra" | grep -qv '"thinking"'; then
        export JCODE_OPENAI_EXTRA_BODY="${extra%,}},{\"thinking\":{\"type\":\"enabled\"}}"
      else
        export JCODE_OPENAI_EXTRA_BODY='{"thinking":{"type":"enabled"}}'
      fi
      ;;
    none | *) ;;
  esac
}
