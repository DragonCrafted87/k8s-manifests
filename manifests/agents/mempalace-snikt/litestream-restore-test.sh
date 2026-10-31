#!/bin/sh
# Prove the MemPalace init script against Litestream 0.5.17.
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

cname=mempalace-litestream-test-$$
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
    docker run --rm --user 1000:1000 --network none -e HOME=/tmp \
        -v "$base/config:/restore:ro" \
        -v "$base/home:/data" \
        -v "$base/replica:/replica" \
        -v "$base/db:/db" \
        --entrypoint /bin/sh "$image" /restore/restore.sh
}

query() {
    docker run --rm --user 1000:1000 --network none -e HOME=/tmp \
        -v "$1:/data" \
        --entrypoint /bin/sh "$image" \
        -c "sqlite3 /data/$2 \"select name from t order by id;\""
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

inode_of() {
    ls -id "$1" | awk '{print $1}'
}

run_init
palace_link=$base/home/.mempalace/palace/sqlite_exact.sqlite3
kg_link=$base/home/.mempalace/knowledge_graph.sqlite3
if [ ! -L "$palace_link" ] || [ ! -L "$kg_link" ]; then
    echo "first boot did not symlink both databases" >&2
    exit 1
fi
docker run --rm --user 1000:1000 --network none -e HOME=/tmp \
    -v "$base/db:/db" \
    --entrypoint /bin/sh "$image" \
    -c 'sqlite3 /db/sqlite_exact.sqlite3 "PRAGMA integrity_check;"' | grep -qx ok
docker run --rm --user 1000:1000 --network none -e HOME=/tmp \
    -v "$base/db:/db" \
    --entrypoint /bin/sh "$image" \
    -c 'sqlite3 /db/knowledge_graph.sqlite3 "PRAGMA journal_mode;"' | grep -qx wal
palace_inode=$(inode_of "$palace_link")
kg_inode=$(inode_of "$kg_link")
echo "empty boot ok"

docker run --rm --user 1000:1000 --network none -e HOME=/tmp \
    -v "$base/db:/db" \
    --entrypoint /bin/sh "$image" \
-c 'sqlite3 /db/sqlite_exact.sqlite3 "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t(name) VALUES ('"'"'palace-alpha'"'"');"
        sqlite3 /db/knowledge_graph.sqlite3 "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t(name) VALUES ('"'"'kg-alpha'"'"');"'
docker run -d --name "$cname" --user 1000:1000 --network none -e HOME=/tmp \
    -v "$base/config:/restore:ro" \
    -v "$base/db:/db" \
    -v "$base/replica:/replica" \
    --entrypoint /bin/sh "$image" \
    -c 'exec litestream replicate -config /restore/litestream.yml'
sleep 1
docker run --rm --user 1000:1000 --network none -e HOME=/tmp \
    -v "$base/db:/db" \
    --entrypoint /bin/sh "$image" \
    -c 'sqlite3 /db/sqlite_exact.sqlite3 "INSERT INTO t(name) VALUES ('"'"'palace-gamma'"'"');"
        sqlite3 /db/knowledge_graph.sqlite3 "INSERT INTO t(name) VALUES ('"'"'kg-gamma'"'"');"'
sleep 2
docker rm -f "$cname" >/dev/null

docker run --rm --user 0 -v "$base:/base" --entrypoint /bin/sh "$image" \
    -c 'rm -rf /base/db; mkdir -p /base/db; chmod 777 /base/db'
run_init
if [ "$(inode_of "$palace_link")" != "$palace_inode" ] || [ "$(inode_of "$kg_link")" != "$kg_inode" ]; then
    echo "second boot replaced a symlink" >&2
    exit 1
fi
expect "$(query "$base/db" sqlite_exact.sqlite3)" "$(printf 'palace-alpha\npalace-gamma')" "palace replica"
expect "$(query "$base/db" knowledge_graph.sqlite3)" "$(printf 'kg-alpha\nkg-gamma')" "knowledge graph replica"
echo "replica boot ok"

docker run --rm --user 0 -v "$base:/base" --entrypoint /bin/sh "$image" \
    -c 'rm -rf /base/db /base/replica/palace; mkdir -p /base/db /base/replica/palace; chmod 777 /base/db /base/replica/palace; echo junk > /base/replica/palace/garbage'
if run_init; then
    echo "junk replica was restored" >&2
    exit 1
fi
echo "failed restore ok"

echo "litestream restore ok"
