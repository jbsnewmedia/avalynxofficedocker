# avalynxofficedocker

All-in-one Docker Compose stack for
[AvalynxOffice](https://github.com/jbsnewmedia/avalynxoffice) — the self-hosted
mail office with web client, calendar, contacts and licensing — plus the
[avalynxofficeeas](https://github.com/jbsnewmedia/avalynxofficeeas)
ActiveSync extension and PostgreSQL.

## Services

| Service | Image | Purpose |
|---|---|---|
| `nginx` | `nginx:1.29-alpine` | Edge: web client on `/`, ActiveSync on `/Microsoft-Server-ActiveSync` |
| `office` | `jbsnewmedia/avalynxoffice` | AvalynxOffice web client + mail engine |
| `eas` | `jbsnewmedia/avalynxofficeeas` | ActiveSync (EAS) endpoint for iOS/Android/Outlook |
| `db` | `postgres:18-alpine` | Shared PostgreSQL database |

The `office` container bootstraps itself on every start: it waits for the
database, applies the migrations bundled with its image version and creates the
env-defined administrator. The `eas` container maps onto the same schema (the
schema is the interface) and therefore starts only after the office bootstrap
is healthy. Attachments are stored in a shared volume mounted into both
containers.

## Quick start

```bash
git clone https://github.com/jbsnewmedia/avalynxofficedocker.git
cd avalynxofficedocker
cp .env.example .env
# edit .env: set POSTGRES_PASSWORD, APP_SECRET (openssl rand -hex 16)
#            and OFFICE_ADMIN_PASSWORD

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

First start takes about a minute (database bootstrap + migrations). Then:

- Web client: `http://<host>/` — log in with the `OFFICE_ADMIN_*` credentials
- ActiveSync: server URL `http://<host>/Microsoft-Server-ActiveSync`,
  user = a mailbox email address, password = the mailbox password

## Configuration (`.env`)

| Variable | Default | Meaning |
|---|---|---|
| `HTTP_PORT` | `80` | Host port of the nginx edge |
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | — | Shared database credentials (password required) |
| `APP_SECRET` | — | Symfony app secret of the web client (`openssl rand -hex 16`, required) |
| `OFFICE_ADMIN_EMAIL` / `OFFICE_ADMIN_PASSWORD` | — | Administrator created on first start (optional) |
| `OFFICE_TAG` / `EAS_TAG` | `latest` | Image tags — pin to a release for reproducible updates |

## HTTPS

Two supported modes — both keep the ActiveSync endpoint working:

**1. Behind an external reverse proxy (Traefik, Caddy, existing nginx, ...)**

Terminate TLS externally and forward to `HTTP_PORT`. Only one setting is
needed so the web client generates `https://` URLs:

```dotenv
TRUSTED_PROXIES=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
```

(Set it to the address of YOUR proxy — the default covers private networks.)

**2. TLS termination in the nginx edge**

```bash
mkdir certs
# put fullchain.pem + privkey.pem into ./certs
cp nginx/https.conf.example nginx/https.conf
```

Uncomment the three commented blocks in `compose.yaml` (port 443, the
`https.conf` mount and the `certs` mount), then `docker compose up -d`.
Without certificates the edge runs HTTP-only — the TLS include is optional
and does not block start-up.

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
consistent dump while the stack runs:

```bash
docker compose exec db pg_dump -U avalynxoffice avalynxoffice > backup.sql
tar czf attachments.tar.gz -C attachments .
```

Restoring on a fresh machine: stop the stack, copy the directories in,
re-apply the ownerships from the quick start, start the stack.

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
