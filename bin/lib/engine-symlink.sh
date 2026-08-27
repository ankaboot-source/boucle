# bin/lib/engine-symlink.sh — portable target for the engine symlinks
#
# Sourcable bash library (no shebang). Source this file to define:
#   engine_symlink_target — the target `ln -s` should be given for a link
#
# THE BUG THIS EXISTS TO PREVENT
#
# LESSONS.yml, .jcode/skills/ and bin/ live under the engine dir (.boucle/)
# but agent prompts reference them at the consumer root, so bin/setup and
# bin/update symlink them up. Both computed the target as
# "<engine>/<path>" — correct when read from the repo root, and wrong the
# moment the link itself is not AT the repo root:
#
#   ln -s ".boucle/.jcode/skills" ".jcode/skills"
#
# `ln -s` resolves a relative target from the directory containing the LINK,
# not from the repo root. That link points at `.jcode/.boucle/.jcode/skills`,
# which does not exist. Two of the three links (LESSONS.yml, bin) sit at the
# root and worked; the skills one sits inside .jcode/ and never did.
#
# The failure is SILENT in the worst way: `ln -s` succeeds, `ls` shows the
# link, `git` records it, and only the skill load fails — the agent reports
# "skill not found", not "your symlink is wrong". The symlink was introduced
# precisely to fix skill loading, and the skills link was the one that stayed
# broken.
#
# The other half of the bug is the opposite failure. Both callers derive the
# engine dir with `$(cd ... && pwd)`, which is ABSOLUTE, so the link they
# write bakes one machine's checkout path into a VERSIONED symlink:
#
#   .jcode/skills -> /home/runner/work/<repo>/<repo>/.boucle/.jcode/skills
#
# That resolves on the runner that wrote it and dangles everywhere else — a
# contributor's laptop, a self-hosted runner, any other checkout path — and
# it churns the repo on every setup/update from a different directory.
#
# So: relative whenever the engine is inside the consumer root (portable,
# stable across machines), with the right number of "../" for the link's own
# depth; absolute only when the engine genuinely lives outside it, where no
# relative path exists.

# engine_symlink_target <engine_dir> <link_path> [consumer_root]
#
#   engine_dir     path to the engine (absolute or relative)
#   link_path      the link to create, relative to the consumer root
#                  (e.g. "LESSONS.yml", ".jcode/skills", "bin")
#   consumer_root  defaults to $PWD
#
# Prints the target to hand to `ln -s`.
#
#   engine_symlink_target /repo/.boucle LESSONS.yml   /repo  -> .boucle/LESSONS.yml
#   engine_symlink_target /repo/.boucle .jcode/skills /repo  -> ../.boucle/.jcode/skills
#   engine_symlink_target /elsewhere/eng .jcode/skills /repo -> /elsewhere/eng/.jcode/skills
#
# Returns 1 and prints nothing when the engine IS the consumer root (the
# dogfood layout): the target already lives where the link would go, so the
# only link that could be written points at itself. Callers must skip on a
# non-zero return rather than create that loop.
engine_symlink_target() {
  local engine_dir="$1" link_path="$2" root="${3:-$PWD}"
  local engine_rel="$engine_dir"

  # Make the engine path relative to the consumer root when it is inside it.
  case "$engine_dir" in
    "$root" | ".")
      # Dogfood: engine == consumer root. Nothing to link.
      return 1
      ;;
    "$root"/*)
      engine_rel="${engine_dir#"$root"/}"
      ;;
    /*)
      # Absolute and outside the consumer root: no relative path exists, so
      # keep it absolute and skip the ../ prefixing below.
      printf '%s\n' "$engine_dir/$link_path"
      return 0
      ;;
  esac

  # One "../" per directory level the LINK sits below the consumer root.
  # A root-level link gets none.
  local up="" dir
  dir=$(dirname "$link_path")
  while [ -n "$dir" ] && [ "$dir" != "." ] && [ "$dir" != "/" ]; do
    up="../$up"
    dir=$(dirname "$dir")
  done

  printf '%s\n' "${up}${engine_rel}/${link_path}"
}
