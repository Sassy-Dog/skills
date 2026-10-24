#!/usr/bin/env bash
# align-labels.sh — the canonical home of the ENGINEERING-DIMENSION + SEVERITY
# label taxonomy. The 14 labels, their colours and their descriptions are
# defined in the CANONICAL_LABELS table below, nowhere else. Point it at a repo
# and it creates what is missing and corrects what has drifted.
#
# TWO LABEL TAXONOMIES LIVE IN THIS PLUGIN. THEY ARE DISJOINT BY DESIGN — do
# NOT "unify" them:
#
#   1. This script — engineering dimensions + severity. Ambient classification:
#      what an issue is ABOUT and how bad it is. Long-lived, repo-wide, applied
#      by humans and by assess-it. assess-it INVOKES this script against the
#      repo it is auditing (skills/assess-it/SKILL.md phase 4); it used to carry
#      its own transcription of the table, which froze at the pre-#158 colours
#      and re-created the very collision #158 removed, in every repo it audited
#      (issue #167). A consumer of this taxonomy runs this script or reads
#      `taxonomy` — it never copies the rows.
#   2. skills/github-issues/scripts/issue-claim.sh (plus the --ensure-label of
#      file-or-link-issue.sh) — the dev-workflow STATE labels `ready`,
#      `in-progress`, `blocked`, `sentry-escalation`. Those are ensure-created
#      at the moment of the state transition that needs them, with canonical
#      colour and description, and MUST NOT appear in the table below: two
#      definitions of one label is exactly the drift both scripts exist to
#      prevent. RESERVED_LABELS asserts it at startup rather than trusting the
#      next editor to remember.
#
# Dependabot's per-ecosystem labels (`javascript`, `github_actions`, `rust`,
# `dart`, …) are auto-created and correctly differ per repo. Not our business.
#
# SCOPE — two passes, and only one of them can ever destroy anything:
#
#   ALIGN (the default pass). Ensures the canonical labels EXIST with canonical
#   definitions. It never deletes a label and never touches an issue.
#
#   MIGRATE (--migrate <file>, issue #163). Folds a repo's one-off labels onto
#   the canonical set: add the new label to every issue carrying the old one,
#   then delete the old label. Deleting a label strips it from every issue
#   carrying it, UNRECOVERABLY — so relabel comes first, delete second, and
#   that ordering is enforced structurally rather than by convention. See THE
#   DELETE GATE below. Mappings are data (a file), never a flag per mapping.
#
# THE DELETE GATE. `gh label delete` has exactly ONE call site in this script:
# inside migrate_delete_gate(). That function's own body issues a FRESH
# `gh issue list` for the old label and returns without deleting on every path
# that is not "zero issues still carry the old label without the new one". The
# relabel loop's counters are not an input to it and are never consulted — the
# migration's own success message is not evidence. A delete is therefore
# unreachable except through a re-query performed immediately before it, in the
# same function body, so a `set -e` gap, a stray `|| true`, or a reordering
# elsewhere in the script cannot route around it. scripts/test-label-migrate.sh
# asserts that single-call-site invariant against this file's source, and
# proves the gate is load-bearing by neutering it and watching the withheld
# delete fire.
#
# What migrate mode deliberately does NOT do:
#   * delete a label that has no mapping. Every delete here is the tail of a
#     verified relabel; a label with no target has signal to lose and no
#     evidence to gate on, so it stays a human decision (issue #159).
#   * relabel pull requests. The migration is about issue signal and
#     `gh issue list` excludes PRs, so a PR carrying a migrated-away label
#     loses it when the label is deleted. Known, accepted, and small.
#   * create a target label. A mapping whose TARGET is absent from the repo is
#     held back rather than invented — run the align pass first.
#
# Usage:
#   align-labels.sh [--repo owner/name] [--dry-run | --check | --collisions]
#   align-labels.sh [--repo owner/name] --migrate <file> [--dry-run]
#   align-labels.sh taxonomy
#
#   taxonomy     print the table as `name|color|description` lines and exit.
#                Needs no gh, no jq and no repo: it is how OTHER tools read this
#                taxonomy without forking a second copy of the values — the
#                mirror of issue-claim.sh's `taxonomy`, which this script's
#                cross-set check already consumes (issue #167).
#   --repo       target repo; defaults to the current repo via `gh repo view`.
#   --dry-run    preview: report what would change, write nothing. Exit 0.
#   --check      drift report: same read-only pass, but exit 3 when the repo is
#                out of alignment — the gateable form for an audit sweep. Also
#                runs the cross-set colour check below.
#   --collisions cross-set colour check ONLY. Compares this table against the
#                dev-workflow taxonomy and exits 3 if any pair is closer than
#                CROSS_SET_MIN_DE. Definitions only: no repo, no gh, no
#                network — the form scripts/preflight.sh gates CI on.
#   --migrate    run the MIGRATE pass over the old -> new mappings in <file>
#                ("-" reads stdin). Mutually exclusive with --check and
#                --collisions. Combine with --dry-run for a full preview.
#
# Mapping file format — one mapping per line, `<repo>|<old>|<new>`:
#
#     # comments and blank lines are ignored; field whitespace is trimmed
#     Sassy-Dog/velovate|priority:p1|sev:critical
#     Sassy-Dog/qr-ninja|supply-chain|security
#
#   One file describes the whole plan and each run processes only the lines
#   whose repo matches the resolved --repo, so the same file drives all 14
#   repos. The WHOLE file is validated before any network call: a mapping
#   touching a reserved dev-workflow label, a duplicated source, a chained
#   mapping (a -> b alongside b -> c in one repo, where the result depends on
#   evaluation order), old == new, or a malformed line each exit 64.
#
# Env: DRY_RUN=1 equivalent to --dry-run. REPO honored if --repo absent.
#      ISSUE_LIMIT overrides the per-mapping issue-read ceiling (default 1000).
#
# Output: one JSON line per canonical label on stdout for the align pass:
#   {"label":"security","action":"ok|create|update|would-create|would-update|failed","detail":"..."}
# and one JSON line per mapping for the migrate pass:
#   {"mapping":"old -> new","old":"..","new":"..","relabeled":N,
#    "action":"migrated|would-migrate|already-migrated|held-back|blocked|failed","detail":"..."}
# Human-readable summary goes to stderr.
#
# Exit codes:
#   0  — aligned (or applied successfully, or --dry-run preview)
#   1  — missing tooling (gh/jq), no repo, or the label read failed
#   2  — at least one write failed (the pass CONTINUES past failures)
#   3  — --check: drift found (nothing was written), or a cross-set colour
#        collision; --collisions: a cross-set colour collision
#   4  — --migrate: at least one mapping was HELD BACK — its old label was not
#        deleted. Outranks 2, because a partial relabel usually produces both
#        and the withheld delete is the outcome an operator must act on; the
#        failing writes are still listed on stderr and in the JSON either way.
#   64 — usage error, or an invalid mapping file (refused before any network
#        call)
#
# Idempotent by construction: a second align run against an aligned repo finds
# every label already matching and issues no gh write at all, and a second
# migrate run finds every old label already gone and issues none either.
#
# COLOURS ARE LORE — three sit deliberately off their modal palette value so
# chips stay distinguishable, and re-"tidying" them reintroduces a collision:
#   security  ee0701  (was identical to sev:critical)
#   tech-debt c5def5  (was identical to sev:medium)
#   epic      3e4b9e  (was identical to sev:low AND to ready)
# `infra` joined the set in 2026-08 and its colour was picked by measurement,
# not by eye: 5f4811 is the maximum-separation point of a 1,440-colour sweep,
# min ΔE2000 = 28.9 against every label that can share a chip row with it (the
# other 13 canonical labels, the four dev-workflow labels above, and GitHub's
# default set) — versus 5.3 for the tightest pair already inside the canonical
# set. It must NOT reuse c5def5, the colour the pre-canonical `infra` carried
# in three repos, because that is tech-debt's.
#
# EACH TAXONOMY USED TO VALIDATE ONLY AGAINST ITSELF, and four cross-set pairs
# sat at ΔE2000 = 0 as a result (issue #161): ready/sev:low,
# in-progress/architecture, blocked/sev:critical and
# sentry-escalation/sev:critical each shared a hex exactly, while every
# dispatchable issue carries one label from each set. The dev-workflow side
# moved; `--collisions` is what stops it happening again, and it reads the
# other taxonomy from its owner (`issue-claim.sh taxonomy`) rather than
# carrying a copy of it — a copy is the fork this split exists to prevent.

set -uo pipefail

# --- the canonical taxonomy: name|color|description --------------------------
# 10 engineering dimensions + 4 severities. Data, not scattered literals: every
# consumer of the taxonomy reads this table.
#
# `site:<name>` IS DELIBERATELY NOT IN HERE, and must not be added. The
# execution-site labels `queue-snapshot.sh` reads (issue #340, epic #322) are an
# open-ended PER-REPO convention — whatever workstations a repo's work runs on —
# while every row below is a fixed set this org applies everywhere. The harm is
# the ALIGN pass's, not migrate's: this table is the set of labels that must
# EXIST in every repo, so enumerating `site:mac` here would create it in every
# repo that has no VDI and no laptop, and `--check` would then report every such
# repo as non-conformant for not carrying a site it has never had. There is no
# correct row to write, because the members differ per repo — which is the
# distinction CLAUDE.md's "a consumer runs the owner or reads its `taxonomy`
# emitter" rule turns on: that rule is about THIS table's members, and `site:*`
# has none to transcribe.
CANONICAL_LABELS=(
    "architecture|1d76db|Architecture & structure"
    "assessment|5319e7|Filed by assess-it"
    "ci-cd|006b75|CI/CD & release"
    "dx|bfdadc|Developer experience"
    "epic|3e4b9e|Tracking epic"
    "infra|5f4811|Infrastructure & platform"
    "observability|fef2c0|Observability & ops"
    "security|ee0701|Security / supply chain"
    "tech-debt|c5def5|Technical debt"
    "testing|0052cc|Testing & quality"
    "sev:critical|b60205|Critical severity"
    "sev:high|d93f0b|High severity"
    "sev:medium|fbca04|Medium severity"
    "sev:low|0e8a16|Low severity"
)

# Owned by the OTHER taxonomy (issue-claim.sh / file-or-link-issue.sh). Adding
# any of these to the table above forks a single source of truth in two.
RESERVED_LABELS=(ready in-progress blocked sentry-escalation)

# Two chips from different taxonomies must never be closer than this. Exact-hex
# (ΔE 0) is what #161 found; 10 is the gate. It is deliberately stricter than
# the 5.3 the canonical set tolerates INTERNALLY (security / sev:high) because
# a cross-set pair co-occurs by construction — every dispatchable issue carries
# a dev-workflow state AND a dimension — whereas two canonical labels sharing
# one issue is optional. The shipped sets measure 24.4 apart at their tightest.
CROSS_SET_MIN_DE=10

# Per-mapping issue-read ceiling for the migrate pass. A TRUNCATED read would
# UNDERCOUNT the issues still carrying the old label, and an undercount is
# exactly what would let a delete through the gate — so hitting the ceiling is
# treated as a failed read, never as "nothing left".
ISSUE_LIMIT="${ISSUE_LIMIT:-1000}"

usage() {
    cat >&2 <<'EOF'
usage: align-labels.sh [--repo owner/name] [--dry-run | --check | --collisions]
       align-labels.sh [--repo owner/name] --migrate <file> [--dry-run]
       align-labels.sh taxonomy
       taxonomy     print `name|color|description` per canonical label and exit
       --dry-run    preview only, never writes, always exit 0
       --check      read-only drift report, exit 3 if the repo is out of alignment
       --collisions cross-set colour check only (no repo, no network), exit 3 on a hit
       --migrate    relabel-then-delete over the old|new mappings in <file>
                    ("-" reads stdin); one `<repo>|<old>|<new>` per line
EOF
    exit 64
}

print_taxonomy() { printf '%s\n' "${CANONICAL_LABELS[@]}"; }

# Data only: no tooling, no repo, no network. Kept ahead of every check below
# so a consumer can read the taxonomy from a bare checkout — the same contract
# as issue-claim.sh's `taxonomy`, which this script's own cross-set check
# consumes. A consumer that needs the table as DATA reads it here; one that
# needs it APPLIED runs the align pass. Neither one transcribes it (issue #167).
if [[ "${1:-}" == "taxonomy" ]]; then
    if [[ $# -ne 1 ]]; then
        echo "align-labels: taxonomy takes no other arguments" >&2
        usage
    fi
    print_taxonomy
    exit 0
fi

REPO="${REPO:-}"
dry_run="${DRY_RUN:-0}"
check_only=0
collisions_only=0
migrate_file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)       REPO="$2"; shift 2 ;;
        --dry-run)    dry_run=1; shift ;;
        --check)      check_only=1; dry_run=1; shift ;;
        --collisions) collisions_only=1; shift ;;
        --migrate)
            [[ $# -ge 2 ]] || { echo "align-labels: --migrate needs a mapping file" >&2; usage; }
            migrate_file="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "align-labels: unknown arg: $1" >&2; usage ;;
    esac
done

if [[ -n "$migrate_file" && ( "$check_only" == "1" || "$collisions_only" == "1" ) ]]; then
    echo "align-labels: --migrate cannot be combined with --check or --collisions" >&2
    usage
fi

# Guardrail, enforced rather than documented: the dev-workflow labels are not
# ours to define.
for spec in "${CANONICAL_LABELS[@]}"; do
    for reserved in "${RESERVED_LABELS[@]}"; do
        if [[ "${spec%%|*}" == "$reserved" ]]; then
            echo "align-labels: '$reserved' belongs to the dev-workflow taxonomy owned by" >&2
            echo "  skills/github-issues/scripts/issue-claim.sh — remove it from CANONICAL_LABELS." >&2
            echo "  Two homes for one label is the drift this script exists to prevent." >&2
            exit 64
        fi
    done
done

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# --- the migration plan: parsed and fully validated BEFORE any network call ---
# `<repo>|<old>|<new>` per line. Everything that can be judged from the file
# alone is judged here, at startup, so a bad plan costs zero writes: a mapping
# is either refused before the first `gh` invocation or it is safe to attempt.
#
# The reserved check covers EVERY line, not just this repo's. A dev-workflow
# label in any line of the plan is a bug in the plan, and finding it only when
# the run reaches that repo is finding it after 13 other repos have been
# mutated.
MIGRATE_SPECS=()
map_reject() {  # $1=line number, $2=reason
    echo "align-labels: mapping file $migrate_file line $1: $2" >&2
    exit 64
}

parse_migrate_map() {
    local file="$1" line lineno=0 repo old new extra key
    local sources="" targets="" reserved

    [[ "$file" == "-" ]] && file="/dev/stdin"
    if [[ ! -r "$file" ]]; then
        echo "align-labels: cannot read mapping file: $migrate_file" >&2
        exit 64
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        line="${line%"${line##*[![:space:]]}"}"   # rtrim
        [[ -z "$line" ]] && continue
        [[ "${line:0:1}" == "#" ]] && continue

        IFS='|' read -r repo old new extra <<<"$line"
        [[ -n "$extra" ]] && map_reject "$lineno" "expected 3 fields (<repo>|<old>|<new>), got more"
        repo="${repo#"${repo%%[![:space:]]*}"}"; repo="${repo%"${repo##*[![:space:]]}"}"
        old="${old#"${old%%[![:space:]]*}"}";    old="${old%"${old##*[![:space:]]}"}"
        new="${new#"${new%%[![:space:]]*}"}";    new="${new%"${new##*[![:space:]]}"}"

        [[ -z "$repo" || -z "$old" || -z "$new" ]] &&
            map_reject "$lineno" "expected 3 non-empty fields (<repo>|<old>|<new>), got: $line"
        [[ "$repo" == */* ]] ||
            map_reject "$lineno" "'$repo' is not an owner/name repo slug"
        [[ "$(lower "$old")" == "$(lower "$new")" ]] &&
            map_reject "$lineno" "old and new are the same label ('$old')"

        for reserved in "${RESERVED_LABELS[@]}"; do
            if [[ "$(lower "$old")" == "$reserved" || "$(lower "$new")" == "$reserved" ]]; then
                echo "align-labels: mapping file $migrate_file line $lineno: '$reserved' belongs to the" >&2
                echo "  dev-workflow taxonomy owned by skills/github-issues/scripts/issue-claim.sh." >&2
                echo "  The two taxonomies are disjoint and single-sourced: migrating a label into or" >&2
                echo "  out of that set is not this script's to do. Refused before any network call." >&2
                exit 64
            fi
        done

        key="$(lower "$repo")|$(lower "$old")"
        if grep -Fqx "$key" <<<"$sources"; then
            map_reject "$lineno" "'$old' is already mapped for $repo — one source, one target"
        fi
        sources+="$key"$'\n'
        targets+="$(lower "$repo")|$(lower "$new")"$'\n'
        MIGRATE_SPECS+=("$repo|$old|$new")
    done <"$file"

    # Chained mappings (a -> b alongside b -> c in one repo) make the outcome
    # depend on evaluation order, and one of the two deletes would run against
    # a label the other still needs. Refuse the plan rather than pick an order.
    local spec s_repo s_old s_new
    [[ "${#MIGRATE_SPECS[@]}" -eq 0 ]] && return 0
    for spec in "${MIGRATE_SPECS[@]}"; do
        IFS='|' read -r s_repo s_old s_new <<<"$spec"
        if grep -Fqx "$(lower "$s_repo")|$(lower "$s_new")" <<<"$sources"; then
            echo "align-labels: mapping file $migrate_file: chained mapping in $s_repo — '$s_old' -> '$s_new'" >&2
            echo "  while '$s_new' is itself mapped away. The result would depend on evaluation order." >&2
            exit 64
        fi
        if grep -Fqx "$(lower "$s_repo")|$(lower "$s_old")" <<<"$targets"; then
            echo "align-labels: mapping file $migrate_file: chained mapping in $s_repo — '$s_old' is both a" >&2
            echo "  migration source and another mapping's target. The result would depend on order." >&2
            exit 64
        fi
    done
}

if [[ -n "$migrate_file" ]]; then
    parse_migrate_map "$migrate_file"
    if [[ "${#MIGRATE_SPECS[@]}" -eq 0 ]]; then
        echo "align-labels: mapping file $migrate_file contains no mappings" >&2
        exit 64
    fi
fi

# Paths are resolved relative to this script so they hold wherever the plugin
# is installed. Hoisted above the tooling checks because --collisions needs the
# dev-workflow source and nothing else.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVWORKFLOW_SOURCE="$SCRIPT_DIR/../skills/github-issues/scripts/issue-claim.sh"

# --- cross-set colour collision check (issue #161) ---------------------------
# Reads the OTHER taxonomy from its owner instead of copying it: `issue-claim.sh
# taxonomy` emits `name|color|description` and needs no gh, jq or repo. One awk
# pass scores every (dev-workflow x canonical) pair with CIEDE2000 — the same
# metric #158 used to pick `infra` — and reports the pairs below the threshold
# plus the tightest pair overall.
#
# Sets CROSS_SET_REPORT (human-readable — the offending pairs, or the tightest
# pair and its ΔE when clear). Returns 0 clear, 1 collision, 2 the dev-workflow
# taxonomy could not be read — which is reported, never treated as "no
# collisions".
CROSS_SET_REPORT=""
cross_set_check() {
    local dw pairs="" dname dcolor cname ccolor rest spec out
    CROSS_SET_REPORT=""

    if [[ ! -f "$DEVWORKFLOW_SOURCE" ]]; then
        CROSS_SET_REPORT="dev-workflow taxonomy not found at $DEVWORKFLOW_SOURCE"
        return 2
    fi
    if ! dw=$(bash "$DEVWORKFLOW_SOURCE" taxonomy 2>/dev/null) || [[ -z "$dw" ]]; then
        CROSS_SET_REPORT="could not read the dev-workflow taxonomy ($DEVWORKFLOW_SOURCE taxonomy)"
        return 2
    fi

    while IFS='|' read -r dname dcolor _; do
        [[ -z "$dname" ]] && continue
        for spec in "${CANONICAL_LABELS[@]}"; do
            cname="${spec%%|*}"
            rest="${spec#*|}"
            ccolor="${rest%%|*}"
            pairs+="$dname $dcolor $cname $ccolor"$'\n'
        done
    done <<<"$dw"

    # CIEDE2000 in awk: POSIX operators only (^ atan2 sin cos exp sqrt), so it
    # runs under BWK awk, mawk and gawk alike. Validated against a reference
    # implementation over 4,400 colour pairs (max abs error 5e-5).
    out=$(printf '%s' "$pairs" | awk -v thr="$CROSS_SET_MIN_DE" '
function hex2dec(s,   i, v, d) {
    s = tolower(s); v = 0
    for (i = 1; i <= length(s); i++) {
        d = index("0123456789abcdef", substr(s, i, 1)) - 1
        if (d < 0) return -1
        v = v * 16 + d
    }
    return v
}
function inv(c) { return (c > 0.04045) ? ((c + 0.055) / 1.055) ^ 2.4 : c / 12.92 }
function fx(t)  { return (t > 0.008856451679) ? t ^ (1.0 / 3.0) : 7.787037037 * t + 0.137931034 }
function lab(hex, out,   r, g, b, x, y, z) {
    r = inv(hex2dec(substr(hex, 1, 2)) / 255.0)
    g = inv(hex2dec(substr(hex, 3, 2)) / 255.0)
    b = inv(hex2dec(substr(hex, 5, 2)) / 255.0)
    x = (r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047
    y = (r * 0.2126729 + g * 0.7151522 + b * 0.0721750)
    z = (r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883
    out[0] = 116 * fx(y) - 16
    out[1] = 500 * (fx(x) - fx(y))
    out[2] = 200 * (fx(y) - fx(z))
}
function deg(r) { return r * 57.29577951308232 }
function rad(d) { return d * 0.01745329251994330 }
function mod360(d) { d = d % 360; return (d < 0) ? d + 360 : d }
function de2000(p, q,   L1,a1,b1,L2,a2,b2,C1,C2,Cb,G,a1p,a2p,C1p,C2p,h1p,h2p,
                        dLp,dCp,dhp,dHp,Lb,Cbp,hbp,T,dth,Rc,Sl,Sc,Sh,Rt,A,B) {
    lab(p, A); lab(q, B)
    L1 = A[0]; a1 = A[1]; b1 = A[2]
    L2 = B[0]; a2 = B[1]; b2 = B[2]
    C1 = sqrt(a1 * a1 + b1 * b1); C2 = sqrt(a2 * a2 + b2 * b2)
    Cb = (C1 + C2) / 2
    G = 0.5 * (1 - sqrt(Cb ^ 7 / (Cb ^ 7 + 6103515625)))
    a1p = (1 + G) * a1; a2p = (1 + G) * a2
    C1p = sqrt(a1p * a1p + b1 * b1); C2p = sqrt(a2p * a2p + b2 * b2)
    h1p = (a1p == 0 && b1 == 0) ? 0 : mod360(deg(atan2(b1, a1p)))
    h2p = (a2p == 0 && b2 == 0) ? 0 : mod360(deg(atan2(b2, a2p)))
    dLp = L2 - L1
    dCp = C2p - C1p
    if (C1p * C2p == 0)          dhp = 0
    else if ((h2p - h1p) > 180)  dhp = h2p - h1p - 360
    else if ((h2p - h1p) < -180) dhp = h2p - h1p + 360
    else                         dhp = h2p - h1p
    dHp = 2 * sqrt(C1p * C2p) * sin(rad(dhp) / 2)
    Lb = (L1 + L2) / 2
    Cbp = (C1p + C2p) / 2
    if (C1p * C2p == 0)                                   hbp = h1p + h2p
    else if (((h1p - h2p) < 180) && ((h1p - h2p) > -180)) hbp = (h1p + h2p) / 2
    else if ((h1p + h2p) < 360)                           hbp = (h1p + h2p + 360) / 2
    else                                                  hbp = (h1p + h2p - 360) / 2
    T = 1 - 0.17 * cos(rad(hbp - 30)) + 0.24 * cos(rad(2 * hbp)) \
          + 0.32 * cos(rad(3 * hbp + 6)) - 0.20 * cos(rad(4 * hbp - 63))
    dth = 30 * exp(-(((hbp - 275) / 25) ^ 2))
    Rc = 2 * sqrt(Cbp ^ 7 / (Cbp ^ 7 + 6103515625))
    Sl = 1 + (0.015 * (Lb - 50) ^ 2) / sqrt(20 + (Lb - 50) ^ 2)
    Sc = 1 + 0.045 * Cbp
    Sh = 1 + 0.015 * Cbp * T
    Rt = -sin(rad(2 * dth)) * Rc
    return sqrt((dLp / Sl) ^ 2 + (dCp / Sc) ^ 2 + (dHp / Sh) ^ 2 \
                + Rt * (dCp / Sc) * (dHp / Sh))
}
NF == 4 {
    d = de2000($2, $4)
    if (min == "" || d < min) { min = d; mp = sprintf("%s %s / %s %s", $1, $2, $3, $4) }
    if (d < thr) printf "HIT %.2f %s (%s) vs %s (%s)\n", d, $1, $2, $3, $4
}
END { printf "MIN %.2f %s\n", min, mp }
')

    local hits
    hits=$(echo "$out" | grep '^HIT ' | sed 's/^HIT /  dE2000 /')
    if [[ -n "$hits" ]]; then
        CROSS_SET_REPORT="$hits"
        return 1
    fi
    CROSS_SET_REPORT="$(echo "$out" | sed -n 's/^MIN \([0-9.]*\) \(.*\)/tightest cross-set pair: dE2000 \1 — \2/p')"
    return 0
}

# --collisions: definitions only. Runs before every tooling and repo check
# because it needs none of them.
if [[ "$collisions_only" == "1" ]]; then
    cross_set_rc=0
    cross_set_check || cross_set_rc=$?
    case "$cross_set_rc" in
        0)
            echo "align-labels: cross-set colours clear (threshold dE2000 >= $CROSS_SET_MIN_DE) — $CROSS_SET_REPORT" >&2
            exit 0 ;;
        1)
            echo "align-labels: CROSS-SET COLOUR COLLISION — a dev-workflow label and a canonical" >&2
            echo "  label are closer than dE2000 $CROSS_SET_MIN_DE. Every dispatchable issue carries one of each," >&2
            echo "  so these chips are hard to tell apart (issue #161):" >&2
            echo "$CROSS_SET_REPORT" >&2
            echo "  Move the dev-workflow side (issue-claim.sh) — the canonical palette and its" >&2
            echo "  conventional severity coding stay put." >&2
            exit 3 ;;
        *)
            echo "align-labels: cross-set colour check COULD NOT RUN — $CROSS_SET_REPORT" >&2
            exit 3 ;;
    esac
fi

# Every pass runs the check. It gates only --check (exit 3, alongside drift);
# an apply or a dry-run reports it loudly and continues, because a definition
# collision is a plugin bug and refusing to align a repo's labels would not fix
# it. It is never silent in any mode.
cross_set_rc=0
cross_set_check || cross_set_rc=$?
if [[ "$cross_set_rc" == "1" ]]; then
    echo "align-labels: CROSS-SET COLOUR COLLISION (issue #161) — these pairs are closer than dE2000 $CROSS_SET_MIN_DE:" >&2
    echo "$CROSS_SET_REPORT" >&2
elif [[ "$cross_set_rc" != "0" ]]; then
    echo "align-labels: cross-set colour check COULD NOT RUN — $CROSS_SET_REPORT" >&2
fi

command -v gh >/dev/null || { echo "align-labels: gh CLI not on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "align-labels: jq not on PATH" >&2; exit 1; }
[[ -z "$REPO" ]] && REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
[[ -z "$REPO" ]] && { echo "align-labels: not in a GitHub repo and --repo not given" >&2; exit 1; }

# Mutations go through pr-shepherd's gh-retry.sh when available (pr-shepherd is
# the script root for the whole plugin).
GH_RETRY="$SCRIPT_DIR/../skills/pr-shepherd/scripts/gh-retry.sh"
if [[ -f "$GH_RETRY" ]]; then
    ghw() { bash "$GH_RETRY" -- "$@"; }
else
    ghw() { gh "$@"; }
fi

# One read for the whole pass. The --limit truncation trap: a repo silently
# capped at the limit would make present labels look absent, so ask for more
# than any repo carries and shout if we ever hit the ceiling.
LIMIT=300
if ! existing=$(gh label list --repo "$REPO" --limit "$LIMIT" --json name,color,description 2>/dev/null); then
    echo "align-labels: could not read labels from $REPO (missing repo, or no access?)" >&2
    exit 1
fi
if ! label_count=$(jq 'length' <<<"$existing" 2>/dev/null); then
    echo "align-labels: unexpected label payload from $REPO" >&2
    exit 1
fi
if [[ "$label_count" -ge "$LIMIT" ]]; then
    echo "align-labels: $REPO returned $label_count labels — at the --limit ceiling; raise LIMIT" >&2
    exit 1
fi

emit() {  # $1=label $2=action $3=detail
    jq -cn --arg l "$1" --arg a "$2" --arg d "$3" '{label:$l, action:$a, detail:$d}'
}

emit_map() {  # $1=old $2=new $3=action $4=relabeled-count $5=detail
    jq -cn --arg o "$1" --arg n "$2" --arg a "$3" --argjson r "$4" --arg d "$5" \
        '{mapping: ($o + " -> " + $n), old: $o, new: $n, relabeled: $r, action: $a, detail: $d}'
}

# The exact stored name of label $1 in $REPO (GitHub label names are
# case-insensitive for uniqueness but case-preserving on the wire), or empty
# when the repo does not carry it. Read from the one label list this pass
# already made.
label_actual() {
    jq -r --arg n "$1" \
        'map(select((.name | ascii_downcase) == ($n | ascii_downcase)))[0].name // empty' \
        <<<"$existing"
}

# Issue numbers in $REPO carrying $1 but NOT $2, one per line, empty when none.
# `--state all` deliberately: deleting a label strips it from closed issues
# too, so a closed issue's signal is just as lost as an open one's.
#
# Returns 1 when the read failed, 2 when it hit ISSUE_LIMIT. Both are failures
# and the ceiling especially so — a truncated list is a SHORTER list, and a
# shorter list is exactly what a delete gate would misread as progress.
migrate_unmigrated_issues() {
    local old="$1" new="$2" payload n
    payload=$(gh issue list --repo "$REPO" --label "$old" --state all \
        --limit "$ISSUE_LIMIT" --json number,labels 2>/dev/null) || return 1
    n=$(jq 'length' <<<"$payload" 2>/dev/null) || return 1
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    [[ "$n" -ge "$ISSUE_LIMIT" ]] && return 2
    jq -r --arg new "$new" \
        '.[] | select([.labels[].name] | index($new) | not) | .number' <<<"$payload" 2>/dev/null
}

# ==============================================================================
#  THE DELETE GATE — the only call site of `gh label delete` in this script.
# ==============================================================================
# Relabel first, delete second is not a comment here, it is the control flow.
# Every path into a label deletion runs through this function, and this
# function's FIRST substantive act is a fresh re-query of the repo. The relabel
# loop's counters are not a parameter and are never read: the migration's own
# success message is not evidence. Every non-zero return leaves the old label
# in place, and "the re-query itself failed" is one of them — unknown is not
# verified.
#
# Returns: 0 verified and deleted · 10 re-query failed · 12 relabel incomplete
#          13 verified but the delete call failed · 20 reached during a dry run
GATE_DETAIL=""
migrate_delete_gate() {
    local old="$1" new="$2" still err n rc=0
    GATE_DETAIL=""

    # Asserted, not assumed: a preview must never reach the one place that can
    # delete a label. The migrate loop also skips the gate entirely in dry-run.
    if [[ "$dry_run" == "1" ]]; then
        GATE_DETAIL="INTERNAL: delete gate reached during a dry run — refused"
        return 20
    fi

    still=$(migrate_unmigrated_issues "$old" "$new") || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        GATE_DETAIL="post-relabel re-query failed (rc=$rc) — NOT verified, delete withheld"
        return 10
    fi
    if [[ -n "$still" ]]; then
        n=$(printf '%s\n' "$still" | wc -l | tr -d ' ')
        GATE_DETAIL="re-query found $n issue(s) still carrying '$old' without '$new' — RELABEL INCOMPLETE, delete withheld"
        return 12
    fi

    # The single call site. scripts/test-label-migrate.sh counts the literal
    # phrase below across every non-comment line of this file and requires the
    # count to be 1 and to sit inside this function — so keep that phrase out
    # of message strings, and put any new deletion behind this gate.
    if err=$(ghw label delete "$old" --repo "$REPO" --yes 2>&1 >/dev/null); then
        GATE_DETAIL="re-query verified 0 issues still carrying '$old'; the label was removed"
        return 0
    fi
    GATE_DETAIL="verified, but removing '$old' failed: $(printf '%s' "$err" | grep -v '^\[gh-retry\]' | head -1)"
    return 13
}

# --- the migrate pass ---------------------------------------------------------
if [[ -n "$migrate_file" ]]; then
    n_considered=0
    n_migrated=0
    n_already=0
    n_would=0
    n_relabeled=0
    n_write_failed=0
    n_held=0
    HELD=""

    hold() {  # $1=old $2=new $3=reason
        HELD+="  $1 -> $2: $3"$'\n'
        n_held=$((n_held + 1))
    }

    for spec in "${MIGRATE_SPECS[@]}"; do
        IFS='|' read -r m_repo old new <<<"$spec"
        [[ "$(lower "$m_repo")" == "$(lower "$REPO")" ]] || continue
        n_considered=$((n_considered + 1))

        old_actual=$(label_actual "$old")
        new_actual=$(label_actual "$new")

        # Already migrated: the old label is gone, so nothing carries it and
        # there is nothing to delete. This is what makes a re-run a true no-op
        # — no issue read, no write, for any mapping that already landed.
        if [[ -z "$old_actual" ]]; then
            emit_map "$old" "$new" "already-migrated" 0 \
                "'$old' is not present in $REPO — nothing to relabel, nothing to delete"
            n_already=$((n_already + 1))
            continue
        fi

        if [[ -z "$new_actual" ]]; then
            reason="target label '$new' does not exist in $REPO — run the align pass first (align-labels.sh --repo $REPO)"
            emit_map "$old" "$new" "blocked" 0 "$reason"
            hold "$old" "$new" "$reason"
            continue
        fi

        rc=0
        pending=$(migrate_unmigrated_issues "$old_actual" "$new_actual") || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            if [[ "$rc" -eq 2 ]]; then
                reason="issue read hit the ceiling of $ISSUE_LIMIT — a truncated read undercounts; raise ISSUE_LIMIT"
            else
                reason="could not list the issues carrying '$old_actual'"
            fi
            emit_map "$old" "$new" "failed" 0 "$reason"
            hold "$old" "$new" "$reason"
            continue
        fi

        if [[ -n "$pending" ]]; then
            n_pending=$(printf '%s\n' "$pending" | wc -l | tr -d ' ')
        else
            n_pending=0
        fi

        if [[ "$dry_run" == "1" ]]; then
            if [[ "$n_pending" -gt 0 ]]; then
                issues_csv=$(printf '%s' "$pending" | tr '\n' ',' | sed 's/,$//')
                detail="would add '$new_actual' to $n_pending issue(s) [#${issues_csv//,/, #}], then re-query and delete '$old_actual' ONLY if 0 still carry it"
            else
                detail="no issue carries '$old_actual' without '$new_actual'; would re-query and then delete '$old_actual'"
            fi
            emit_map "$old" "$new" "would-migrate" "$n_pending" "$detail"
            n_would=$((n_would + 1))
            n_relabeled=$((n_relabeled + n_pending))
            continue
        fi

        added=0
        edit_failed=0
        while IFS= read -r num; do
            [[ -z "$num" ]] && continue
            if err=$(ghw issue edit "$num" --repo "$REPO" --add-label "$new_actual" 2>&1 >/dev/null); then
                added=$((added + 1))
            else
                edit_failed=$((edit_failed + 1))
                echo "align-labels: issue #$num: could not add '$new_actual': $(printf '%s' "$err" | grep -v '^\[gh-retry\]' | head -1)" >&2
            fi
        done <<<"$pending"
        n_relabeled=$((n_relabeled + added))
        n_write_failed=$((n_write_failed + edit_failed))

        gate_rc=0
        migrate_delete_gate "$old_actual" "$new_actual" || gate_rc=$?
        if [[ "$gate_rc" -eq 0 ]]; then
            emit_map "$old" "$new" "migrated" "$added" "$GATE_DETAIL"
            n_migrated=$((n_migrated + 1))
        else
            emit_map "$old" "$new" "held-back" "$added" "$GATE_DETAIL"
            hold "$old" "$new" "$GATE_DETAIL"
        fi
    done

    if [[ "$dry_run" == "1" ]]; then mode="migrate dry-run"; else mode="migrate"; fi

    # A plan that targets no mapping at this repo is a legitimate outcome when
    # one file drives every repo — but it is also what a typo'd slug looks
    # like, so say which repos the file DOES target rather than exiting quietly.
    if [[ "$n_considered" -eq 0 ]]; then
        echo "align-labels: $REPO [$mode] — no mapping in $migrate_file targets $REPO; no issue was read and nothing was written." >&2
        echo "  the file targets: $(printf '%s\n' "${MIGRATE_SPECS[@]}" | cut -d'|' -f1 | sort -u | tr '\n' ' ')" >&2
        exit 0
    fi

    if [[ "$dry_run" == "1" ]]; then
        echo "align-labels: $REPO [$mode] — $n_considered mapping(s): $n_would to migrate, $n_already already migrated, $n_held cannot run; $n_relabeled issue relabel(s) previewed (no writes)" >&2
        if [[ "$n_held" -gt 0 ]]; then
            echo "align-labels: MAPPINGS THAT CANNOT RUN AS PLANNED (no delete would be attempted):" >&2
            printf '%s' "$HELD" >&2
        fi
        exit 0
    fi

    echo "align-labels: $REPO [$mode] — $n_considered mapping(s): $n_migrated migrated, $n_already already migrated, $n_held held back; $n_relabeled issue relabel(s), $n_write_failed write failure(s)" >&2
    if [[ "$n_held" -gt 0 ]]; then
        echo "align-labels: MAPPINGS HELD BACK — the old label was NOT deleted:" >&2
        printf '%s' "$HELD" >&2
        echo "  Fix the cause and re-run: the relabels already applied are idempotent, so a" >&2
        echo "  re-run only touches what is still outstanding." >&2
        exit 4
    fi
    [[ "$n_write_failed" -gt 0 ]] && exit 2
    exit 0
fi

n_ok=0
n_create=0
n_update=0
n_failed=0

for spec in "${CANONICAL_LABELS[@]}"; do
    IFS='|' read -r name color desc <<<"$spec"

    cur=$(jq -c --arg n "$name" \
        'map(select((.name | ascii_downcase) == ($n | ascii_downcase)))[0] // empty' \
        <<<"$existing")

    if [[ -z "$cur" ]]; then
        action="create"
        detail="absent"
    else
        cur_name=$(jq -r '.name' <<<"$cur")
        cur_color=$(jq -r '.color | ascii_downcase' <<<"$cur")
        cur_desc=$(jq -r '.description // ""' <<<"$cur")
        drift=""
        [[ "$cur_name" != "$name" ]] && drift="name $cur_name -> $name"
        if [[ "$cur_color" != "$color" ]]; then
            drift="${drift:+$drift; }color $cur_color -> $color"
        fi
        if [[ "$cur_desc" != "$desc" ]]; then
            drift="${drift:+$drift; }description \"$cur_desc\" -> \"$desc\""
        fi
        if [[ -z "$drift" ]]; then
            emit "$name" "ok" ""
            n_ok=$((n_ok + 1))
            continue
        fi
        action="update"
        detail="$drift"
    fi

    if [[ "$dry_run" == "1" ]]; then
        emit "$name" "would-$action" "$detail"
        if [[ "$action" == "create" ]]; then n_create=$((n_create + 1)); else n_update=$((n_update + 1)); fi
        continue
    fi

    rc=0
    if [[ "$action" == "create" ]]; then
        err=$(ghw label create "$name" --repo "$REPO" --color "$color" \
            --description "$desc" 2>&1 >/dev/null) || rc=$?
    else
        err=$(ghw label edit "$cur_name" --repo "$REPO" --name "$name" --color "$color" \
            --description "$desc" 2>&1 >/dev/null) || rc=$?
    fi

    if [[ "$rc" -ne 0 ]]; then
        emit "$name" "failed" "$(echo "$err" | grep -v '^\[gh-retry\]' | head -1)"
        n_failed=$((n_failed + 1))
        continue
    fi

    emit "$name" "$action" "$detail"
    if [[ "$action" == "create" ]]; then n_create=$((n_create + 1)); else n_update=$((n_update + 1)); fi
done

drifted=$((n_create + n_update))
if [[ "$dry_run" == "1" ]]; then
    if [[ "$check_only" == "1" ]]; then mode="check"; else mode="dry-run"; fi
    echo "align-labels: $REPO [$mode] — ${#CANONICAL_LABELS[@]} canonical labels: $n_ok aligned, $n_create to create, $n_update to update (no writes)" >&2
    if [[ "$check_only" == "1" ]]; then
        # Cross-set colours are part of what --check reports. A check that
        # could not run counts as a finding, not as a pass.
        if [[ "$cross_set_rc" == "0" ]]; then
            echo "align-labels: cross-set colours clear — $CROSS_SET_REPORT" >&2
        fi
        if [[ "$drifted" -gt 0 || "$cross_set_rc" != "0" ]]; then
            exit 3
        fi
    fi
    exit 0
fi

echo "align-labels: $REPO — ${#CANONICAL_LABELS[@]} canonical labels: $n_ok aligned, $n_create created, $n_update updated, $n_failed failed" >&2
[[ "$n_failed" -gt 0 ]] && exit 2
exit 0
