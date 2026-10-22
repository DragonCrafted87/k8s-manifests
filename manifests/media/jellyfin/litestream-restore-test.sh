#!/bin/sh
# Prove the Jellyfin init script against Litestream 0.5.17.
# The script and the config are the ConfigMap literals, not a second copy.
# jellyfin.db and library.db are both restored. The bak copy is not.
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
mkdir -p "$base/data" "$base/replica" "$base/db" "$base/restored" "$base/config"
chmod 777 "$base/data" "$base/replica" "$base/db" "$base/restored" "$base/config"

cname=jellyfin-litestream-test-$$
cleanup() {
    docker rm -f "$cname" >/dev/null 2>&1 || true
    if [ -d "$base" ]; then
        docker run --rm --user 0 -v "$base:/base" --entrypoint /bin/sh "$image" \
            -c 'rm -rf /base/data /base/replica /base/db /base/restored /base/config' \
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
    docker run --rm --user 0:0 --network none -e HOME=/tmp \
        -v "$base/config:/restore:ro" \
        -v "$base/data:/seed:ro" \
        -v "$base/data:/config/data" \
        -v "$base/replica:/replica" \
        -v "$base/db:/db" \
        --entrypoint /bin/sh "$image" /restore/restore.sh
}

names() {
    vol=$1
    dbpath=$2
    docker run --rm --user 0:0 --network none -e HOME=/tmp \
        -v "$vol" \
        --entrypoint /bin/sh "$image" \
        -c "sqlite3 ${dbpath} \"select name from t order by id;\""
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

write_db() {
    vol=$1
    dbpath=$2
    sql=$3
    docker run --rm --user 0:0 --network none -e HOME=/tmp \
        -v "$vol" \
        --entrypoint /bin/sh "$image" \
        -c "sqlite3 ${dbpath} \"PRAGMA journal_mode=WAL; ${sql}\""
}

rows=$(printf 'alpha\nbeta')
write_db "$base/data:/data" /data/jellyfin.db \
    "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t(name) VALUES ('alpha'), ('beta');" \
    >/dev/null
write_db "$base/data:/data" /data/library.db \
    "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t(name) VALUES ('alpha'), ('beta');" \
    >/dev/null
printf 'keep\n' >"$base/data/library.db.bak1"

run_init
expect "$(names "$base/db:/db" /db/jellyfin.db)" "$rows" "jellyfin seed"
expect "$(names "$base/db:/db" /db/library.db)" "$rows" "library seed"
if [ ! -L "$base/data/jellyfin.db" ] || [ ! -L "$base/data/library.db" ]; then
    echo "init did not symlink the databases" >&2
    exit 1
fi
if [ ! -s "$base/data/jellyfin.db.nfs-seed" ] || [ ! -s "$base/data/library.db.nfs-seed" ]; then
    echo "init did not keep the seed files" >&2
    exit 1
fi
if [ ! -f "$base/data/library.db.bak1" ]; then
    echo "init removed library.db.bak1" >&2
    exit 1
fi
if [ -e "$base/db/library.db.bak1" ]; then
    echo "init copied library.db.bak1 into the live directory" >&2
    exit 1
fi
printf 'keep\n' | cmp - "$base/data/library.db.bak1"

# A write through the symlink has to land on the emptyDir file.
# SQLite checkpoints and removes the wal when that connection closes,
# so the proof is the row in /db/library.db and no wal beside the symlink.
docker run --rm --user 0:0 --network none -e HOME=/tmp \
    -v "$base/data:/config/data" \
    -v "$base/db:/db" \
    --entrypoint /bin/sh "$image" \
    -c "sqlite3 /config/data/library.db \"INSERT INTO t(name) VALUES ('link');\"" \
    >/dev/null
if [ "$(readlink "$base/data/library.db")" != "/db/library.db" ]; then
    echo "library.db symlink was replaced" >&2
    exit 1
fi
if [ -e "$base/data/library.db-wal" ]; then
    echo "sqlite created a wal beside the symlink" >&2
    exit 1
fi
expect "$(names "$base/db:/db" /db/library.db)" "$(printf 'alpha\nbeta\nlink')" "symlink write"

docker run -d --name "$cname" --user 0:0 --network none -e HOME=/tmp \
    -v "$base/config:/restore:ro" \
    -v "$base/db:/db" \
    -v "$base/replica:/replica" \
    --entrypoint /bin/sh "$image" \
    -c 'exec litestream replicate -config /restore/litestream.yml'
sleep 1
write_db "$base/db:/db" /db/jellyfin.db "INSERT INTO t(name) VALUES ('gamma');" >/dev/null
write_db "$base/db:/db" /db/library.db "INSERT INTO t(name) VALUES ('gamma');" >/dev/null
sleep 2
docker rm -f "$cname" >/dev/null

if find "$base/replica" -name '*bak*' | grep -q .; then
    echo "replica contains a bak file" >&2
    exit 1
fi

docker run --rm --user 0:0 --network none -e HOME=/tmp \
    -v "$base/config:/restore:ro" \
    -v "$base/replica:/replica:ro" \
    -v "$base/restored:/restored" \
    --entrypoint /bin/sh "$image" \
    -c 'litestream restore -config /restore/litestream.yml -o /restored/jellyfin.db /db/jellyfin.db; litestream restore -config /restore/litestream.yml -o /restored/library.db /db/library.db'
replicated=$(printf 'alpha\nbeta\ngamma')
library_rows=$(printf 'alpha\nbeta\nlink\ngamma')
expect "$(names "$base/restored:/restored" /restored/jellyfin.db)" "$replicated" "jellyfin replica"
expect "$(names "$base/restored:/restored" /restored/library.db)" "$library_rows" "library replica"

rm -f "$base/db/jellyfin.db" "$base/db/jellyfin.db-wal" "$base/db/jellyfin.db-shm"
rm -f "$base/db/library.db" "$base/db/library.db-wal" "$base/db/library.db-shm"
write_db "$base/data:/data" /data/jellyfin.db.nfs-seed \
    "DELETE FROM t; INSERT INTO t(name) VALUES ('stale');" >/dev/null
write_db "$base/data:/data" /data/library.db.nfs-seed \
    "DELETE FROM t; INSERT INTO t(name) VALUES ('stale');" >/dev/null
run_init
expect "$(names "$base/db:/db" /db/jellyfin.db)" "$replicated" "jellyfin second init"
expect "$(names "$base/db:/db" /db/library.db)" "$library_rows" "library second init"

docker run --rm --user 0 -v "$base:/base" --entrypoint /bin/sh "$image" \
    -c 'rm -rf /base/replica /base/db; mkdir -p /base/replica /base/db; chmod 777 /base/replica /base/db'
write_db "$base/data:/data" /data/jellyfin.db.nfs-seed \
    "DELETE FROM t; INSERT INTO t(name) VALUES ('kept');" >/dev/null
write_db "$base/data:/data" /data/library.db.nfs-seed \
    "DELETE FROM t; INSERT INTO t(name) VALUES ('kept');" >/dev/null
run_init
kept=$(printf 'kept')
expect "$(names "$base/db:/db" /db/jellyfin.db)" "$kept" "jellyfin nfs-seed"
expect "$(names "$base/db:/db" /db/library.db)" "$kept" "library nfs-seed"

docker run --rm --user 0 -v "$base:/base" --entrypoint /bin/sh "$image" \
    -c 'rm -rf /base/replica /base/db /base/data; mkdir -p /base/replica /base/db /base/data; chmod 777 /base/replica /base/db /base/data'
if run_init; then
    echo "init succeeded with no replica and no seed" >&2
    exit 1
fi

echo "litestream restore ok"
