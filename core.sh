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
  ports                 show port mappings
  help                  this help
EOF
}

# Resolve the office container id via compose (the project name is fixed in
# compose.yaml, independent of the directory name).
office_container() {
    docker compose ps -q office 2>/dev/null
}

check_env() {
    local missing=0
    while IFS='=' read -r key _; do
        [ -z "$key" ] && continue
        val="$(grep -E "^${key}=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
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
    return "$missing"
}

# Read a variable from .env (last assignment wins, empty if absent).
env_value() {
    grep -E "^${1}=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true
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

# Apply the EAS grants (postgres/eas-grants.sql) through psql in the db
# container. The office entrypoint does the same on every start, this is the
# manual fallback.
grant_eas() {
    local role
    role="$(env_value EAS_DB_USER)"
    role="${role:-eas_user}"
    if ! printf '%s' "$role" | grep -Eq '^[a-z_][a-z0-9_]{0,62}$'; then
        fail "EAS_DB_USER must match ^[a-z_][a-z0-9_]*$ (got: $role)"
        exit 1
    fi
    docker compose exec -T db psql -v ON_ERROR_STOP=1 -v role="$role" \
        -U "$(env_value POSTGRES_USER)" -d "$(env_value POSTGRES_DB)" < postgres/eas-grants.sql
    ok "EAS grants applied for role $role"
}

# Bind-mount targets must exist before mounting (otherwise docker creates
# them as root) and need the container-internal owners:
#   uid 70   = postgres user of the postgres:18-alpine image
#   uid 1000 = application user inside the office/eas images
# The ownership fix runs through a throwaway alpine container so no sudo is
# required on the host.
ensure_host_dirs() {
    local dirs=(postgres-data attachments office-var eas-state eas-log)
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
