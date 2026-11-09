#!/usr/bin/env bash
#
# core.sh - control the avalynxoffice stack (office + eas + nginx + postgres).
#
#   ./core.sh init-env     create .env from .env.example with generated secrets
#   ./core.sh up           start the stack (creates data dirs, fixes owners)
#   ./core.sh down         stop & remove (data directories are kept)
#   ./core.sh restart      down -> up
#   ./core.sh pull         pull the latest images (see OFFICE_TAG/EAS_TAG)
#   ./core.sh update       pull -> up (applies new migrations automatically)
#   ./core.sh status       container status
#   ./core.sh logs [svc]   follow logs (svc: all|office|eas|nginx|db)
#   ./core.sh shell        bash in the office container (user: application)
#   ./core.sh root-shell   bash in the office container (user: root)
#   ./core.sh exec -- CMD  run CMD inside the office container
#   ./core.sh console CMD  run php bin/console CMD in the office container
#   ./core.sh backup       pg_dump + attachments tar into the current directory
#   ./core.sh grant-eas    (re-)apply the least-privilege grants for the EAS role
#   ./core.sh reset        down + wipe all data directories (fresh install; asks)
#   ./core.sh ports        show port mappings
#   ./core.sh help
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Host ports for docker compose (same variables as in compose.yaml).
# .env overrides the defaults, real environment variables win over .env.
for var in HTTP_PORT HTTPS_PORT; do
    val="$(grep -E "^${var}=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    if [ -z "${!var:-}" ] && [ -n "$val" ]; then export "$var=$val"; fi
done

C()   { printf '\033[%sm' "$1"; }
BOLD=$(C 1); GREEN=$(C 32); RED=$(C 31); YELLOW=$(C 33); R=$(C 0)
ok()   { printf "  ${GREEN}OK${R}   %s\n" "$*"; }
warn() { printf "  ${YELLOW}WARN${R} %s\n" "$*"; }
fail() { printf "  ${RED}FAIL${R} %s\n" "$*"; }

usage() {
    cat <<EOF
core.sh - control the avalynxoffice stack (office + eas + nginx + postgres:18)

Commands:
  init-env              create .env from .env.example and generate the secrets
                        (APP_SECRET, AVALYNXOFFICE_ENCRYPTION_KEY, POSTGRES_PASSWORD,
                        EAS_DB_PASSWORD); never overwrites an existing .env
  up                    create data dirs (fix owners via docker) -> up -d
  down                  stop & remove (local data directories are kept)
  restart               down -> up
  pull                  pull the images (tags from .env: OFFICE_TAG/EAS_TAG)
  update                pull -> up (migrations are applied by the entrypoint)
  status                container status
  logs [svc]            follow logs (svc: all|office|eas|nginx|db, default: all)
  shell                 bash as application in the office container
  root-shell            bash as root in the office container
  exec -- CMD           run CMD in the office container
  console CMD           run php bin/console CMD in the office container
  backup                pg_dump + attachments tar into the current directory
  grant-eas             (re-)apply the least-privilege grants for the EAS role
                        (done automatically by the office entrypoint after migrations)
  reset [--yes]         stop the stack and DELETE postgres-data, attachments,
                        office-var, eas-state, eas-log for a fresh installation
                        (.env is kept; asks for confirmation unless --yes)
  ports                 show port mappings
  help                  this help
EOF
}

# Resolve the office container id via compose (the project name is fixed in
# compose.yaml, independent of the directory name).
office_container() {
    docker compose ps -q office 2>/dev/null
}

# Data directories that make up an installation (bind mounts in compose.yaml).
DATA_DIRS=(postgres-data attachments office-var eas-state eas-log)

# A fresh installation has no initialized database yet: postgres-data is
# missing or empty (the postgres image only initializes an empty directory).
fresh_install() {
    [ ! -d postgres-data ] || [ -z "$(ls -A postgres-data 2>/dev/null)" ]
}

check_env() {
    local missing=0 key val
    while IFS='=' read -r key _; do
        [ -z "$key" ] && continue
        val="$(env_value "$key")"
        if [ -z "$val" ]; then
            fail "$key is not set in .env"
            missing=1
        fi
    done <<'EOF'
POSTGRES_PASSWORD
APP_SECRET
AVALYNXOFFICE_ENCRYPTION_KEY
EAS_DB_PASSWORD
EOF
    # Weak or placeholder secrets are rejected (N5): "change-me"-style values
    # from examples and anything shorter than 16 characters.
    for key in POSTGRES_PASSWORD EAS_DB_PASSWORD APP_SECRET; do
        val="$(env_value "$key")"
        [ -z "$val" ] && continue
        case "$val" in
            change-me|change_me|changeme|CHANGE-ME|CHANGE_ME|CHANGEME|password|secret)
                fail "$key uses the placeholder value '$val' - generate a real secret (openssl rand -hex 16)"
                missing=1
                continue
                ;;
        esac
        if [ "${#val}" -lt 16 ]; then
            fail "$key is shorter than 16 characters - generate a real secret (openssl rand -hex 16)"
            missing=1
        fi
    done
    # TRUSTED_PROXIES must name the compose nginx only (fixed 172.30.3.2).
    # Broad ranges let any container - or, behind an external proxy, any
    # client - spoof X-Forwarded-* headers (client IP, https scheme).
    local proxies
    proxies="$(env_value TRUSTED_PROXIES)"
    if [ -n "$proxies" ] && [ "$proxies" != "172.30.3.2" ]; then
        case "$proxies" in
            *"/8"*|*"/12"*|*"/16"*)
                warn "TRUSTED_PROXIES='$proxies' contains a broad network range - use the fixed nginx address 172.30.3.2 (plus single external proxy addresses)"
                ;;
            *)
                warn "TRUSTED_PROXIES='$proxies' differs from the compose nginx address 172.30.3.2 - make sure only real proxies are listed"
                ;;
        esac
    fi
    # First start: without an administrator the stack comes up fine but nobody
    # can log in. The password may come from .env or from the optional Compose
    # secret file (OFFICE_ADMIN_PASSWORD_FILE, see compose.yaml). Existing
    # installations may (and should) leave the password empty.
    if fresh_install; then
        local admin_pw admin_mail
        admin_pw="$(env_value OFFICE_ADMIN_PASSWORD)"
        admin_mail="$(env_value OFFICE_ADMIN_EMAIL)"
        if [ -z "$admin_pw" ] && [ ! -s secrets/office_admin_password ]; then
            fail "fresh installation (postgres-data is empty) but OFFICE_ADMIN_PASSWORD is not set in .env - no user could log in (alternatively provide secrets/office_admin_password, see README)"
            missing=1
        elif [ -n "$admin_pw" ] && [ "${#admin_pw}" -lt 8 ]; then
            fail "OFFICE_ADMIN_PASSWORD is shorter than 8 characters"
            missing=1
        fi
        if [ -z "$admin_mail" ] && [ ! -s secrets/office_admin_email ]; then
            warn "OFFICE_ADMIN_EMAIL is not set - the administrator will be created as admin@example.com"
        fi
    fi
    return "$missing"
}

# Read a variable from .env (last assignment wins, empty if absent). Surrounding
# single/double quotes are stripped like docker compose does.
env_value() {
    local raw
    raw="$(grep -E "^${1}=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    case "$raw" in
        \"*\") raw="${raw#\"}"; raw="${raw%\"}" ;;
        \'*\') raw="${raw#\'}"; raw="${raw%\'}" ;;
    esac
    printf '%s' "$raw"
}

# Create .env from .env.example and fill in the generated secrets. Existing
# files are left untouched so a re-run can never destroy the encryption key.
init_env() {
    if [ -e .env ]; then
        fail ".env already exists - refusing to overwrite it (secrets inside must not be regenerated)"
        exit 1
    fi
    umask 077
    cp .env.example .env
    local app_secret enc_key pg_pw eas_pw
    app_secret="$(openssl rand -hex 16)"
    enc_key="$(openssl rand -base64 32)"
    pg_pw="$(openssl rand -hex 16)"
    eas_pw="$(openssl rand -hex 16)"
    sed -i \
        -e "s|^APP_SECRET=.*|APP_SECRET=${app_secret}|" \
        -e "s|^AVALYNXOFFICE_ENCRYPTION_KEY=.*|AVALYNXOFFICE_ENCRYPTION_KEY=${enc_key}|" \
        -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${pg_pw}|" \
        -e "s|^EAS_DB_PASSWORD=.*|EAS_DB_PASSWORD=${eas_pw}|" \
        .env
    ok "created .env with generated APP_SECRET, AVALYNXOFFICE_ENCRYPTION_KEY, POSTGRES_PASSWORD, EAS_DB_PASSWORD"
    warn "set OFFICE_ADMIN_EMAIL / OFFICE_ADMIN_PASSWORD in .env before the first start"
    warn "back up AVALYNXOFFICE_ENCRYPTION_KEY together with the database - without it stored mail passwords are lost"
}

# Apply the EAS grants through the office container: `office-grant-eas` runs
# the same step as the entrypoint (single source of truth is eas-grants.sql
# shipped in the office image). The entrypoint does this on every start, this
# is the manual fallback.
grant_eas() {
    local role
    role="$(env_value EAS_DB_USER)"
    role="${role:-eas_user}"
    if ! printf '%s' "$role" | grep -Eq '^[a-z_][a-z0-9_]{0,62}$'; then
        fail "EAS_DB_USER must match ^[a-z_][a-z0-9_]*$ (got: $role)"
        exit 1
    fi
    if [ -z "$(office_container)" ]; then
        fail "office container is not running (./core.sh up)"
        exit 1
    fi
    docker compose exec -T office office-grant-eas "$role"
    ok "EAS grants applied for role $role"
}

# Bind-mount targets must exist before mounting (otherwise docker creates
# them as root) and need the container-internal owners:
#   uid 70   = postgres user of the postgres:18-alpine image
#   uid 1000 = application user inside the office/eas images
# The ownership fix runs through a throwaway alpine container so no sudo is
# required on the host.
ensure_host_dirs() {
    local dirs=("${DATA_DIRS[@]}")
    local d uid
    for d in "${dirs[@]}"; do
        mkdir -p "$d"
    done
    local owner_fixed=0
    for d in "${dirs[@]}"; do
        uid="$(stat -c '%u' "$d")"
        if [ "$d" = "postgres-data" ]; then
            [ "$uid" = "70" ] && continue
            docker run --rm -v "$ROOT":/mnt alpine chown -R 70:70 "/mnt/$d" >/dev/null 2>&1 && owner_fixed=1
        else
            [ "$uid" = "1000" ] && continue
            docker run --rm -v "$ROOT":/mnt alpine chown -R 1000:1000 "/mnt/$d" >/dev/null 2>&1 && owner_fixed=1
        fi
    done
    if [ "$owner_fixed" = "1" ]; then
        ok "data directories created / ownership adjusted"
    fi
}

# Wipe an installation for a clean start: stops the stack and removes the
# contents of all data directories (database, attachments, logs, EAS state).
# The directories are owned by container uids (70/1000), so the deletion runs
# through a throwaway alpine container instead of requiring sudo. .env (and
# with it AVALYNXOFFICE_ENCRYPTION_KEY) is never touched.
reset_data() {
    local yes="${1:-}" d
    local present=()
    for d in "${DATA_DIRS[@]}"; do
        [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ] && present+=("$d")
    done
    if [ "${#present[@]}" -eq 0 ]; then
        ok "nothing to reset - all data directories are empty"
        return 0
    fi
    printf "${BOLD}This DELETES all data of this installation in %s:${R}\n" "$ROOT"
    for d in "${present[@]}"; do
        printf '    - %s\n' "$d"
    done
    printf '  (database incl. users, accounts, mails, attachments, logs, EAS device state; .env is kept)\n'
    if [ "$yes" != "--yes" ]; then
        if [ ! -t 0 ]; then
            fail "no terminal for confirmation - run ./core.sh reset --yes to skip the prompt"
            exit 1
        fi
        local answer
        read -r -p "  Type 'yes' to continue: " answer
        if [ "$answer" != "yes" ]; then
            warn "aborted, nothing deleted"
            exit 1
        fi
    fi
    docker compose down >/dev/null 2>&1 || true
    local args=()
    for d in "${present[@]}"; do
        args+=("/mnt/$d")
    done
    # Delete the contents only (hidden files included); the directories
    # themselves stay in place and get their owners fixed again on `up`.
    docker run --rm -v "$ROOT":/mnt alpine sh -c 'for d in "$@"; do find "$d" -mindepth 1 -delete; done' _ "${args[@]}"
    ok "data directories wiped: ${present[*]}"
    warn "next ./core.sh up performs a fresh installation - make sure OFFICE_ADMIN_PASSWORD is set in .env"
}

case "${1:-help}" in
    init-env|init)
        init_env
        ;;
    up|start)
        check_env || { fail "fix .env first"; exit 1; }
        ensure_host_dirs
        docker compose up -d
        docker compose ps
        ;;
    down|stop)
        docker compose down
        ;;
    restart)
        docker compose down >/dev/null 2>&1 || true
        docker compose up -d
        docker compose ps
        ;;
    pull)
        docker compose pull
        ;;
    update)
        docker compose pull
        docker compose up -d
        docker compose ps
        ;;
    status)
        docker compose ps
        ;;
    logs)
        svc="${2:-all}"
        if [ "$svc" = "all" ]; then
            docker compose logs -f
        else
            docker compose logs -f "$svc"
        fi
        ;;
    shell|bash)
        docker exec -it --user=application -w /app "$(office_container)" bash
        ;;
    root-shell|root)
        docker exec -it --user=root -w /app "$(office_container)" bash
        ;;
    exec)
        shift || true
        if [ "${1:-}" = "--" ]; then shift; fi
        if [ "$#" -eq 0 ]; then
            fail "exec needs a command, e.g. ./core.sh exec -- php -v"
            exit 1
        fi
        docker exec --user=application -w /app "$(office_container)" "$@"
        ;;
    console)
        shift || true
        if [ "$#" -eq 0 ]; then
            fail "console needs a command, e.g. ./core.sh console app:mail:fetch"
            exit 1
        fi
        docker exec --user=application -w /app "$(office_container)" php bin/console "$@"
        ;;
    backup)
        local_out="office-backup-$(date +%Y%m%d-%H%M%S)"
        umask 077
        docker compose exec -T db pg_dump -U "$(grep -E '^POSTGRES_USER=' .env | tail -1 | cut -d= -f2-)" \
            "$(grep -E '^POSTGRES_DB=' .env | tail -1 | cut -d= -f2-)" > "${local_out}.sql"
        tar czf "${local_out}-attachments.tar.gz" -C attachments .
        ok "created ${local_out}.sql and ${local_out}-attachments.tar.gz"
        warn "keep AVALYNXOFFICE_ENCRYPTION_KEY from .env together with this backup"
        ;;
    grant-eas)
        grant_eas
        ;;
    reset)
        reset_data "${2:-}"
        ;;
    ports)
        echo "HTTP:   localhost:${HTTP_PORT:-80}"
        echo "HTTPS:  localhost:${HTTPS_PORT:-443} (only with TLS termination in the edge)"
        ;;
    help|-h|--help|"")
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
