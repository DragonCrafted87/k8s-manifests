#!/bin/sh
# Prove the forgeledger init script against Litestream 0.5.17.
# The script and the config are the ConfigMap literals, not a second copy.
# The pod runs as uid 65534, and the server keeps the database in WAL.
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
mkdir -p "$base/seed" "$base/replica" "$base/db" "$base/restored" "$base/config"
chmod 777 "$base/seed" "$base/replica" "$base/db" "$base/restored" "$base/config"

cname=forgeledger-litestream-test-$$
cleanup() {
    docker rm -f "$cname" >/dev/null 2>&1 || true
    if [ -d "$base" ]; then
        docker run --rm --user 0 -v "$base:/base" --entrypoint /bin/sh "$image" \
            -c 'rm -rf /base/seed /base/replica /base/db /base/restored /base/config' \
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
    docker run --rm --user 65534:65534 --network none -e HOME=/tmp \
        -v "$base/config:/restore:ro" \
        -v "$base/seed:/seed:ro" \
        -v "$base/replica:/replica" \
        -v "$base/db:/data" \
        --entrypoint /bin/sh "$image" /restore/restore.sh
}

names() {
    docker run --rm --user 65534:65534 --network none -e HOME=/tmp \
        -v "$1:/data" \
        --entrypoint /bin/sh "$image" \
        -c 'sqlite3 /data/forgeledger.sqlite "select name from t order by id;"'
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

# One connection, so synchronous=NORMAL applies to these writes.
# journal_mode prints wal. synchronous=NORMAL prints 1.
write_normal() {
    vol=$1
    dbpath=$2
    sql=$3
    docker run --rm --user 65534:65534 --network none -e HOME=/tmp \
        -v "$vol" \
        --entrypoint /bin/sh "$image" \
        -c "sqlite3 ${dbpath} \"PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA synchronous; ${sql}\""
}

mode=$(write_normal "$base/seed:/seed" /seed/forgeledger.sqlite \
    "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t(name) VALUES ('alpha'), ('beta');")
expect "$mode" "$(printf 'wal\n1')" "seed writer"

run_init
expect "$(names "$base/db")" "$(printf 'alpha\nbeta')" "seed restore"

docker run -d --name "$cname" --user 65534:65534 --network none -e HOME=/tmp \
    -v "$base/config:/restore:ro" \
    -v "$base/db:/data" \
    -v "$base/replica:/replica" \
    --entrypoint /bin/sh "$image" \
    -c 'exec litestream replicate -config /restore/litestream.yml'
sleep 1
mode=$(write_normal "$base/db:/data" /data/forgeledger.sqlite \
    "INSERT INTO t(name) VALUES ('gamma');")
expect "$mode" "$(printf 'wal\n1')" "replica writer"
sleep 2
docker rm -f "$cname" >/dev/null

docker run --rm --user 65534:65534 --network none -e HOME=/tmp \
    -v "$base/config:/restore:ro" \
    -v "$base/replica:/replica:ro" \
    -v "$base/restored:/restored" \
    --entrypoint /bin/sh "$image" \
    -c 'litestream restore -config /restore/litestream.yml -o /restored/forgeledger.sqlite /data/forgeledger.sqlite'
expect "$(names "$base/restored")" "$(printf 'alpha\nbeta\ngamma')" "replica restore"

rm -f "$base/db/forgeledger.sqlite" "$base/db/forgeledger.sqlite-wal" "$base/db/forgeledger.sqlite-shm"
mode=$(write_normal "$base/seed:/seed" /seed/forgeledger.sqlite \
    "DELETE FROM t; INSERT INTO t(name) VALUES ('stale');")
expect "$mode" "$(printf 'wal\n1')" "stale writer"
run_init
expect "$(names "$base/db")" "$(printf 'alpha\nbeta\ngamma')" "second init"

docker run --rm --user 0 -v "$base:/base" --entrypoint /bin/sh "$image" \
    -c 'rm -rf /base/replica /base/db /base/seed; mkdir -p /base/replica /base/db /base/seed; chmod 777 /base/replica /base/db /base/seed'
if run_init; then
    echo "init succeeded with no replica and no seed" >&2
    exit 1
fi

echo "litestream restore ok"
