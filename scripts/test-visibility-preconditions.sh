#!/usr/bin/env bash
# test-visibility-preconditions.sh — pins the repo-visibility precondition AND
# the credential naming on EVERY setup-deps template that mints a GitHub App
# token (issues #178, #186, #316).
#
# Renamed from test-auto-merge-visibility.sh in #186: the subject was never the
# auto-merge workflow, it was the credential. Three templates mint
# PLATFORM_WRITER_APP_* from the same two org secrets — dependabot-auto-merge,
# lockfile-sync-bun, lockfile-sync-pod — and #178 gave the precondition to only
# one of them, leaving the other two rendering into public repos through the
# door it left open.
#
# The pair is PLATFORM_WRITER_APP_CLIENT_ID + PLATFORM_WRITER_APP_PRIVATE_KEY
# since #316; before that it was PLATFORM_WRITER_APP_ID, whose input
# `create-github-app-token` deprecated in v3.2.0. Both names exist in both org
# stores and they are DIFFERENT values, so property 9 asserts the templates mint
# with `client-id:` and that no `app-id:` survives IN THE MINT STEP — scoped
# there rather than file-wide, since a file-wide absence check is failed by the
# prose that explains the rule. The tempting
# shortcut is to pass the numeric App ID through `client-id`, which GitHub's JWT
# `iss` claim accepts, and which would silence the deprecation with no new
# secret while leaving an App ID in an input named client-id in every consumer.
#
# Why this is a source-level guard and not a render test. The render decision is
# not made by a script — `render-dependabot.sh` renders `dependabot.yml` only.
# The decision lives in SKILL.md prose that an agent follows, so the artifact
# under test is the instruction itself, the same way test-label-migrate.sh pins
# align-labels.sh's single-call-site invariant and test-detect-hook-stack.sh
# pins "has_tracked carries no pipeline".
#
# The bug it guards is the expensive kind: invisible at render time, surfacing
# weeks later somewhere else. Org secrets at `private` visibility (= private +
# internal) exclude PUBLIC repos in BOTH the Actions and the Dependabot store.
# Rendered into a public repo, `secrets.*` resolves to the empty string and
# `create-github-app-token` fails on that repo's next Dependabot PR — as an auth
# error that looks unrelated to the generator run that caused it.
#
# The two lockfile templates are the WORSE case, which is why narrowing this
# file back to auto-merge would be a regression and not a simplification:
# dependabot-auto-merge deliberately never checks out, while both lockfile-sync
# templates `actions/checkout` the PR head ref with the minted token in scope.
#
# Properties asserted:
#
#   1. SKILL.md probes visibility (`gh repo view … --json visibility`).
#   2. SKILL.md states the public → do-not-render rule.
#   3. The veto names ALL FOUR App-token outputs, not just auto-merge (#186);
#      deps-cadence (#509) joined the three Dependabot workflows.
#   4. The render table carries the precondition on all four rows (#186).
#   5. The Guardrails section carries it as a standing rule covering the
#      lockfile templates too — guardrails are what a hurried reader checks.
#   6. The no-gate arm does not instruct an unconditional lockfile-sync render.
#   7. The skip report names the CONSEQUENCE and a workaround, so a public repo
#      that needs lockfile sync is not left at a wall with no next step.
#   8. dependabot.yml.template does NOT assert unconditionally that
#      dependabot-auto-merge.yml holds semver-major, because in a public repo
#      that workflow is deliberately absent and the claim would be false.
#   9. All three token-minting templates pass `client-id:` naming
#      PLATFORM_WRITER_APP_CLIENT_ID, carry the matching presence gate, and
#      retain NO `app-id:` input or PLATFORM_WRITER_APP_ID reference (#316).
#      Per-template, because the deprecation warning fires once per template and
#      a single-template assertion is how #178 came to cover one of three.
#
# No gh, no network, no repo mutation — it reads two tracked files plus the
# three token-minting templates.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-visibility-preconditions.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-visibility-preconditions: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

SKILL="skills/setup-deps/SKILL.md"
TEMPLATE="skills/setup-deps/references/templates/dependabot.yml.template"

fails=0
ok()   { echo "  ok    $1"; }
bad()  { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

echo "visibility preconditions on App-token templates (issues #178, #186)"

for f in "$SKILL" "$TEMPLATE"; do
    [ -r "$f" ] || { bad "missing file: $f"; }
done
[ "$fails" -eq 0 ] || { echo "test-visibility-preconditions: FAILED" >&2; exit 1; }

# The visibility section, isolated. Every rule below is scoped to it rather than
# to the whole file, so a passing mention of "public" elsewhere cannot satisfy
# any of them.
visibility_section="$(awk '/^### The second precondition: repo visibility/{f=1; next} /^#{2,3} /{f=0} f' "$SKILL")"
[ -n "$visibility_section" ] || bad "cannot locate the '### The second precondition: repo visibility' section"

# Whitespace-flattened copy of the whole file. This repo hard-wraps prose, so a
# phrase routinely straddles two lines and a line-scoped grep misses it. For a
# MUST-NOT-EXIST assertion that miss is a FALSE PASS — the forbidden wording is
# present, merely wrapped — so every such check below runs against this, never
# against raw lines. (A must-EXIST check may stay line-scoped: a wrap there
# fails loudly, which is safe.)
skill_flat="$(tr '\n' ' ' < "$SKILL" | tr -s ' ')"

# 1. The probe itself. Without it the rule cannot be applied, however well the
#    prose describes it.
if grep -qE 'gh repo view.*--json visibility' "$SKILL"; then
    ok "SKILL.md probes repo visibility"
else
    bad "SKILL.md has no 'gh repo view … --json visibility' probe"
fi

# 2. The rule. Matched on the pairing of 'public' with a do-not-render
#    instruction.
#    Captured first, never `grep … | grep -q`: under this script's pipefail,
#    grep -q closes the pipe on its first match, the upstream grep takes
#    SIGPIPE, and the promoted 141 makes a MATCH read as a MISS (issue #172,
#    generalised in #256) — this gate would report the rule missing from a file
#    that states it.
public_lines="$(grep -iE 'public' "$SKILL")"
if grep -qiE 'do not render|never render|not render' <<<"$public_lines"; then
    ok "SKILL.md states public -> do not render"
else
    bad "SKILL.md does not tie 'public' to a do-not-render instruction"
fi

# 3. (#186) The veto must name all three templates. This is the assertion the
#    pre-#186 file fails: its visibility section spoke only of the auto-merge
#    workflow, so both lockfile templates rendered into public repos.
for tpl in auto-merge bun-lockfile pod-lockfile deps-cadence; do
    if printf '%s' "$visibility_section" | grep -qE "$tpl"; then
        ok "visibility veto names $tpl"
    else
        bad "visibility veto does not name $tpl — it renders into public repos"
    fi
done

# 4. (#186) The render table is what a reader consults to answer "does this get
#    rendered?". A precondition stated only in prose two hundred lines down is
#    the shape that let #178 cover one template and miss two.
while IFS= read -r row; do
    file="$(printf '%s' "$row" | sed -E 's/^\| *`([^`]+)`.*/\1/')"
    if printf '%s' "$row" | grep -qiE 'not public|non-public|public'; then
        ok "render table row for $file carries the visibility precondition"
    else
        bad "render table row for $file has no visibility precondition"
    fi
done < <(grep -E '^\| `\.github/workflows/(dependabot-(auto-merge|bun-lockfile|pod-lockfile)|deps-cadence)\.yml`' "$SKILL")

# 5. The standing guardrail, scoped to the Guardrails section only. It must now
#    cover the lockfile templates: a guardrail naming only auto-merge is what
#    #186 was filed about.
guardrails="$(awk '/^## Guardrails/{f=1; next} /^## /{f=0} f' "$SKILL")"
# Re-join each wrapped bullet into ONE record, so "same bullet" stays the unit
# of the check. Flattening the whole section instead would let 'public' in one
# guardrail and 'lockfile' in an unrelated one satisfy it.
guardrail_bullets="$(printf '%s\n' "$guardrails" |
    awk '/^- /{if (b != "") print b; b=$0; next} {b = b " " $0} END{if (b != "") print b}')"
if printf '%s' "$guardrails" | grep -qiE 'public'; then
    ok "Guardrails section carries the public-repo rule"
else
    bad "Guardrails section does not mention the public-repo rule"
fi
if printf '%s\n' "$guardrail_bullets" | grep -iE 'public' | grep -qiE 'lockfile'; then
    ok "Guardrails public-repo rule covers the lockfile-sync templates"
else
    bad "Guardrails public-repo rule is still scoped to auto-merge alone"
fi

# 6. (#186) The no-gate arm used to read "Render `dependabot.yml` and the
#    lockfile-sync workflows only" — an unconditional instruction that
#    contradicts the veto in exactly the repos this change is about.
if printf '%s' "$skill_flat" | grep -qE 'lockfile-sync workflows only'; then
    bad "no-gate arm still instructs an unconditional lockfile-sync render"
else
    ok "no-gate arm carries no unconditional lockfile-sync render"
fi
# ...and that arm must still require a gate, so deleting the paragraph outright
# cannot pass this check.
if printf '%s' "$skill_flat" | grep -qiE 'needs a gate first|repo needs a gate'; then
    ok "no-gate arm still tells the user a gate is required"
else
    bad "no-gate arm no longer states that the repo needs a gate"
fi

# 7. (#186) A veto with no next step leaves every npm-path Dependabot PR in a
#    public bun repo dead on arrival with nothing said about it. The skip report
#    must name the consequence and a manual path.
if printf '%s' "$visibility_section" | grep -qiE 'frozen|dead on arrival|fail.*CI|CI.*reject'; then
    ok "skip report names the consequence of the missing lockfile sync"
else
    bad "skip report does not name what breaks without lockfile sync"
fi
# Tied to 'lockfile' on the same line on purpose. An unscoped search for
# "by hand" passes on the unrelated 403 sentence further down this very section
# ("...reviewing Dependabot PRs by hand is the enforcement"), which would make
# this assertion vacuous — it did, before #186.
if printf '%s' "$visibility_section" | grep -iE 'lockfile' | grep -qiE 'regenerat|by hand|manually|locally'; then
    ok "skip report names a manual workaround for the lockfile"
else
    bad "skip report offers no lockfile workaround for a public repo needing sync"
fi

# 8b. (#190) The public-repo lockfile answer is DELIBERATE non-automation. It
#     must read as a decision, not as a gap someone should close: a reader who
#     takes it for an unfinished item "fixes" it by putting a write-capable
#     credential inside a public repo, which is the one outcome the decision
#     exists to prevent. Pinned on the pairing of a decision word with the
#     do-not-automate instruction, so softening it to a TODO fails here.
if printf '%s' "$skill_flat" | grep -qiE 'deliberate non-automation|is the answer for public'; then
    ok "public-repo lockfile answer is stated as a decision"
else
    bad "public-repo lockfile answer no longer reads as a decision (#190)"
fi
if printf '%s' "$skill_flat" | grep -qiE 'do not automate it|Do not automate'; then
    ok "SKILL.md instructs not to automate the public-repo path"
else
    bad "SKILL.md lost the do-not-automate instruction for public repos"
fi

# 8. The template must not claim coverage it may not have. The pre-fix wording
#    was 'and dependabot-auto-merge.yml holds them anyway' — an unconditional
#    assertion that is false in exactly the repos this change is about.
# Flattened for the same false-pass reason as the SKILL.md must-not-exist checks
# above: the forbidden claim lives in a wrapped comment block.
template_flat="$(tr '\n' ' ' < "$TEMPLATE" | tr -s ' ')"
if printf '%s' "$template_flat" | grep -qE 'holds them anyway'; then
    bad "template still asserts auto-merge 'holds them anyway' unconditionally"
else
    ok "template makes no unconditional auto-merge coverage claim"
fi

# ...and it must still explain the semver-major exclusion, which is the reason
# that comment block exists. Guarding only against the old sentence would let
# deleting the whole paragraph pass.
if grep -qiE 'semver-major is excluded' "$TEMPLATE"; then
    ok "template still explains the semver-major exclusion"
else
    bad "template no longer explains why semver-major is excluded"
fi

# 9. The credential is the CLIENT ID, per template (#316). One row each, for the
#    reason #186 exists: the warning fires once per template, and a gate that
#    checked one of the three is exactly how #178 shipped covering one of three.
#    Both directions are asserted — the presence of `client-id:` AND the absence
#    of `app-id:` — because passing the numeric App ID through `client-id` also
#    satisfies a presence-only check, works at runtime (GitHub's JWT `iss` claim
#    accepts either), and is the shortcut SKILL.md rules out.
# DERIVED, not transcribed. A hard-coded list is how a fourth minting template
# inherits no coverage at all; test-template-actionlint.sh derives its set the
# same way. The vacuity guard is the point of deriving: an empty set would make
# every loop below pass by never running.
TOKEN_TEMPLATES="$(git ls-files 'skills/setup-deps/references/templates/*.template.yml' \
    | xargs grep -l 'actions/create-github-app-token' 2>/dev/null)"
if [ -z "$TOKEN_TEMPLATES" ]; then
    bad "no template references actions/create-github-app-token — the credential rows below would pass vacuously"
elif [ "$(printf '%s\n' "$TOKEN_TEMPLATES" | wc -l | tr -d ' ')" -lt 3 ]; then
    bad "only $(printf '%s\n' "$TOKEN_TEMPLATES" | wc -l | tr -d ' ') token-minting template(s) found; #186 established there are three"
else
    ok "token-minting templates derived from the tree ($(printf '%s\n' "$TOKEN_TEMPLATES" | wc -l | tr -d ' ') found)"
fi

# step_region <file> <step name> — one `- name: <step>` step's own lines, ending
# at the next step. SCOPING IS THE WHOLE POINT: file-wide greps let a
# commented-out `client-id:` satisfy a presence check and let an `app-id:`
# anywhere else in the file escape an absence check, and both were reproduced.
# Six-space step indent, identical in all three templates.
step_region() {
    awk -v want="      - name: $2" '
        index($0, want) == 1 { f = 1; print; next }
        f && /^      - name: / { exit }
        f { print }' "$1"
}

# 9. The credential is the CLIENT ID, per template (#316), asserted INSIDE the
#    two steps that carry it. One row each, for the reason #186 exists: the
#    warning fires once per template, and a gate that checked one of three is
#    exactly how #178 shipped covering one of three.
#
#    The presence gate is asserted MECHANICALLY, not by its message. Its six
#    places (env key, `[ -n ]` test, `missing=` string, per template) were all
#    renamed here, and a message-only check certifies none of them. Three
#    mutations were GREEN against the message-only form and are red now:
#      - `[ -n "$APP_CLIENT_ID" ]` -> `[ -n "$APP_KEY" ]`: an unprovisioned
#        client ID stops being caught and dies later inside the mint, as the
#        opaque auth error this step exists to replace.
#      - env key `APP_CLIENT_ID:` -> `APP_ID:`: the variable is unset, `missing`
#        is ALWAYS non-empty, and every consumer's Dependabot PR hard-fails with
#        a bogus "Missing Dependabot secret(s)" even when provisioning is right.
#      - `exit 1` -> `echo`: the gate degrades to a warning and stops gating.
#    The env key is CAPTURED and compared, never spelled twice, so renaming it
#    consistently stays legal and renaming it in one place does not.
#
#    The absence check matches `app[-_]id` case-insensitively with optional
#    quotes: `"app-id":` and `App-id:` are legal YAML, resolve to the same
#    input, still emit the deprecation warning, and both passed the plain
#    `^[[:space:]]*app-id:` anchor.
for tf in $TOKEN_TEMPLATES; do
    t="$(basename "$tf" .template.yml)"
    gate_step="$(step_region "$tf" "Require the app credentials")"
    mint_step="$(step_region "$tf" "Mint GitHub App token")"
    env_key="$(printf '%s\n' "$gate_step" \
        | sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\):[[:space:]]*\${{[[:space:]]*secrets\.PLATFORM_WRITER_APP_CLIENT_ID[[:space:]]*}}.*/\1/p' \
        | head -1)"

    if [ -z "$mint_step" ] || [ -z "$gate_step" ]; then
        bad "$t: could not slice the credential steps — 'Require the app credentials' and/or 'Mint GitHub App token' no longer parse at the expected indent"
    elif ! printf '%s\n' "$mint_step" | grep -q 'client-id:[[:space:]]*\${{[[:space:]]*secrets\.PLATFORM_WRITER_APP_CLIENT_ID[[:space:]]*}}'; then
        bad "$t: the mint step does not pass client-id: PLATFORM_WRITER_APP_CLIENT_ID (#316)"
    elif printf '%s\n' "$mint_step" | grep -qEi '^[[:space:]]*"?app[-_]id"?[[:space:]]*:'; then
        bad "$t: the mint step still passes the deprecated app-id: input — it warns on every consumer run and breaks when the fallback is dropped"
    elif printf '%s\n' "$mint_step" | grep -q 'PLATFORM_WRITER_APP_ID'; then
        bad "$t: the mint step references PLATFORM_WRITER_APP_ID — a DIFFERENT value from the client ID; passing it through client-id: is the shortcut SKILL.md rules out"
    elif [ -z "$env_key" ]; then
        bad "$t: the presence gate binds no env var to PLATFORM_WRITER_APP_CLIENT_ID, so it cannot be checking the secret the mint uses"
    elif ! printf '%s\n' "$gate_step" | grep -qF "[ -n \"\$$env_key\" ]"; then
        bad "$t: the presence gate binds \$$env_key but never tests it — an unprovisioned client ID is no longer caught here and dies opaquely inside the mint"
    elif ! printf '%s\n' "$gate_step" | grep -q 'missing PLATFORM_WRITER_APP_CLIENT_ID'; then
        bad "$t: the presence gate tests \$$env_key but names a different secret in its failure message"
    elif ! printf '%s\n' "$gate_step" | grep -qE '^[[:space:]]*exit 1$'; then
        bad "$t: the presence gate no longer exits non-zero — it degrades to a warning and stops gating"
    else
        ok "$t: mints with client-id: PLATFORM_WRITER_APP_CLIENT_ID, and its presence gate tests \$$env_key and exits"
    fi
done

# 10. THE TWO VERSION MARKERS MOVE TOGETHER. Every template carries its version
#     twice — the `# TEMPLATE: <name> · version N` file header and the
#     `generated-by: … | template-version: N` marker — and eight prior bumps
#     moved both. Nothing checked it, and #316's first commit bumped only the
#     second in all three files, leaving 2/3, 8/9 and 5/6. The split is silent
#     in the worst direction: the header block is stripped before render, so no
#     consumer sees it and only the next EDITOR is misled — including about
#     whether the next bump is 9 or 10, since the header prose cites its own
#     version by number to explain render rules.
for tf in $TOKEN_TEMPLATES; do
    t="$(basename "$tf" .template.yml)"
    hdr_v="$(sed -n '1s/.*· version \([0-9][0-9]*\).*/\1/p' "$tf")"
    gen_v="$(sed -n 's/.*| template-version: \([0-9][0-9]*\).*/\1/p' "$tf" | head -1)"
    if [ -z "$hdr_v" ] || [ -z "$gen_v" ]; then
        bad "$t: could not read both version markers (header='$hdr_v' generated-by='$gen_v') — one of the two has moved or changed shape"
    elif [ "$hdr_v" != "$gen_v" ]; then
        bad "$t: version markers disagree — file header says $hdr_v, generated-by says $gen_v. Both move on every bump"
    else
        ok "$t: both version markers read $hdr_v"
    fi
done

# The prerequisite list is the one place a human is told which secret to
# provision, and it named the deprecated one. A template/doc split here costs a
# consumer a failed run per repo, which is how #316 was found. Scoped to §4 and
# asserted on the IDENTIFIER alone: pinning the sentence would fail identically
# on a harmless reflow and on a genuine revert.
skill_s4="$(awk '/^## 4\. Prerequisites/{f=1} f&&/^## 5\./{exit} f' "$SKILL")"
if printf '%s\n' "$skill_s4" | grep -q 'PLATFORM_WRITER_APP_CLIENT_ID'; then
    ok "SKILL.md §4 names the client ID as the secret to provision"
else
    bad "SKILL.md §4 does not name PLATFORM_WRITER_APP_CLIENT_ID — the templates and the provisioning instruction disagree"
fi

if [ "$fails" -ne 0 ]; then
    echo "test-visibility-preconditions: FAILED ($fails)" >&2
    exit 1
fi
echo "visibility precondition tests: all green"
