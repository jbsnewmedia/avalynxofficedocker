# avalynxofficedocker

All-in-one Docker Compose stack for
[AvalynxOffice](https://github.com/jbsnewmedia/avalynxoffice) — the self-hosted
mail office with web client, calendar, contacts and licensing — plus the
[avalynxofficeeas](https://github.com/jbsnewmedia/avalynxofficeeas)
ActiveSync extension and PostgreSQL.

## Services

| Service | Image | Purpose |
|---|---|---|
| `nginx` | `nginx:1.30-alpine` | Edge: web client on `/`, ActiveSync on `/Microsoft-Server-ActiveSync` |
| `office` | `jbsnewmedia/avalynxoffice` | AvalynxOffice web client + mail engine |
| `eas` | `jbsnewmedia/avalynxofficeeas` | ActiveSync (EAS) endpoint for iOS/Android/Outlook |
| `db` | `postgres:18-alpine` | Shared PostgreSQL database |

The `office` container bootstraps itself on every start: it waits for the
database, applies the migrations bundled with its image version, grants the
least-privilege EAS database role access to the tables it needs and creates
the env-defined administrator. The `eas` container maps onto the same schema
(the schema is the interface) with its own restricted database role and
therefore starts only after the office bootstrap is healthy; nginx waits for
both. Attachments are stored in a shared volume mounted into both containers.
All containers run with `no-new-privileges`, drop every Linux capability
except the few their entrypoints need (`cap_drop: ALL` + minimal `cap_add`)
and are confined by memory and process-count limits (see *Resource limits*).

## Quick start

```bash
git clone https://github.com/jbsnewmedia/avalynxofficedocker.git
cd avalynxofficedocker
# Creates .env from .env.example and generates APP_SECRET,
# AVALYNXOFFICE_ENCRYPTION_KEY, POSTGRES_PASSWORD and EAS_DB_PASSWORD.
# (Manual alternative: cp .env.example .env and fill in the values -
#  APP_SECRET: openssl rand -hex 16, AVALYNXOFFICE_ENCRYPTION_KEY: openssl rand -base64 32)
./core.sh init-env
# edit .env: set OFFICE_ADMIN_EMAIL and OFFICE_ADMIN_PASSWORD

# Checks .env, creates the local data directories with the right owners
# (no sudo needed) and runs docker compose up -d.
./core.sh up
```

That is the whole installation: configure `.env`, `./core.sh up`, open
`http://<host>/` and log in with `OFFICE_ADMIN_EMAIL` / `OFFICE_ADMIN_PASSWORD`.
On a fresh installation (empty `postgres-data/`) `core.sh up` refuses to start
without an administrator password, because the stack would come up without
any user able to log in; on an existing installation the variable may stay
empty.

Without `core.sh` (plain `docker compose up -d`) create the data directories
yourself: `mkdir -p postgres-data attachments office-var eas-state eas-log`,
`sudo chown 70:70 postgres-data` (postgres user of the alpine image) and
`sudo chown 1000:1000 attachments office-var eas-state eas-log` (application
user inside the office/eas containers).

All state lives in these local directories (bind mounts), so upgrades are a
simple image change and the data stays visible in the project folder.

`compose.yaml` works standalone (`docker compose up -d` — compose reads
`.env` automatically). The provided `core.sh` wraps the everyday commands:

```bash
./core.sh up              # start (also creates/fixes the data directories)
./core.sh update          # pull latest images -> up (migrations run on start)
./core.sh console app:mail:fetch --limit=10
./core.sh backup          # pg_dump + attachments tar into the project dir
./core.sh reset           # stop + wipe all data directories for a fresh install (asks)
./core.sh help
```

`reset` deletes the database, attachments, logs and the EAS device state of
this installation (through a throwaway container, no sudo required) and keeps
`.env`. Use it to start over, e.g. after experimenting with an older image
version; add `--yes` to skip the confirmation prompt.

First start takes about a minute (database bootstrap + migrations). The plain
HTTP web client is for local-only setup; configure TLS before entering real
credentials or exposing the stack publicly. ActiveSync redirects HTTP requests
to HTTPS and is unavailable until TLS is configured.

After the first successful start remove `OFFICE_ADMIN_PASSWORD` from `.env`
(and `docker compose up -d` once more): the administrator already exists, the
variable is only consumed by the bootstrap and otherwise just lingers in the
container environment (the entrypoint logs a warning on every start while it
is still set). The entrypoint unsets it before the web server starts and
passes it to the console command via the environment, never on a command
line.

Alternative without a plain-text value in `.env`: a Compose secret. Put the
password into a file (e.g. `./secrets/office_admin_password`, `chmod 600`),
uncomment the `secrets:` blocks in `compose.yaml` (service level + top level)
and set `OFFICE_ADMIN_PASSWORD_FILE: /run/secrets/office_admin_password` in
the `office` environment while leaving `OFFICE_ADMIN_PASSWORD` empty. The
entrypoint reads `OFFICE_ADMIN_PASSWORD_FILE` / `OFFICE_ADMIN_EMAIL_FILE`
and refuses to start when both the plain variable and the `_FILE` variant are
set.

**Back up `AVALYNXOFFICE_ENCRYPTION_KEY` together with the database.** The
key encrypts the stored mail account credentials; if it is lost, every saved
mail password becomes unusable and has to be re-entered. Never regenerate it
on an existing installation.

- Local-only setup: `http://localhost/` — log in with the `OFFICE_ADMIN_*` credentials
- Public web client after configuring TLS: `https://<host>/`
- ActiveSync: server URL `https://<host>/Microsoft-Server-ActiveSync`,
  user = the AvalynxOffice login e-mail address, password = an **app password**
  created in the web client under *Profile → App passwords* (the web login
  password is not accepted on devices; app passwords can be revoked per device)

## Configuration (`.env`)

| Variable | Default | Meaning |
|---|---|---|
| `HTTP_PORT` | `80` | Host port of the nginx edge |
| `HTTP_BIND` / `HTTPS_BIND` | `0.0.0.0` | Bind address of the published ports; `127.0.0.1` behind an external reverse proxy on the same host (HTTPS mode 1) |
| `HTTPS_PORT` | `443` | Host port for TLS in the edge (HTTPS mode 2, only when enabled in `compose.yaml`) |
| `TRUSTED_PROXIES` | `172.30.0.2` | Proxy addresses the office container trusts for `X-Forwarded-*`; keep the fixed edge address (`core.sh up` warns about other values or broad ranges) |
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | — | Database owner credentials used by the office container (password required, at least 16 characters, no placeholder) |
| `EAS_DB_USER` / `EAS_DB_PASSWORD` | `eas_user` / — | Least-privilege database role of the EAS container (password required, `openssl rand -hex 16`) — see below |
| `APP_SECRET` | — | Symfony app secret of the web client (`openssl rand -hex 16`, required, at least 16 characters) |
| `AVALYNXOFFICE_ENCRYPTION_KEY` | — | Key for the encrypted mail account credentials (`openssl rand -base64 32`, required; back up with the database) |
| `OFFICE_ADMIN_EMAIL` / `OFFICE_ADMIN_PASSWORD` | — | Administrator created on first start (`core.sh up` requires the password on a fresh installation; remove it after the first start or use `OFFICE_ADMIN_PASSWORD_FILE` with a Compose secret) |
| `NGINX_IMAGE` | `nginx:1.30-alpine` | Edge image override (floating stable line: picks up new 1.30.x on pull) |
| `POSTGRES_IMAGE` | `postgres:18-alpine` | Database image override |
| `OFFICE_TAG` / `EAS_TAG` | `latest` | Image tags — **pin to a released version in production** (e.g. `1.0.2`) so updates are a deliberate step instead of whatever `latest` currently points to |
| `NGINX_MEM_LIMIT` / `NGINX_PIDS_LIMIT` | `128m` / `256` | Memory and process limits of the nginx edge |
| `OFFICE_MEM_LIMIT` / `OFFICE_PIDS_LIMIT` | `1g` / `256` | Memory and process limits of the office container |
| `EAS_MEM_LIMIT` / `EAS_PIDS_LIMIT` | `512m` / `256` | Memory and process limits of the EAS container |
| `DB_MEM_LIMIT` / `DB_PIDS_LIMIT` | `1g` / `512` | Memory and process limits of PostgreSQL |

### EAS database role (least privilege)

The ActiveSync container does not use the database owner. On the first start
(fresh `postgres-data/`) `postgres/init/01-eas-role.sh` creates the login role
`EAS_DB_USER` with `EAS_DB_PASSWORD`. Because the tables only exist after the
office migrations, the office entrypoint (re-)applies the grants after every
migration run. The grants are explicit (no `ALL TABLES`, no default
privileges, no sequences — all keys are UUIDs):

- `SELECT` on `account`, `user_account`, `license_state`,
  `app_user_app_password`;
- `SELECT` on the columns `id`, `email`, `roles`, `active`, `last_auth_at`,
  `created_at`, `updated_at` of `app_user` — the web login password hash is
  not readable by the EAS role (devices authenticate with app passwords);
- `SELECT`/`INSERT`/`UPDATE`/`DELETE` on the mail, contact and calendar
  tables (`email*`, `body`, `attachment`, `address`, `account_address`,
  `folder`, `account_folder`, `calendar_event`);
- column-restricted `UPDATE` on `account.inbox_folder_id`,
  `app_user.last_auth_at` and `app_user_app_password.last_used_at`.

Blanket grants of earlier stack versions are revoked by the same script, so
an update tightens existing installations automatically. The SQL lives in the
office image (`docker/prod/eas-grants.sql` in the AvalynxOffice repository,
single source of truth) and is applied by `office-grant-eas` inside the
container. To re-apply it manually (office container must be running):

```bash
./core.sh grant-eas          # = docker compose exec office office-grant-eas
```

If the role has to be created on an existing database (volume initialised
before this stack version), run the `CREATE ROLE` from the init script once
against the running database, then `./core.sh grant-eas`.

### Edge hardening

The nginx edge rate-limits `/login` (30 requests/minute per IP, burst 10,
HTTP 429 beyond that) and caps `/Microsoft-Server-ActiveSync` at 20 concurrent
connections per IP (ActiveSync clients poll often and hold long Ping requests,
so no request-rate limit is applied there). Adjust the zones at the top of
`nginx/nginx.conf` if needed.

Both limits key on the client address as seen by the Compose nginx. In HTTPS
mode 1 (external reverse proxy) that address is always the proxy, so the
limits would throttle the proxy instead of individual clients — see the notes
in that section.

Request bodies are capped at 64 MB (`client_max_body_size 64m` in
`nginx/nginx.conf` and `nginx/https.conf.example`). This is a generous upper
bound above the application limits: the office container caps stored
attachments via `ATTACHMENT_STORAGE_MAX_BYTES` (64 KB in `compose.yaml`), the
EAS container defaults to 25 MB. If you raise the application limit, raise
the nginx value accordingly — it is a plain config value, not an `.env`
variable.

### Resource limits

Every container has a memory and a process-count (`pids`) limit, set via
`deploy.resources.limits` (honoured by `docker compose` v2+ without Swarm).
The defaults suit a small installation; override them in `.env`
(`NGINX_MEM_LIMIT`, `OFFICE_MEM_LIMIT`, `EAS_MEM_LIMIT`, `DB_MEM_LIMIT` and
the matching `*_PIDS_LIMIT`). A container that exceeds its memory limit is
OOM-killed and restarted by Docker (`restart: unless-stopped`); check
`docker stats` and raise the limit if that happens under normal load.

All containers additionally start with `cap_drop: ALL` and only the
capabilities their entrypoints need to fix volume ownership, bind port 80 and
switch to the unprivileged service user (`CHOWN`, `SETUID`, `SETGID`,
`NET_BIND_SERVICE`, plus `DAC_OVERRIDE`/`FOWNER` for the webdevops based
application images and PostgreSQL). Dynamic container addresses are taken
from `172.30.0.128/25`, so the fixed edge address `172.30.0.2` used as the
default `TRUSTED_PROXIES` is never handed to another container.

## HTTPS

Two supported modes — both keep the ActiveSync endpoint working:

**1. Behind an external reverse proxy (Traefik, Caddy, existing nginx, ...)**

Terminate TLS externally and connect the proxy directly to the `office` and
`eas` services on the Compose network. Configure the proxy to overwrite—not
append or pass through—`X-Forwarded-For`, `X-Real-IP` and `X-Forwarded-Proto`
(`https`). Set `TRUSTED_PROXIES` to the exact proxy IP (or a narrowly scoped
subnet):

```dotenv
TRUSTED_PROXIES=172.30.0.10
```

Do not trust broad private ranges (`/8`, `/12`, `/16`); `core.sh up` warns
about them. The Compose nginx edge is fixed at `172.30.0.2`; it overwrites
forwarded headers and is the default trusted proxy.

In this mode the Compose nginx should **not** sit between the external proxy
and the applications: its rate limits and connection caps key on the client
address, which would always be the external proxy, and it overwrites
`X-Forwarded-For`/`X-Real-IP` with that address, so the applications would
never see the real client IP (audit finding M-1). Either point the external
proxy at `office:80` / `eas:80` directly, or — if the Compose nginx has to
stay in the chain — enable the commented `set_real_ip_from` block in
`nginx/nginx.conf` for the single proxy address and add that address to
`TRUSTED_PROXIES`. In both cases bind the published port to the loopback
interface so the plain-HTTP edge is not reachable from the network:

```dotenv
HTTP_BIND=127.0.0.1
```

**2. TLS termination in the nginx edge**

```bash
mkdir certs
# put fullchain.pem + privkey.pem into ./certs
cp nginx/https.conf.example nginx/https.conf
cp nginx/http-redirect.conf.example nginx/http-redirect.conf
```

In `compose.yaml` uncomment the port 443 line, the `https.conf` mount and the
`certs` mount, and **replace** the `nginx.conf` mount by the
`http-redirect.conf` mount (both are mounted as `default.conf`), then
`docker compose up -d`.

- `https.conf` contains only the port 443 server: TLS 1.2/1.3 with the
  Mozilla *intermediate* cipher list, session cache without tickets, OCSP
  stapling, `Strict-Transport-Security` (1 year, `includeSubDomains`) and
  `X-Content-Type-Options: nosniff` on server level.
- `http-redirect.conf` provides the port 80 server, which redirects every
  request (not only ActiveSync) with `308` to `https://$host$request_uri`,
  plus the shared rate-limit zones. Keeping `nginx.conf` instead would still
  proxy the web client over plain HTTP.
- Recommended: replace `server_name _` in both files with your host name and
  redirect to that fixed name instead of `$host`, so client-supplied `Host`
  headers are not echoed into the `Location` header.

Until TLS is configured, HTTP-only access is local-testing-only and must not
be used for real mail credentials or publicly exposed ActiveSync.

## Updating

```bash
docker compose pull
docker compose up -d
```

The office container applies new migrations automatically on start. Pin
`OFFICE_TAG`/`EAS_TAG` to released versions before pulling to control the
upgrade step.

## Data directories & backup

All persistent state is stored in bind-mounted local directories:

| Directory | Content |
|---|---|
| `postgres-data/` | PostgreSQL data (mail, calendar, contacts, users, licensing) |
| `attachments/` | Email attachments (shared by office + eas) |
| `office-var/` | Symfony cache/logs of the web client |
| `eas-state/` / `eas-log/` | ActiveSync device state and logs |

Back up at least `postgres-data/` and `attachments/` — best as a
consistent dump while the stack runs — **and the `.env` file** (or at least
`AVALYNXOFFICE_ENCRYPTION_KEY`): the database dump alone is useless for the
stored mail credentials without the key.

```bash
docker compose exec db pg_dump -U avalynxoffice avalynxoffice > backup.sql
tar czf attachments.tar.gz -C attachments .
```

Restoring on a fresh machine: stop the stack, copy the directories in,
re-apply the ownerships from the quick start, restore `.env` with the
original `AVALYNXOFFICE_ENCRYPTION_KEY`, start the stack.

## Mailboxes

Mailboxes (real POP3/SMTP accounts) are added either in the web client admin
area or on the CLI of the office container:

```bash
docker compose exec office php bin/console app:mailbox:add \
    you@example.com "PASSWORD" --host=pop.example.com --user=you@example.com \
    --port=995 --security=ssl
```

Incoming mail is fetched by the mail engine (see the AvalynxOffice README for
scheduling `app:mail:fetch` / `app:mail:send`).
