#!/bin/sh
# Prove the Hermes init script against Litestream 0.5.17.
# The script and the config are the ConfigMap literals, not a second copy.
set -eu

cd "$(dirname "$0")"
image=litestream/litestream:0.5.17

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required" >&2
    exit 1
fi
if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "missing image ${image}" >&2
    exit 1
fi

base=$(mktemp -d)
chmod 777 "$base"
mkdir -p "$base/home" "$base/replica" "$base/db" "$base/restored" "$base/config"
chmod 777 "$base/home" "$base/replica" "$base/db" "$base/restored" "$base/config"

cname=hermes-litestream-test-$$
cleanup() {
    docker rm -f "$cname" >/dev/null 2>&1 || true
    if [ -d "$base" ]; then
        docker run --rm --user 0 -v "$base:/base" --entrypoint /bin/sh "$image" \
            -c 'rm -rf /base/home /base/replica /base/db /base/restored /base/config' \
            >/dev/null 2>&1 || true
        rm -rf "$base"
    fi
}
trap cleanup EXIT

extract_key() {
    key=$1
    dest=$2
    awk -v key="$key" '
        $0 == "  " key ": |" { capture = 1; next }
        capture && substr($0, 1, 4) == "    " { print substr($0, 5); next }
        capture && $0 == "" { print ""; next }
        capture { exit }
    ' 10_litestream.yml >"$dest"
    if [ ! -s "$dest" ]; then
        echo "missing ${key} in 10_litestream.yml" >&2
        exit 1
    fi
}

extract_key litestream.yml "$base/config/litestream.yml"
extract_key restore.sh "$base/config/restore.sh"
chmod 644 "$base/config/restore.sh" "$base/config/litestream.yml"

run_init() {
    docker run --rm --user 10000:10000 --network none -e HOME=/tmp \
        -v "$base/config:/restore:ro" \
        -v "$base/home:/opt/data" \
        -v "$base/replica:/replica" \
        -v "$base/db:/db" \
        --entrypoint /bin/sh "$image" /restore/restore.sh
}

names() {
    docker run --rm --user 10000:10000 --network none -e HOME=/tmp \
        -v "$1:/data" \
        --entrypoint /bin/sh "$image" \
        -c 'sqlite3 /data/state.db "select name from t order by id;"'
}

expect() {
    got=$1
    want=$2
    label=$3
    if [ "$got" != "$want" ]; then
        echo "${label} returned: ${got}" >&2
        exit 1
    fi
}

run_init
if [ ! -L "$base/home/state.db" ]; then
    echo "first boot did not symlink state.db" >&2
    exit 1
fi
docker run --rm --user 10000:10000 --network none -e HOME=/tmp \
    -v "$base/db:/db" \
    --entrypoint /bin/sh "$image" \
    -c 'sqlite3 /db/state.db "PRAGMA integrity_check;"' | grep -qx ok

docker run --rm --user 0 -v "$base:/base" --entrypoint /bin/sh "$image" \
    -c 'rm -rf /base/replica /base/db /base/home; mkdir -p /base/replica /base/db /base/home; chmod 777 /base/replica /base/db /base/home'
docker run --rm --user 10000:10000 --network none -e HOME=/tmp \
    -v "$base/home:/home" \
    --entrypoint /bin/sh "$image" \
    -c 'sqlite3 /home/state.db "PRAGMA journal_mode=WAL; CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t(name) VALUES ('"'"'alpha'"'"'), ('"'"'beta'"'"');"'

run_init
if [ ! -f "$base/home/state.db.nfs-seed" ]; then
    echo "seed was not moved aside" >&2
    exit 1
fi
expect "$(names "$base/db")" "$(printf 'alpha\nbeta')" "seed restore"

docker run -d --name "$cname" --user 10000:10000 --network none -e HOME=/tmp \
    -v "$base/config:/restore:ro" \
    -v "$base/db:/db" \
    -v "$base/replica:/replica" \
    --entrypoint /bin/sh "$image" \
    -c 'exec litestream replicate -config /restore/litestream.yml'
sleep 1
docker run --rm --user 10000:10000 --network none -e HOME=/tmp \
    -v "$base/db:/db" \
    --entrypoint /bin/sh "$image" \
    -c 'sqlite3 /db/state.db "INSERT INTO t(name) VALUES ('"'"'gamma'"'"');"'
sleep 2
docker rm -f "$cname" >/dev/null

docker run --rm --user 10000:10000 --network none -e HOME=/tmp \
    -v "$base/config:/restore:ro" \
    -v "$base/replica:/replica:ro" \
    -v "$base/restored:/restored" \
    --entrypoint /bin/sh "$image" \
    -c 'litestream restore -config /restore/litestream.yml -o /restored/state.db /db/state.db'
expect "$(names "$base/restored")" "$(printf 'alpha\nbeta\ngamma')" "replica restore"

docker run --rm --user 0 -v "$base:/base" --entrypoint /bin/sh "$image" \
    -c 'rm -rf /base/db; mkdir -p /base/db; chmod 777 /base/db'
docker run --rm --user 10000:10000 --network none -e HOME=/tmp \
    -v "$base/home:/home" \
    --entrypoint /bin/sh "$image" \
    -c 'rm -f /home/state.db; sqlite3 /home/state.db "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t(name) VALUES ('"'"'stale'"'"');"'
run_init
expect "$(names "$base/db")" "$(printf 'alpha\nbeta\ngamma')" "second init"

echo "litestream restore ok"
