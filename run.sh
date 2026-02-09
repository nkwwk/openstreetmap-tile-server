#!/bin/bash

set -euo pipefail

function createPostgresConfig() {
  cp /etc/postgresql/$PG_VERSION/main/postgresql.custom.conf.tmpl /etc/postgresql/$PG_VERSION/main/conf.d/postgresql.custom.conf
  sudo -u postgres echo "autovacuum = $AUTOVACUUM" >> /etc/postgresql/$PG_VERSION/main/conf.d/postgresql.custom.conf
  cat /etc/postgresql/$PG_VERSION/main/conf.d/postgresql.custom.conf
}

function setPostgresPassword() {
    sudo -u postgres psql -c "ALTER USER renderer PASSWORD '${PGPASSWORD:-renderer}'"
}

if [ "$#" -ne 1 ]; then
    echo "usage: <import|run|export>"
    echo "commands:"
    echo "    import: Set up the database and import /data/region.osm.pbf"
    echo "    run: Runs Apache and renderd to serve tiles at /tile/{z}/{x}/{y}.png"
    echo "    export: Export rendered tiles to a .mbtiles file"
    echo "environment variables:"
    echo "    THREADS: defines number of threads used for importing / tile rendering"
    echo "    UPDATES: consecutive updates (enabled/disabled)"
    echo "    NAME_LUA: name of .lua script to run as part of the style"
    echo "    NAME_STYLE: name of the .style to use"
    echo "    NAME_MML: name of the .mml file to render to mapnik.xml"
    echo "    NAME_SQL: name of the .sql file to use"
    echo "    EXPORT_FILE: output .mbtiles filename (default: tiles.mbtiles)"
    echo "    EXPORT_MINZOOM: minimum zoom level to export (default: 0)"
    echo "    EXPORT_MAXZOOM: maximum zoom level to export (default: 20)"
    exit 1
fi

set -x

# if there is no custom style mounted, then use osm-carto
if [ ! "$(ls -A /data/style/)" ]; then
    mv /home/renderer/src/openstreetmap-carto-backup/* /data/style/
fi

# carto build
if [ ! -f /data/style/mapnik.xml ]; then
    cd /data/style/
    carto ${NAME_MML:-project.mml} > mapnik.xml
fi

if [ "$1" == "import" ]; then
    # Ensure that database directory is in right state
    mkdir -p /data/database/postgres/
    chown renderer: /data/database/
    chown -R postgres: /var/lib/postgresql /data/database/postgres/
    if [ ! -f /data/database/postgres/PG_VERSION ]; then
        sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/pg_ctl -D /data/database/postgres/ initdb -o "--locale C.UTF-8"
    fi

    # Initialize PostgreSQL
    createPostgresConfig
    service postgresql start
    sudo -u postgres createuser renderer
    sudo -u postgres createdb -E UTF8 -O renderer gis
    sudo -u postgres psql -d gis -c "CREATE EXTENSION postgis;"
    sudo -u postgres psql -d gis -c "CREATE EXTENSION hstore;"
    sudo -u postgres psql -d gis -c "ALTER TABLE geometry_columns OWNER TO renderer;"
    sudo -u postgres psql -d gis -c "ALTER TABLE spatial_ref_sys OWNER TO renderer;"
    setPostgresPassword

    # Download Luxembourg as sample if no data is provided
    if [ ! -f /data/region.osm.pbf ] && [ -z "${DOWNLOAD_PBF:-}" ]; then
        echo "WARNING: No import file at /data/region.osm.pbf, so importing Luxembourg as example..."
        DOWNLOAD_PBF="https://download.geofabrik.de/europe/luxembourg-latest.osm.pbf"
        DOWNLOAD_POLY="https://download.geofabrik.de/europe/luxembourg.poly"
    fi

    if [ -n "${DOWNLOAD_PBF:-}" ]; then
        echo "INFO: Download PBF file: $DOWNLOAD_PBF"
        wget ${WGET_ARGS:-} "$DOWNLOAD_PBF" -O /data/region.osm.pbf
        if [ -n "${DOWNLOAD_POLY:-}" ]; then
            echo "INFO: Download PBF-POLY file: $DOWNLOAD_POLY"
            wget ${WGET_ARGS:-} "$DOWNLOAD_POLY" -O /data/region.poly
        fi
    fi

    if [ "${UPDATES:-}" == "enabled" ] || [ "${UPDATES:-}" == "1" ]; then
        # determine and set osmosis_replication_timestamp (for consecutive updates)
        REPLICATION_TIMESTAMP=`osmium fileinfo -g header.option.osmosis_replication_timestamp /data/region.osm.pbf`

        # initial setup of osmosis workspace (for consecutive updates)
        sudo -E -u renderer openstreetmap-tiles-update-expire.sh $REPLICATION_TIMESTAMP
    fi

    # copy polygon file if available
    if [ -f /data/region.poly ]; then
        cp /data/region.poly /data/database/region.poly
        chown renderer: /data/database/region.poly
    fi

    # flat-nodes
    if [ "${FLAT_NODES:-}" == "enabled" ] || [ "${FLAT_NODES:-}" == "1" ]; then
        OSM2PGSQL_EXTRA_ARGS="${OSM2PGSQL_EXTRA_ARGS:-} --flat-nodes /data/database/flat_nodes.bin"
    fi

    # Import data
    sudo -u renderer osm2pgsql -d gis --create --slim -G --hstore  \
      --tag-transform-script /data/style/${NAME_LUA:-openstreetmap-carto.lua}  \
      --number-processes ${THREADS:-4}  \
      -S /data/style/${NAME_STYLE:-openstreetmap-carto.style}  \
      /data/region.osm.pbf  \
      ${OSM2PGSQL_EXTRA_ARGS:-}  \
    ;

    # old flat-nodes dir
    if [ -f /nodes/flat_nodes.bin ] && ! [ -f /data/database/flat_nodes.bin ]; then
        mv /nodes/flat_nodes.bin /data/database/flat_nodes.bin
        chown renderer: /data/database/flat_nodes.bin
    fi

    # Create indexes
    if [ -f /data/style/${NAME_SQL:-indexes.sql} ]; then
        sudo -u postgres psql -d gis -f /data/style/${NAME_SQL:-indexes.sql}
    fi

    #Import external data
    chown -R renderer: /home/renderer/src/ /data/style/
    if [ -f /data/style/scripts/get-external-data.py ] && [ -f /data/style/external-data.yml ]; then
        sudo -E -u renderer python3 /data/style/scripts/get-external-data.py -c /data/style/external-data.yml -D /data/style/data
    fi

    # Register that data has changed for mod_tile caching purposes
    sudo -u renderer touch /data/database/planet-import-complete

    service postgresql stop

    exit 0
fi

if [ "$1" == "run" ]; then
    # Clean /tmp
    rm -rf /tmp/*

    # migrate old files
    if [ -f /data/database/PG_VERSION ] && ! [ -d /data/database/postgres/ ]; then
        mkdir /data/database/postgres/
        mv /data/database/* /data/database/postgres/
    fi
    if [ -f /nodes/flat_nodes.bin ] && ! [ -f /data/database/flat_nodes.bin ]; then
        mv /nodes/flat_nodes.bin /data/database/flat_nodes.bin
    fi
    if [ -f /data/tiles/data.poly ] && ! [ -f /data/database/region.poly ]; then
        mv /data/tiles/data.poly /data/database/region.poly
    fi

    # sync planet-import-complete file
    if [ -f /data/tiles/planet-import-complete ] && ! [ -f /data/database/planet-import-complete ]; then
        cp /data/tiles/planet-import-complete /data/database/planet-import-complete
    fi
    if ! [ -f /data/tiles/planet-import-complete ] && [ -f /data/database/planet-import-complete ]; then
        cp /data/database/planet-import-complete /data/tiles/planet-import-complete
    fi

    # Fix postgres data privileges
    chown -R postgres: /var/lib/postgresql/ /data/database/postgres/

    # Configure Apache CORS
    if [ "${ALLOW_CORS:-}" == "enabled" ] || [ "${ALLOW_CORS:-}" == "1" ]; then
        echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" >> /etc/apache2/envvars
    fi

    # Initialize PostgreSQL and Apache
    createPostgresConfig
    service postgresql start
    service apache2 restart
    setPostgresPassword

    # Configure renderd threads
    sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS:-4}/g" /etc/renderd.conf

    # start cron job to trigger consecutive updates
    if [ "${UPDATES:-}" == "enabled" ] || [ "${UPDATES:-}" == "1" ]; then
        /etc/init.d/cron start
        sudo -u renderer touch /var/log/tiles/run.log; tail -f /var/log/tiles/run.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/osmosis.log; tail -f /var/log/tiles/osmosis.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/expiry.log; tail -f /var/log/tiles/expiry.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/osm2pgsql.log; tail -f /var/log/tiles/osm2pgsql.log >> /proc/1/fd/1 &

    fi

    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sudo -u renderer renderd -f -c /etc/renderd.conf &
    child=$!
    wait "$child"

    service postgresql stop

    exit 0
fi

if [ "$1" == "export" ]; then
    if [ ! -d /data/tiles/default ] || [ -z "$(ls -A /data/tiles/default 2>/dev/null)" ]; then
        echo "ERROR: No tiles found in /data/tiles/default/"
        echo "Render tiles first or mount a tiles volume at /data/tiles."
        exit 1
    fi

    EXPORT_FILE=${EXPORT_FILE:-tiles.mbtiles}
    EXPORT_MINZOOM=${EXPORT_MINZOOM:-0}
    EXPORT_MAXZOOM=${EXPORT_MAXZOOM:-20}

    if [[ "$EXPORT_FILE" = /* ]]; then
        EXPORT_PATH="$EXPORT_FILE"
    else
        EXPORT_PATH="/data/${EXPORT_FILE}"
    fi

    OUTPUT_DIR=$(dirname "$EXPORT_PATH")
    mkdir -p "$OUTPUT_DIR"
    chown renderer: "$OUTPUT_DIR"

    if [ "${EXPORT_MINZOOM}" -gt "${EXPORT_MAXZOOM}" ]; then
        echo "ERROR: EXPORT_MINZOOM must be <= EXPORT_MAXZOOM"
        exit 1
    fi

    EXPORT_TILES_DIR="/tmp/tiles-export"
    rm -rf "${EXPORT_TILES_DIR}"
    mkdir -p "${EXPORT_TILES_DIR}"

    copied=$(python3 - <<'PY'
import math
import os
import shutil
import struct
import sys

src_root = "/data/tiles/default"
dst_root = "/tmp/tiles-export"
min_zoom = int(os.environ.get("EXPORT_MINZOOM", "0"))
max_zoom = int(os.environ.get("EXPORT_MAXZOOM", "20"))

def in_range(z):
    return min_zoom <= z <= max_zoom

def ensure_parent(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)

count = 0

for root, _, files in os.walk(src_root):
    for name in files:
        path = os.path.join(root, name)
        if name.endswith(".png"):
            rel = os.path.relpath(path, src_root)
            parts = rel.split(os.sep)
            try:
                z = int(parts[0])
            except (ValueError, IndexError):
                continue
            if not in_range(z):
                continue
            dst = os.path.join(dst_root, rel)
            ensure_parent(dst)
            shutil.copy2(path, dst)
            count += 1
            continue

        if not name.endswith(".meta"):
            continue

        with open(path, "rb") as f:
            header = f.read(20)
            if len(header) < 20:
                continue
            magic, entry_count, x, y, z = struct.unpack("<4siiii", header)
            if magic not in (b"META", b"METZ"):
                continue
            if magic == b"METZ":
                # Compressed meta tiles are not supported here.
                continue
            if entry_count <= 0:
                continue
            if not in_range(z):
                continue

            entry_bytes = f.read(entry_count * 8)
            if len(entry_bytes) < entry_count * 8:
                continue
            f.seek(0)
            data = f.read()

        meta_size = int(math.sqrt(entry_count))
        if meta_size * meta_size != entry_count:
            continue

        for idx in range(entry_count):
            off, size = struct.unpack_from("<ii", entry_bytes, idx * 8)
            if size <= 0:
                continue
            tx = x + (idx // meta_size)
            ty = y + (idx % meta_size)
            dst = os.path.join(dst_root, str(z), str(tx), f"{ty}.png")
            ensure_parent(dst)
            with open(dst, "wb") as out:
                out.write(data[off:off + size])
            count += 1

print(count)
PY
)

if [ "${copied}" -eq 0 ]; then
    echo "ERROR: No tiles found in zoom range ${EXPORT_MINZOOM}-${EXPORT_MAXZOOM}"
    exit 1
fi

    echo "Exporting tiles from ${EXPORT_TILES_DIR} to ${EXPORT_PATH}"
    echo "Zoom levels: ${EXPORT_MINZOOM} to ${EXPORT_MAXZOOM}"

    sudo -u renderer mb-util \
        --scheme=xyz \
        --image_format=png \
        "${EXPORT_TILES_DIR}" \
        "${EXPORT_PATH}"

    chown renderer: "${EXPORT_PATH}"
    echo "Successfully exported tiles to ${EXPORT_PATH}"
    ls -lh "${EXPORT_PATH}"

    exit 0
fi

echo "invalid command"
exit 1
