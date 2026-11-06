#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# lib/profile.sh — first-issue project profile determination (#186).
#
# The install profile (`site` vs `infra`, #182) is decided once, at setup
# time. A repo installed non-interactively defaults to `site`; an infra repo
# installed that way then runs the full site pipeline (worker build gate
# fails, deploy has nothing to publish, URL-mode e2e probes a site that does
# not exist). #186 lets the FIRST issue entering the loop determine the
# profile deterministically, propose it to the human, and apply it on
# confirmation — reusing the no-key needs-info rails (comment marker, label,
# emoji/reply re-trigger).
#
# This file holds the PURE pieces:
#   - detect_project_profile — deterministic repo-signal detection, no LLM,
#     no network. Returns `site|infra|unknown` plus evidence lines.
#   - profile_decision — pure state-machine decision from the effective
#     profile, the determination-comment marker, the note reactions and the
#     human replies. Returns the action the triage stage must take.
#
# Sourced by lib/boucle.sh (available to every CI stage) and by bin/setup
# (the install-time detection + preset application).
#
# Keeping the detection and the decision here means they are tested in
# isolation (test/profile.bats) instead of through the full triage stage.

# ── Detection ─────────────────────────────────────────────────────────────
#
# detect_project_profile [root]
#
# Scan a repository tree for site and infra signals and print:
#   line 1  — the profile: `site`, `infra`, or `unknown`
#   line 2+ — zero or more `evidence: <path>` lines naming what matched
#
# Deterministic: no LLM, no network, no package-manager invocation. The
# scan is shallow on purpose — config files sit at the repo root in every
# framework, and a deep walk would make triage pay for a large tree. An
# ambiguous tree (both families present) returns `unknown` with the evidence
# from BOTH families so the human can arbitrate; an empty tree returns
# `unknown` with no evidence.
detect_project_profile() {
  local root="${1:-.}"
  [ -d "$root" ] || {
    printf 'unknown\n'
    return 0
  }

  local site_evidence=()
  local infra_evidence=()
  local f base

  # ── Site signals ────────────────────────────────────────────────────
  # Framework config files: unambiguous, sit at the repo root.
  for f in astro.config.mjs astro.config.js astro.config.ts astro.config.cjs \
    next.config.js next.config.mjs next.config.ts \
    nuxt.config.js nuxt.config.ts \
    mkdocs.yml _config.yml hugo.toml hugo.yaml hugo.yml; do
    [ -f "$root/$f" ] && site_evidence+=("$f")
  done

  # package.json declaring a static-site framework in its deps. Read with jq
  # when available (the repo already depends on it); fall back to a grep that
  # is scoped to the dependency keys so a script named "astro" cannot match.
  if [ -f "$root/package.json" ]; then
    local framework=""
    if command -v jq > /dev/null 2>&1; then
      framework=$(jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys[]' "$root/package.json" 2> /dev/null \
        | grep -E '^(astro|next|nuxt|gatsby|@11ty/eleventy|vitepress|hugo)$' | head -n 1 || true)
    else
      framework=$(grep -oE '"(astro|next|nuxt|gatsby|@11ty/eleventy|vitepress|hugo)"[[:space:]]*:' "$root/package.json" 2> /dev/null \
        | head -n 1 | sed 's/["[:space:]:]//g' || true)
    fi
    [ -n "$framework" ] && site_evidence+=("package.json ($framework)")
  fi

  # ── Infra signals ───────────────────────────────────────────────────
  # Ansible config at the root.
  [ -f "$root/ansible.cfg" ] && infra_evidence+=("ansible.cfg")

  # Terraform: a terraform/ directory or a root-level *.tf file.
  if [ -d "$root/terraform" ]; then
    infra_evidence+=("terraform/")
  else
    for f in "$root"/*.tf; do
      [ -e "$f" ] || continue
      base=$(basename "$f")
      infra_evidence+=("$base")
      break
    done
  fi

  # Kubernetes / Kustomize manifests.
  [ -f "$root/kustomization.yaml" ] && infra_evidence+=("kustomization.yaml")
  [ -f "$root/kustomization.yml" ] && infra_evidence+=("kustomization.yml")

  # Pulumi configs.
  for f in "$root"/Pulumi*.yaml "$root"/Pulumi*.yml; do
    [ -e "$f" ] || continue
    infra_evidence+=("$(basename "$f")")
    break
  done

  # CloudFormation templates.
  for f in "$root"/*.yaml "$root"/*.yml "$root"/*.json; do
    [ -e "$f" ] || continue
    if grep -q 'AWSTemplateFormatVersion' "$f" 2> /dev/null; then
      infra_evidence+=("$(basename "$f") (CloudFormation)")
      break
    fi
  done

  # Playbook-shaped YAML: a top-level yml/yaml declaring both `hosts:` and
  # `tasks:` or `roles:`. Keep the scan to the repo root — playbooks live
  # there or in a known playbooks/ directory in practice.
  local candidates=()
  for f in "$root"/*.yml "$root"/*.yaml; do
    [ -e "$f" ] || continue
    candidates+=("$f")
  done
  if [ -d "$root/playbooks" ]; then
    for f in "$root/playbooks"/*.yml "$root/playbooks"/*.yaml; do
      [ -e "$f" ] || continue
      candidates+=("$f")
    done
  fi
  for f in "${candidates[@]+"${candidates[@]}"}"; do
    if grep -qE '^[[:space:]]*(-[[:space:]]+)?hosts:' "$f" 2> /dev/null \
      && grep -qE '^[[:space:]]*(-[[:space:]]+)?(tasks|roles):' "$f" 2> /dev/null; then
      infra_evidence+=("$(basename "$f") (playbook)")
      break
    fi
  done

  # ── Verdict ─────────────────────────────────────────────────────────
  local has_site=0 has_infra=0
  [ "${#site_evidence[@]}" -gt 0 ] && has_site=1
  [ "${#infra_evidence[@]}" -gt 0 ] && has_infra=1

  if [ "$has_site" -eq 1 ] && [ "$has_infra" -eq 0 ]; then
    printf 'site\n'
    for f in "${site_evidence[@]}"; do
      printf 'evidence: %s\n' "$f"
    done
    return 0
  fi
  if [ "$has_infra" -eq 1 ] && [ "$has_site" -eq 0 ]; then
    printf 'infra\n'
    for f in "${infra_evidence[@]}"; do
      printf 'evidence: %s\n' "$f"
    done
    return 0
  fi
  # Both families present (ambiguous) or neither (empty tree).
  printf 'unknown\n'
  for f in "${site_evidence[@]+"${site_evidence[@]}"}"; do
    printf 'evidence: %s\n' "$f"
  done
  for f in "${infra_evidence[@]+"${infra_evidence[@]}"}"; do
    printf 'evidence: %s\n' "$f"
  done
  return 0
}

# ── Decision ──────────────────────────────────────────────────────────────
#
# profile_decision <effective_profile> <marker> <reactions_json> <replies_text>
#
# Pure: no network, no forge calls. Decides what the triage stage must do
# with the first-issue profile flow. Arguments:
#
#   effective_profile — `${BOUCLE_PROFILE:-auto}` at triage time. An explicit
#                       `site`/`infra` means the install already chose: the
#                       flow MUST NOT intervene.
#   marker            — the marker on the latest profile determination
#                       comment: `none`, `needs-info`, or `profile-applied`.
#   reactions_json    — JSON array of canonical reaction names on that
#                       comment (`[]` when absent/malformed).
#   replies_text      — newline-separated human reply bodies posted AFTER
#                       the determination comment.
#
# Returns ONE action string on stdout:
#   explicit      — effective profile is site/infra; no intervention.
#   no-marker     — no determination comment yet; run detection.
#   apply-infra   — a decisive confirmation for infra; apply the preset.
#   apply-site    — a decisive confirmation for site; record site.
#   applied       — the comment already carries the applied marker; skip.
#   stay          — a determination exists but no decisive answer yet;
#                   refresh the comment and keep needs-info.
#
# Precedence: an explicit reply line (`profile: site|infra`) overrides the
# emoji reaction; among reactions, an approval emoji means infra and a
# thumbs-down means site. Approval emojis mirror the canonical set the
# dispatch/doctor use for spec approval: thumbsup, heart, rocket, tada.
profile_decision() {
  local effective="${1:-auto}"
  local marker="${2:-none}"
  local reactions="${3:-[]}"
  local replies="${4:-}"

  # Explicit install profile — never intervene.
  case "$effective" in
    site | infra)
      printf 'explicit\n'
      return 0
      ;;
  esac

  # Already applied — idempotent, never re-post.
  [ "$marker" = "profile-applied" ] && {
    printf 'applied\n'
    return 0
  }

  # No determination comment yet — detection runs.
  [ "$marker" = "none" ] && {
    printf 'no-marker\n'
    return 0
  }

  # A determination comment exists (`needs-info`): read the answer.
  # A reply line overrides an emoji reaction.
  if printf '%s\n' "$replies" | grep -qiE '^[[:space:]]*profile:[[:space:]]*infra[[:space:]]*$'; then
    printf 'apply-infra\n'
    return 0
  fi
  if printf '%s\n' "$replies" | grep -qiE '^[[:space:]]*profile:[[:space:]]*site[[:space:]]*$'; then
    printf 'apply-site\n'
    return 0
  fi

  # Normalize the reaction array defensively: a malformed/absent payload is
  # an empty set, never a crash.
  local names=""
  if command -v jq > /dev/null 2>&1; then
    names=$(printf '%s' "$reactions" | jq -r '.[]? | select(type == "string")' 2> /dev/null || true)
  else
    names=$(printf '%s' "$reactions" | grep -oE '"[a-z_]+"' | tr -d '"' || true)
  fi

  if printf '%s\n' "$names" | grep -qxE 'thumbsup|heart|rocket|tada'; then
    printf 'apply-infra\n'
    return 0
  fi
  if printf '%s\n' "$names" | grep -qx 'thumbs_down'; then
    printf 'apply-site\n'
    return 0
  fi

  printf 'stay\n'
  return 0
}

# ── Preset application ────────────────────────────────────────────────────
#
# apply_profile_preset <profile> [--dry-run]
#
# Set the install-profile variables through the forge API (`forge_ci_var_set`
# in bin/forge/). Best-effort: a transient API error must never abort the
# triage run — the caller continues with the issue's normal triage.
#
# Presets (mirroring bin/setup's #182 infra preset):
#   infra — BOUCLE_PROFILE=infra, BOUCLE_DEPLOY_MODE=external,
#           BOUCLE_REVIEW_MODE=diff, BOUCLE_E2E_COMMAND=true,
#           BOUCLE_BUILD_CMD=true, BOUCLE_UPDATE_DISABLE=true.
#   site  — BOUCLE_PROFILE=site only.
#
# Precedence note (GitLab): project CI/CD variables override variables
# defined in `.gitlab-ci.yml` — so these writes take effect even when the
# root shim's `variables:` block still carries the old value. That is what
# makes the triage-time application work without editing the shim. On
# GitHub, a repo Variable only reaches a job when the workflow maps it in
# its `env:` block; the workflow maps the preset vars but NOT BOUCLE_PROFILE
# itself, so the caller prints the `gh variable set` commands in the
# determination comment as a fail-open fallback (documented deviation).
#
# The preset does NOT neutralize the engine's inherited `default:` (the
# `inherit: default: false` contract lives in the root shim and only
# `bin/setup --profile infra` regenerates it). The determination comment
# MUST warn about that.
apply_profile_preset() {
  local profile="$1" dry_run="${2:-}"
  local vars=() values=()

  case "$profile" in
    infra)
      vars=(BOUCLE_PROFILE BOUCLE_DEPLOY_MODE BOUCLE_REVIEW_MODE BOUCLE_E2E_COMMAND BOUCLE_BUILD_CMD BOUCLE_UPDATE_DISABLE)
      values=(infra external diff true true true)
      ;;
    site)
      vars=(BOUCLE_PROFILE)
      values=(site)
      ;;
    *)
      echo "apply_profile_preset: unknown profile '$profile' (expected: infra|site)" >&2
      return 1
      ;;
  esac

  local i
  for i in "${!vars[@]}"; do
    if [ "$dry_run" = "--dry-run" ]; then
      printf 'would set %s=%s\n' "${vars[$i]}" "${values[$i]}"
      continue
    fi
    forge_ci_var_set "${vars[$i]}" "${values[$i]}" 2> /dev/null || true
  done
}
