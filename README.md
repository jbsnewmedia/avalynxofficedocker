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
All application containers run with `no-new-privileges`.

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

# Create the local data directories and set the owners:
#   uid 70  = postgres user of the alpine image
#   uid 1000 = application user inside the office/eas containers
mkdir -p postgres-data attachments office-var eas-state eas-log
sudo chown 70:70 postgres-data
sudo chown 1000:1000 attachments office-var eas-state eas-log

docker compose up -d
```

All state lives in these local directories (bind mounts), so upgrades are a
simple image change and the data stays visible in the project folder.

`compose.yaml` works standalone (`docker compose up -d` — compose reads
`.env` automatically). The provided `core.sh` wraps the everyday commands:

```bash
./core.sh up              # start (also creates/fixes the data directories)
./core.sh update          # pull latest images -> up (migrations run on start)
./core.sh console app:mail:fetch --limit=10
./core.sh backup          # pg_dump + attachments tar into the project dir
./core.sh help
```

First start takes about a minute (database bootstrap + migrations). The plain
HTTP web client is for local-only setup; configure TLS before entering real
credentials or exposing the stack publicly. ActiveSync redirects HTTP requests
to HTTPS and is unavailable until TLS is configured.

After the first successful start remove `OFFICE_ADMIN_PASSWORD` from `.env`
(and `docker compose up -d` once more): the administrator already exists, the
variable is only consumed by the bootstrap and otherwise just lingers in the
container environment. The entrypoint unsets it before the web server starts
and passes it to the console command via the environment, never on a command
line.

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
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | — | Database owner credentials used by the office container (password required) |
| `EAS_DB_USER` / `EAS_DB_PASSWORD` | `eas_user` / — | Least-privilege database role of the EAS container (password required, `openssl rand -hex 16`) — see below |
| `APP_SECRET` | — | Symfony app secret of the web client (`openssl rand -hex 16`, required) |
| `AVALYNXOFFICE_ENCRYPTION_KEY` | — | Key for the encrypted mail account credentials (`openssl rand -base64 32`, required; back up with the database) |
| `OFFICE_ADMIN_EMAIL` / `OFFICE_ADMIN_PASSWORD` | — | Administrator created on first start (optional; remove the password after the first start) |
| `NGINX_IMAGE` | `nginx:1.30-alpine` | Edge image override (floating stable line: picks up new 1.30.x on pull) |
| `POSTGRES_IMAGE` | `postgres:18-alpine` | Database image override |
| `OFFICE_TAG` / `EAS_TAG` | `latest` | Image tags — pin to a release for reproducible updates |

### EAS database role (least privilege)

The ActiveSync container does not use the database owner. On the first start
(fresh `postgres-data/`) `postgres/init/01-eas-role.sh` creates the login role
`EAS_DB_USER` with `EAS_DB_PASSWORD`. Because the tables only exist after the
office migrations, the office entrypoint (re-)applies the grants after every
migration run: `SELECT` on all tables (also future ones via
`ALTER DEFAULT PRIVILEGES`), `INSERT`/`UPDATE`/`DELETE` on the mail, contact and
calendar tables, plus column-restricted updates on `account.inbox_folder_id`
and `app_user.last_auth_at`. To re-apply the grants manually (same SQL,
`postgres/eas-grants.sql`):

```bash
./core.sh grant-eas
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

## HTTPS

Two supported modes — both keep the ActiveSync endpoint working:

**1. Behind an external reverse proxy (Traefik, Caddy, existing nginx, ...)**

Terminate TLS externally and connect the proxy directly to the `office` and
`eas` services on the Compose network. Configure the proxy to overwrite—not
append or pass through—`X-Forwarded-For`, `X-Real-IP` and `X-Forwarded-Proto`.
Set `TRUSTED_PROXIES` to the exact proxy IP (or a narrowly scoped subnet):

```dotenv
TRUSTED_PROXIES=172.30.0.10
```

Do not trust broad private ranges. The Compose nginx edge is fixed at
`172.30.0.2`; it overwrites forwarded headers and is the default trusted proxy.

**2. TLS termination in the nginx edge**

```bash
mkdir certs
# put fullchain.pem + privkey.pem into ./certs
cp nginx/https.conf.example nginx/https.conf
```

Uncomment the three commented blocks in `compose.yaml` (port 443, the
`https.conf` mount and the `certs` mount), then `docker compose up -d`.
With this configuration the edge redirects all HTTP requests to HTTPS. Until
TLS is configured, HTTP-only access is local-testing-only and must not be used
for real mail credentials or publicly exposed ActiveSync.

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
