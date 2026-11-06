#!/usr/bin/env bats
# shellcheck disable=SC2154 # BATS_TEST_DIRNAME is set by bats at runtime
# test/freeride.bats — the freeride catalog and mode helpers (lib/freeride.sh)
# plus the freeride-aware doctor audit.
#
# These pin the CONTRACT: catalog shape, per-role model resolution, the
# cloudflare account-id requirement, the per-provider model override, mode
# priority (legacy > freeride) and the doctor blocker's two-path message.
# Every case runs under `env -i` so an ambient BOUCLE_* cannot satisfy it.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$BATS_TEST_DIRNAME/.."
  FREERIDE_LIB="$REPO/lib/freeride.sh"
}

# ── Catalog ────────────────────────────────────────────────────────────

@test "freeride_catalog: lists the 7 providers with pipe-delimited key columns" {
  run env -i PATH="$PATH" HOME="$HOME" bash -c "source '$FREERIDE_LIB'; freeride_catalog"
  assert_success
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "7" ]
  assert_output --partial "BOUCLE_GROQ_API_KEY"
  assert_output --partial "BOUCLE_NVIDIA_API_KEY"
  assert_output --partial "BOUCLE_CLOUDFLARE_API_KEY"
  assert_output --partial "BOUCLE_MISTRAL_API_KEY"
}

@test "freeride_providers: a provider with no key is skipped" {
  run env -i PATH="$PATH" HOME="$HOME" bash -c "source '$FREERIDE_LIB'; freeride_providers worker"
  assert_success
  refute_output --partial "groq"
}

@test "freeride_providers: worker resolves the code model" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_GROQ_API_KEY=x \
    bash -c "source '$FREERIDE_LIB'; freeride_providers worker"
  assert_success
  assert_output --partial "groq|https://api.groq.com/openai/v1|BOUCLE_GROQ_API_KEY|qwen/qwen3-32b|high"
}

@test "freeride_providers: triage resolves the reasoning model" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_GROQ_API_KEY=x \
    bash -c "source '$FREERIDE_LIB'; freeride_providers triage"
  assert_success
  assert_output --partial "|openai/gpt-oss-120b|high"
}

@test "freeride_providers: cloudflare without an account id is skipped" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_CLOUDFLARE_API_KEY=x \
    bash -c "source '$FREERIDE_LIB'; freeride_providers worker"
  assert_success
  refute_output --partial "cloudflare"
}

@test "freeride_providers: cloudflare with an account id resolves its base_url" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_CLOUDFLARE_API_KEY=x BOUCLE_CLOUDFLARE_ACCOUNT_ID=acct123 \
    bash -c "source '$FREERIDE_LIB'; freeride_providers worker"
  assert_success
  assert_output --partial "cloudflare|https://api.cloudflare.com/client/v4/accounts/acct123/ai/v1|BOUCLE_CLOUDFLARE_API_KEY|"
}

@test "freeride_providers: BOUCLE_<PROVIDER>_MODEL overrides the resolved model" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_GROQ_API_KEY=x BOUCLE_GROQ_MODEL=custom-model \
    bash -c "source '$FREERIDE_LIB'; freeride_providers worker"
  assert_success
  assert_output --partial "|custom-model|high"
}

# ── Mode helpers ───────────────────────────────────────────────────────

@test "has_llm_config: the legacy pair is enough" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_BASE_URL=https://x/v1 BOUCLE_LLM_API_KEY=k \
    bash -c "source '$FREERIDE_LIB'; has_llm_config"
  assert_success
}

@test "has_llm_config: a freeride key alone is enough" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_GROQ_API_KEY=x \
    bash -c "source '$FREERIDE_LIB'; has_llm_config"
  assert_success
}

@test "has_llm_config: nothing configured is not enough" {
  run env -i PATH="$PATH" HOME="$HOME" bash -c "source '$FREERIDE_LIB'; has_llm_config"
  assert_failure
}

@test "is_freeride_mode: the legacy pair beats freeride keys" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_BASE_URL=https://x/v1 BOUCLE_LLM_API_KEY=k BOUCLE_GROQ_API_KEY=x \
    bash -c "source '$FREERIDE_LIB'; is_freeride_mode"
  assert_failure
}

@test "is_freeride_mode: a freeride key alone is freeride mode" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_GROQ_API_KEY=x \
    bash -c "source '$FREERIDE_LIB'; is_freeride_mode"
  assert_success
}

# ── Doctor audit (freeride-aware blocker) ──────────────────────────────

@test "doctor --audit: a freeride key alone raises no blocker and lists the provider" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_GROQ_API_KEY=x bash bin/doctor --audit
  assert_success
  refute_output --partial "BLOCKER"
  assert_output --partial "freeride LLM config detected"
  assert_output --partial "groq (openai/gpt-oss-120b)"
}

@test "doctor --audit: no config at all blocks and names both paths" {
  run env -i PATH="$PATH" HOME="$HOME" bash bin/doctor --audit
  assert_failure
  assert_output --partial "BOUCLE_LLM_API_KEY is not set"
  assert_output --partial "freeride provider key"
}
