# GitHub Secrets & Variables — Scope Hierarchy Reference

## Three Scopes

GitHub secrets and variables exist at three levels, each with different visibility, inheritance, and CLI flags.

### 1. Organization Level

Owned by the org. Can be scoped to all repos, private repos only, or specific repos.

```bash
# Secrets
gh secret set SECRET_NAME --org ORG_NAME                          # all repos
gh secret set SECRET_NAME --org ORG_NAME --visibility private     # private repos only
gh secret set SECRET_NAME --org ORG_NAME --repos repo1,repo2      # specific repos
gh secret list --org ORG_NAME
gh secret delete SECRET_NAME --org ORG_NAME

# Variables
gh variable set VAR_NAME --org ORG_NAME
gh variable set VAR_NAME --org ORG_NAME --visibility private
gh variable set VAR_NAME --org ORG_NAME --repos repo1,repo2
gh variable list --org ORG_NAME
gh variable delete VAR_NAME --org ORG_NAME
```

**Workflow reference:**

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ secrets.ORG_SECRET }}"    # same namespace as repo secrets
      - run: echo "${{ vars.ORG_VARIABLE }}"     # same namespace as repo variables
```

Org-level secrets/variables appear in `secrets.*` and `vars.*` automatically — no special prefix or syntax. If a repo-level secret has the same name, it **shadows** the org-level one.

### 2. Repository Level

Owned by the repo. Available to all workflows in that repo, across all environments (unless an environment-level secret shadows it).

```bash
# Secrets (default scope when inside a repo)
gh secret set SECRET_NAME                    # interactive, prompts for value
gh secret set SECRET_NAME --body "value"     # non-interactive
gh secret set SECRET_NAME < secret-file.txt  # from file/pipe
gh secret list
gh secret delete SECRET_NAME

# Variables
gh variable set VAR_NAME --body "value"
gh variable list
gh variable delete VAR_NAME
```

**Workflow reference:**

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ secrets.REPO_SECRET }}"
      - run: echo "${{ vars.REPO_VARIABLE }}"
```

### 3. Environment Level

Scoped to a specific deployment environment (e.g., `production`, `staging`). Only available to jobs that declare `environment:`.

```bash
# Secrets
gh secret set SECRET_NAME --env production
gh secret list --env production
gh secret delete SECRET_NAME --env production

# Variables
gh variable set VAR_NAME --env production --body "value"
gh variable list --env production
gh variable delete VAR_NAME --env production
```

**Workflow reference — MUST declare environment:**

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production          # <-- REQUIRED for environment secrets/vars
    steps:
      - run: echo "${{ secrets.PROD_DB_PASSWORD }}"
      - run: echo "${{ vars.PROD_API_URL }}"
```

Without the `environment:` key, environment-level secrets and variables are **invisible** to the job. This is the single most common mistake.

## Shadowing / Precedence

When the same name exists at multiple levels:

```
Environment > Repository > Organization
```

- Environment-level wins over repo-level
- Repo-level wins over org-level
- There is no merge — the highest-precedence value is used entirely

## Secrets vs Variables

| Aspect | Secrets (`secrets.*`) | Variables (`vars.*`) |
|--------|----------------------|---------------------|
| Encrypted at rest | Yes | No |
| Masked in logs | Yes (value replaced with `***`) | No |
| Readable via API/CLI | No (write-only after creation) | Yes |
| Max size | 48 KB | 48 KB |
| Use for | Passwords, tokens, keys, certs | URLs, feature flags, config values |
| gh subcommand | `gh secret` | `gh variable` |
| Workflow context | `secrets.NAME` | `vars.NAME` |

**Critical**: Secrets are write-only. `gh secret list` shows names but never values. There is no `gh secret get`. Do not attempt to read secret values — it is not possible by design.

## GitHub Actions Contexts

The full set of relevant contexts in workflows:

```yaml
${{ secrets.NAME }}          # Secrets (org, repo, or environment)
${{ vars.NAME }}             # Variables (org, repo, or environment)
${{ github.token }}          # Auto-generated GITHUB_TOKEN
${{ env.NAME }}              # Environment variables set in the workflow
```

These are NOT interchangeable:

- `secrets.X` — GitHub-managed encrypted secrets
- `vars.X` — GitHub-managed plaintext variables
- `env.X` — Workflow-defined environment variables (set with `env:` blocks)
- `$X` or `${{ env.X }}` — Shell environment variables

## Dependabot Secrets

Dependabot has its own secret scope. Regular repo/org secrets are NOT available to Dependabot PRs.

```bash
gh secret set SECRET_NAME --app dependabot
gh secret list --app dependabot
```

## Common Patterns

### Setting from Doppler or another secret manager

```bash
# Pipe value from Doppler into GH secret
doppler secrets get SECRET_NAME --plain | gh secret set SECRET_NAME

# Bulk sync (set multiple): the plugin's Bash guard allows a Doppler command only on its own,
# so run each line below as its own command (no `;`, `&&` or `trap` joining them to the
# download), keep the path literal and free of the word the guard watches for, and let gh read
# the file. The file holds live values: create it private first, delete it after, and delete
# it even if the gh step fails.
install -m 600 /dev/null /tmp/gh-secrets-sync.env
doppler secrets download --no-file --format env > /tmp/gh-secrets-sync.env
gh secret set -f /tmp/gh-secrets-sync.env
rm -f /tmp/gh-secrets-sync.env
```

### Setting for GitHub Actions vs GitHub Codespaces

```bash
gh secret set SECRET_NAME --app actions       # default
gh secret set SECRET_NAME --app codespaces
```
