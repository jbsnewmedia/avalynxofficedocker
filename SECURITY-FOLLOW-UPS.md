# Security Follow-Ups (audit 2026-10-30/31)

This document lists the **remaining open findings** of the security audit
(AvalynxOffice, AvalynxOfficeEAS, Docker stacks) together with concrete
implementation notes. The major findings (H1–H3, M1–M3 from the EAS audit,
entrypoint deadlock, plugins.json bootstrap bug) are already fixed; what is
left are deliberately documented minor items.

---

## 1. Apache `ServerTokens` in the dev stack (ports 83/88)

**Finding:** The dev stack (avalynxoffice-dev, `avalynxoffice-dev/compose.yaml`)
and the img-dev stack expose Apache directly (no nginx edge). The webdevops
base image answers with `Server: Apache/2.4.68 (Debian)` — version information
of the web server and OS layer (Low, information leakage). The production
stacks are not affected (`server_tokens off` in the nginx config applies there).

**Fix options (dev stack `avalynxoffice-dev/compose.yaml`):**

1. Set the environment variable of the webdevops image (Apache modules
   `mod_headers`/ServerTokens):

   ```yaml
   office:
       environment:
           - APACHE_SERVER_TOKENS=Prod
   ```

   **Check effectiveness:** not every webdevops version evaluates the variable.
   Verification: `curl -sI http://127.0.0.1:83/ | grep -i '^server'` →
   expected `Server: Apache` without a version string.

2. If the variable has no effect, mount a file
   `docker/web/conf/apache2/server-tokens.conf` containing `ServerTokens Prod`
   into the image:

   ```yaml
   volumes:
       - ./docker/web/server-tokens.conf:/etc/apache2/conf-enabled/00-server-tokens.conf:ro
   ```

**Priority:** Low — since the migration the dev stacks are bound to
`127.0.0.1` (`HTTP_BIND`), so the leak is only visible locally.

---

## 2. GitHub Actions: SHA pinning and `permissions` (both repos)

**Finding (Medium, supply chain):** The workflows
`avalynxoffice/.github/workflows/docker-image.yml` (+ `ci.yml`) and
`avalynxofficeeas/.github/workflows/docker-image.yml` (+ `ci.yml`) pin the
actions they use to major tags only (`actions/checkout@v6`,
`docker/login-action@v4`, `docker/build-push-action@v7`,
`shivammathur/setup-php@v2`, …) and declare no `permissions:` block.
A hijacked/compromised tag can influence the workflow job — in particular
because `docker/login-action` handles the `DOCKERHUB_TOKEN` secret and the
Docker workflows run on push/tag.

**Fix (per workflow file):**

1. **Keep permissions minimal** — as the first element after `on:`:

   ```yaml
   permissions:
       contents: read
   ```

   (The Docker workflows need no write permissions; release workflows might
   need `contents: write` — set that explicitly and individually there.)

2. **Pin actions to full commit SHAs.** Determine the current SHAs:

   ```bash
   gh api repos/actions/checkout/git/ref/tags/v6 --jq '.object.sha'
   # for annotated tags additionally resolve the underlying commit:
   gh api repos/actions/checkout/git/tags/<tag-sha> --jq '.object.sha'
   ```

   Then replace (determine the SHA yourself at pin time — deliberately no
   example SHA here):

   ```yaml
   # before
   - uses: actions/checkout@v6
   # after
   - uses: actions/checkout@<full-commit-sha> # v6
   ```

   Affected actions in both repos:
   - `actions/checkout`
   - `docker/setup-buildx-action`
   - `docker/login-action`
   - `docker/metadata-action`
   - `docker/build-push-action`
   - `shivammathur/setup-php`

3. Optionally in addition: a `Dependabot` configuration
   (`.github/dependabot.yml`, `package-ecosystem: github-actions`) so that
   SHA pins are updated regularly and in a reviewable way.

**Confirmed non-critical (as of the audit):** no `pull_request_target`, no
secret usage in fork context, no build cache enabled, `docker.sock` is not
mounted anywhere.

---

## 3. `secrets/` in the `.gitignore` of the Docker repo — done

**Finding (Medium, secret leak channel):** `compose.yaml` (lines ~192–197) and
`README.md` (section "Administrator password as Compose secret") recommend
`./secrets/office_admin_password` — but the `secrets/` directory was missing
from `.gitignore`. Anyone following the docs could commit the plaintext secret
and (the repo is public) publish it.

**Fix (applied):** added to `avalynxofficedocker/.gitignore`:

```gitignore
# Compose secrets (see compose.yaml / README)
secrets/
# Defensive leftovers: never commit SQL dumps
*.sql
```

**Additionally recommended (both repos, prophylactic):** add `auth.json`,
`*.pem`, `id_rsa*`, `secrets/` to the `.dockerignore` of the main repo — a
one-off Composer login would otherwise end up in the public image via
`COPY . /app`.

---

## 4. Credential rotation (reminder)

Even if accepted for the local test stacks: before every real deployment

- `OFFICE_ADMIN_PASSWORD` ≥ 16 random characters, remove it from `.env`
  after the first start (the entrypoint warns on every start) or switch to
  `OFFICE_ADMIN_PASSWORD_FILE` + Compose secret,
- generate `POSTGRES_PASSWORD` / `EAS_DB_PASSWORD` / `APP_SECRET` /
  `AVALYNXOFFICE_ENCRYPTION_KEY` fresh
  (`openssl rand -hex 16` or `openssl rand -base64 32`),
- start the stack exclusively via `./core.sh up` (validates placeholders and
  minimum lengths).

---

## 5. Operational notes from the update process

- **DB reset:** PostgreSQL 18 keeps its data in `postgres-data/18/`
  (root/uid-70-owned). A plain `rm -rf postgres-data/*` as an unprivileged
  user **does not delete the database**. Use `./core.sh reset` instead: it
  stops the stack and wipes all data directories through a throwaway
  container (no sudo required), keeping `.env`. Manual equivalent:
  `docker run --rm -v "$PWD/postgres-data:/data" alpine sh -c 'rm -rf /data/*'`
  (containers stopped).
- **EAS state signing:** since the EAS hardening, state files are
  HMAC-signed (key: `EAS_STATE_KEY` or derived from `DATABASE_URL`). When the
  `DATABASE_URL` credentials (or `EAS_STATE_KEY`) change, existing device
  states become invalid → devices then perform a full resync. Clear the state
  directory as well if needed.
- **`EAS_TRUSTED_PROXIES`:** set per stack to the fixed nginx IP
  (prod `172.30.0.2`, img-prod `172.30.1.2`, img-dev `172.30.2.2`), otherwise
  the EAS brute-force protection uses the proxy IP as a single shared bucket.
