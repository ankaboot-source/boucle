#!/usr/bin/env bats
# Skill usage evidence (#49) and generated skill index (#50)
#
# Boucle ships 62 skills and asks agents to load them. Nothing checked that
# they did — the engine mentioned "skill" once, in a comment — and 41 of the
# 62 were named in no prompt at all, so they could never fire.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

extract_skills_func() {
  awk '/^extract_skills_used\(\) \{/,/^}/' bin/jc > "$1"
}

# ── Extraction (#49) ──────────────────────────────────────────────────

@test "skills: loads are extracted from the transcript" {
  TMPF=$(mktemp); T=$(mktemp -d)
  extract_skills_func "$TMPF"
  mkdir -p "$T/.jcode/skills/ui-ux-pro-max" "$T/.jcode/skills/grill-me"
  printf 'skill tool: ui-ux-pro-max\nLoading skill grill-me now\n' > "$T/agent.log"
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; extract_skills_used '$T/agent.log'"
  assert_success
  assert_line "grill-me"
  assert_line "ui-ux-pro-max"
  rm -rf "$TMPF" "$T"
}

@test "skills: a name that is not a skill on disk is not reported" {
  # A false positive here would later become a gate passing on a skill that
  # was never loaded.
  TMPF=$(mktemp); T=$(mktemp -d)
  extract_skills_func "$TMPF"
  mkdir -p "$T/.jcode/skills/grill-me"
  printf 'I considered the skill nonexistent-thing but skipped it\n' > "$T/agent.log"
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; extract_skills_used '$T/agent.log'"
  assert_success
  refute_output --partial "nonexistent-thing"
  rm -rf "$TMPF" "$T"
}

@test "skills: an unreadable transcript is 'not observable', never 'none used'" {
  # Missing evidence stays explicit. This distinction is what would make a
  # gate built on this data safe.
  run grep -q 'observable="no"' bin/jc
  assert_success
  run grep -q 'observable=\$observable' bin/jc
  assert_success
}

@test "skills: usage is reported on the existing metrics channel" {
  run grep -q 'skills_used=\${used:-none}' bin/jc
  assert_success
}

@test "skills: nothing fails or blocks on skill usage yet" {
  # Measurement only: a gate needs evidence it can trust, and this is what
  # collects it.
  run bash -c "awk '/^record_skills_used\(\) \{/,/^}/' bin/jc | grep -cE 'exit [1-9]|VERDICT|FAIL' || true"
  assert_output "0"
}

# ── Generated index (#50) ─────────────────────────────────────────────

@test "index: every skill on disk appears" {
  on_disk=$(find .jcode/skills -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')
  in_index=$(bin/skills-index | wc -l | tr -d ' ')
  [ "$on_disk" -eq "$in_index" ]
}

@test "index: entries are keyed by directory name, which is what loads" {
  run bin/skills-index --names
  assert_success
  assert_line "ui-ux-pro-max"
  assert_line "grill-me"
  # The three formerly divergent ones are published under their directory.
  assert_line "composition-patterns"
  assert_line "react-view-transitions"
  assert_line "taste-skill"
}

@test "index: no skill declares a frontmatter name differing from its directory" {
  # The index publishes the directory name. A mismatch means the skill
  # silently fails to load under the name it advertises — and a silent
  # failure is the worst mode, because the agent believes it is loaded.
  bad=0
  for md in .jcode/skills/*/SKILL.md; do
    dir=$(basename "$(dirname "$md")")
    declared=$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{exit} i' "$md" \
      | sed -n 's/^name:[[:space:]]*//p' | tr -d '"' | head -1)
    if [ -n "$declared" ] && [ "$declared" != "$dir" ]; then
      echo "mismatch: dir=$dir name=$declared"
      bad=$((bad + 1))
    fi
  done
  [ "$bad" -eq 0 ]
}

@test "index: it is a display, not a filter — nothing restricts the skills dir" {
  run bash -c "grep -cE 'rm |mv |chmod |ln -s' bin/skills-index || true"
  assert_output "0"
}

@test "index: the catalogue reaches the domain roles, not e2e" {
  run bash -c "awk '/Append the generated skill catalogue/,/esac/' bin/jc | grep -q 'triage | worker | reviewer'"
  assert_success
  # Check the case PATTERN, not the surrounding comment (which names e2e
  # precisely to explain the exclusion).
  run bash -c "awk '/Append the generated skill catalogue/,/esac/' bin/jc | grep -cE '^ +e2e\)' || true"
  assert_output "0"
}

@test "index: the agent is told the list is exhaustive and loadable mid-run" {
  run grep -q "exhaustive and every entry is loadable at any point" bin/jc
  assert_success
}

@test "index: an empty or missing skills directory is a no-op" {
  T=$(mktemp -d)
  run bin/skills-index --dir "$T/nope"
  assert_success
  assert_output ""
  rm -rf "$T"
}

# ── Audit (#41 extension) ─────────────────────────────────────────────

@test "audit: reports skill reachability" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k bash bin/doctor --audit
  assert_success
  assert_output --partial "skills are reachable"
}

@test "audit: flags skills missing a trigger or a verification section" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k bash bin/doctor --audit
  assert_success
  assert_output --partial "When to use"
  assert_output --partial "Verification"
}
