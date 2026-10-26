#!/usr/bin/env bash
# check-legacy-names.sh — no superseded skill, plugin or marketplace name may
# appear in the tracked tree outside the files that must still spell it (issue
# #612; the guard formerly inlined as section 4 of scripts/preflight.sh, and
# its gate 4 there).
#
# Run it from a repo root (or any directory inside one). Exit 0: every guarded
# name is confined to its sanctioned files. Exit 1: residue, or a guarded name
# with no allow list; each offender is named on stderr with its files. Exit 2:
# the scan itself could not run (not inside a git repo, or `git grep` failed),
# which is an error and never a pass. Subcommands read no repo and no network:
#   check-legacy-names.sh names        the guarded names, one per line
#   check-legacy-names.sh allow NAME   NAME's sanctioned paths, one per line
#                                      (a trailing / is a directory); exit 1
#                                      when NAME has no branch
# scripts/test-legacy-names.sh reads both emitters instead of carrying a copy.
#
# RENAME HISTORY. Every superseded name may appear only in the sanctioned
# backward-compat mentions: the ownership matchers still have to RECOGNISE
# artifacts produced under the older names, and those markers are committed
# inside every consumer repo. Anything else is a stale reference that would
# confuse a render or send a reader to a dead path.
#   The generator family (issue #120):
#     create-dev-workflows -> refresh-sassydog-skills (0.9.0)
#     refresh-sassydog-skills -> refresh-skills (2026.7.22)
#     refresh-skills -> setup-config (issue #121)
#     refresh-hooks -> setup-hooks (issue #122; the intermediate producer name
#       refresh-sassydog-hooks is sanctioned where hooks artifacts carry it)
#     refresh-deps  -> setup-deps  (issue #123; likewise refresh-sassydog-deps)
#   The plugin: ai-agent-skills -> sassy-dog, the marketplace sassy-dog-skills
#     -> skills (issue #71), and the GitHub repo ai-agent-skills -> skills
#     (issue #72).
#   The collection-scope naming sweep dropped -it: plate-it -> survey-work,
#     groom-it -> groom-backlog (nee fill-it), drain-it -> dispatch-ready,
#     clean-it -> tidy-repo.
#
# EXCLUSIONS ARE PER NAME, never one shared union (the #610 and #612 lesson): a
# name is sanctioned in exactly the files that must still spell it out. A union
# would let a stale `refresh-deps` hide in a file sanctioned only for
# `refresh-skills`, which is the residue this guard exists to catch. So every
# name has its own case branch with its own `git grep -l <name>`-measured list,
# even where two names list the same files, and the three refresh-sassydog-
# producer names are three names, never the bare prefix they share. A name in
# GUARDED_NAMES with no branch is reported (`no allow list for '<name>'`) and
# fails, and the later names are still checked.
#
# Every sanctioned list below also holds scripts/check-legacy-names.sh (this
# file spells the names) and, for the three producer names setup-config's
# recognizer must list, scripts/test-ownership-matchers.sh, which proves that
# list names each of them once.
#
# WHAT IS PINNED, by scripts/test-legacy-names.sh (each construct has a mutant
# there that keeps its message and must still be caught): a hit outside the
# allow list fails and names the offending name and file; a name sanctioned only
# for a different name fails; an unbranched name hits the default arm whether
# added first or last and does not stop the later names; a `git grep` that
# cannot run, and a directory that is not a repo, exit 2 and never read as clean.
#
# NOT COVERED, named so nothing claims more than it checks: a name deleted from
# GUARDED_NAMES (the gate reads this file's own list, so it cannot tell); the
# `cd "$root" || fatal` path (a repo root that cannot be entered; no case reaches
# it); an allow list WIDENED to make CI green (the gate proves the lists are
# enforced and per name, not that each is minimal; review the diff of this
# file); a hit in an untracked file (`git grep` reads tracked files only); and a
# legacy name written in a form the literal -F match misses (a case change, a
# split word).
#
# Portable bash 3.2 (macOS) through current: no associative arrays, no mapfile.
set -uo pipefail
export LC_ALL=C

GUARDED_NAMES=(
    'create-dev-workflows'
    'refresh-sassydog-skills'
    'refresh-sassydog-hooks'
    'refresh-sassydog-deps'
    'refresh-skills'
    'refresh-hooks'
    'refresh-deps'
    'ai-agent-skills'
    'sassy-dog-skills'
    'plate-it'
    'groom-it'
    'drain-it'
    'clean-it'
)

# legacy_allow NAME — sets ALLOW to NAME's sanctioned paths (a trailing / is a
# directory); returns 1 for a name with no branch.
legacy_allow() {
    ALLOW=()
    case "$1" in
        create-dev-workflows)
            # setup-config's marker recognizer and the adopt/update walkthrough
            # that names the original producer.
            ALLOW=(
                'skills/setup-config/SKILL.md'
                'skills/setup-config/references/update-mode.md'
                'scripts/test-ownership-matchers.sh'
                'scripts/check-legacy-names.sh'
            ) ;;
        refresh-sassydog-skills)
            # setup-config's recognizer, in both of the places it lists
            # producers (#414 turned this name into refresh-skills in both).
            ALLOW=(
                'skills/setup-config/SKILL.md'
                'skills/setup-config/references/update-mode.md'
                'scripts/test-ownership-matchers.sh'
                'scripts/check-legacy-names.sh'
            ) ;;
        refresh-sassydog-hooks)
            # setup-hooks' generated-by ownership matcher, plus the committed
            # consumer hook fixtures that carry it verbatim (issue #133).
            ALLOW=(
                'skills/setup-hooks/SKILL.md'
                'scripts/fixtures/legacy-markers/'
                'scripts/check-legacy-names.sh'
            ) ;;
        refresh-sassydog-deps)
            # setup-deps' generated-by ownership matcher.
            ALLOW=(
                'skills/setup-deps/SKILL.md'
                'scripts/check-legacy-names.sh'
            ) ;;
        refresh-skills)
            # setup-config's marker recognizer and the adopt/update walkthrough
            # that names the superseded producer.
            ALLOW=(
                'skills/setup-config/SKILL.md'
                'skills/setup-config/references/update-mode.md'
                'scripts/test-ownership-matchers.sh'
                'scripts/check-legacy-names.sh'
            ) ;;
        refresh-hooks)
            # setup-hooks' generated-by ownership matcher, plus the committed
            # consumer artifacts that PROVE the matcher still accepts this
            # producer name (issue #133: the fixtures are verbatim upstream
            # bytes; sanitising the name out of them would defeat their entire
            # purpose).
            ALLOW=(
                'skills/setup-hooks/SKILL.md'
                'scripts/fixtures/legacy-markers/'
                'scripts/check-legacy-names.sh'
            ) ;;
        refresh-deps)
            # setup-deps' generated-by ownership matcher + the committed
            # consumer artifacts proving the matcher accepts it (issue #133).
            ALLOW=(
                'skills/setup-deps/SKILL.md'
                'scripts/fixtures/legacy-markers/'
                'scripts/check-legacy-names.sh'
            ) ;;
        ai-agent-skills)
            # The old plugin name stays load-bearing in README.md (the one
            # historical line recording the #71 rename), in the setup-deps and
            # setup-hooks generated-by recognizers (their markers are committed
            # inside every consumer repo, so a narrower matcher would treat a
            # pre-rename consumer file as hand-written), and in the committed
            # consumer artifacts still stamped with the pre-rename namespace
            # (issue #133).
            ALLOW=(
                'README.md'
                'skills/setup-deps/SKILL.md'
                'skills/setup-hooks/SKILL.md'
                'scripts/fixtures/legacy-markers/'
                'scripts/check-legacy-names.sh'
            ) ;;
        sassy-dog-skills)
            # The old marketplace name appears only in README.md's one-time
            # re-add instructions (which must name it to remove it).
            ALLOW=(
                'README.md'
                'scripts/check-legacy-names.sh'
            ) ;;
        plate-it)
            # Legacy trigger phrases, the "Formerly" note and the
            # stranded-pre-rename-config detection in the renamed skill and
            # whats-on-fire's blind-spot probe; the setup-config rename map and
            # legacy-artifact recognition; README's "(formerly ...)" notes.
            ALLOW=(
                'README.md'
                'skills/survey-work/SKILL.md'
                'skills/whats-on-fire/SKILL.md'
                'skills/setup-config/SKILL.md'
                'skills/setup-config/references/migrate-mode.md'
                'skills/setup-config/references/update-mode.md'
                'scripts/check-legacy-names.sh'
            ) ;;
        groom-it)
            ALLOW=(
                'README.md'
                'skills/groom-backlog/SKILL.md'
                'skills/setup-config/references/migrate-mode.md'
                'skills/setup-config/references/update-mode.md'
                'scripts/check-legacy-names.sh'
            ) ;;
        drain-it)
            ALLOW=(
                'README.md'
                'skills/dispatch-ready/SKILL.md'
                'skills/setup-config/SKILL.md'
                'skills/setup-config/references/migrate-mode.md'
                'skills/setup-config/references/update-mode.md'
                'scripts/check-legacy-names.sh'
            ) ;;
        clean-it)
            ALLOW=(
                'README.md'
                'skills/tidy-repo/SKILL.md'
                'skills/setup-config/SKILL.md'
                'skills/setup-config/references/migrate-mode.md'
                'skills/setup-config/references/update-mode.md'
                'scripts/check-legacy-names.sh'
            ) ;;
        *) ALLOW=('scripts/check-legacy-names.sh'); return 1 ;;
    esac
}

status=0
note_status() { [ "$1" -gt "$status" ] && status="$1"; return 0; }
fatal() { echo "legacy-name guard — $1" >&2; exit 2; }

case "${1:-}" in
    names)
        printf '%s\n' "${GUARDED_NAMES[@]}"
        exit 0 ;;
    allow)
        [ "$#" -eq 2 ] || { echo "usage: check-legacy-names.sh allow NAME" >&2; exit 64; }
        legacy_allow "$2" || exit 1
        printf '%s\n' "${ALLOW[@]}"
        exit 0 ;;
    '') ;;
    *) echo "usage: check-legacy-names.sh [names | allow NAME]" >&2; exit 64 ;;
esac

root=$(git rev-parse --show-toplevel 2>/dev/null) || fatal "not inside a git repository; the scan could not run"
cd "$root" || fatal "cannot enter the repo root '$root'"

for name in "${GUARDED_NAMES[@]}"; do
    if ! legacy_allow "$name"; then
        echo "legacy-name guard — no allow list for '$name': give it its own case branch in scripts/check-legacy-names.sh" >&2
        note_status 1 # unbranched
        continue # later names are still checked
    fi
    specs=()
    for p in "${ALLOW[@]}"; do specs+=(":!$p"); done
    hits=$(git grep -l -F -e "$name" -- "${specs[@]}"); grc=$?
    case "$grc" in
        0)
            echo "legacy-name guard — '$name' outside the sanctioned back-compat files:" >&2
            printf '%s\n' "$hits" | sed 's/^/  /' >&2
            note_status 1 # residue
            ;;
        1) : ;;
        *)
            echo "legacy-name guard — git grep failed (exit $grc) while scanning '$name'; an error, never a pass" >&2
            note_status 2
            ;;
    esac
done
exit "$status"
