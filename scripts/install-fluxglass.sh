#!/bin/sh
set -eu

repo="${FLUXGLASS_REPO:-TEPZAET/OpenFlux}"
ref="${FLUXGLASS_REF:-fluxglass-yandex-auto}"
install_dir="${FLUXGLASS_INSTALL_DIR:-/opt/fluxglass}"
container="fluxglass-yandex"
image="fluxglass-yandex:local"
doc_url="${FLUXGLASS_DOC_URL:-${1:-}}"

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run as root"
[ -n "$doc_url" ] || fail "Yandex document URL is required"
case "$doc_url" in
    https://disk.yandex.*/*|https://yadi.sk/*) ;;
    *) fail "unsupported Yandex document URL" ;;
esac

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        return
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io ca-certificates curl tar
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y docker ca-certificates curl tar
    elif command -v yum >/dev/null 2>&1; then
        yum install -y docker ca-certificates curl tar
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache docker ca-certificates curl tar
    else
        fail "supported package manager not found"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker
    else
        service docker start
    fi
}

install_docker
docker info >/dev/null 2>&1 || fail "Docker daemon is unavailable"

work_dir="$(mktemp -d /tmp/fluxglass-install.XXXXXX)"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

archive="$work_dir/source.tar.gz"
curl -fL --retry 3 --connect-timeout 15 \
    "https://github.com/$repo/archive/refs/heads/$ref.tar.gz" -o "$archive"
mkdir "$work_dir/source"
tar -xzf "$archive" -C "$work_dir/source" --strip-components=1

docker build -t "$image" "$work_dir/source"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="$install_dir/backups/$timestamp"
mkdir -p "$backup_dir"
legacy_active=0
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet openflux-yandex.service; then
    legacy_active=1
    systemctl cat openflux-yandex.service > "$backup_dir/openflux-yandex.service"
    if [ -f /usr/local/bin/openflux ]; then
        cp -p /usr/local/bin/openflux "$backup_dir/openflux"
    fi
    systemctl stop openflux-yandex.service
    systemctl disable openflux-yandex.service >/dev/null 2>&1 || true
fi

mkdir -p "$install_dir"
printf '%s\n' "$doc_url" > "$install_dir/document-url"
chmod 600 "$install_dir/document-url"

docker rm -f "$container" >/dev/null 2>&1 || true
if ! docker run -d \
    --name "$container" \
    --restart unless-stopped \
    --label io.fluxglass.managed=true \
    --cap-add NET_RAW \
    --cap-add NET_ADMIN \
    -e ROLE=exit-node \
    -e TRANSPORT=auto \
    -e URL="$doc_url" \
    "$image" >/dev/null; then
    if [ "$legacy_active" -eq 1 ]; then
        systemctl enable --now openflux-yandex.service
    fi
    fail "container start failed; previous OpenFlux service restored"
fi

sleep 5
if ! docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
    docker logs "$container" >&2 || true
    docker rm -f "$container" >/dev/null 2>&1 || true
    if [ "$legacy_active" -eq 1 ]; then
        systemctl enable --now openflux-yandex.service
    fi
    fail "container stopped during startup; previous OpenFlux service restored"
fi

detected="$(docker logs "$container" 2>&1 | sed -n 's/.*Yandex document mode: \([^ ]*\).*/\1/p' | tail -n 1)"
[ -n "$detected" ] || detected="pending"
printf 'OK\nCONTAINER=%s\nTRANSPORT=%s\nBACKUP=%s\n' "$container" "$detected" "$backup_dir"
