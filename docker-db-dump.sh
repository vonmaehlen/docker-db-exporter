#!/bin/sh

#The MIT License (MIT)
#
# Copyright (c) 2024 Vonmählen GmbH
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the “Software”), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# of the Software, and to permit persons to whom the Software is furnished to do
# so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -eu

backup_dir="$(pwd)/_db_backups"

# list of containers, that must be backed up. One name per line.
containers="shop-next-database"

# list of containers, that should not be backed up. One name per line.
ignored_containers="shop-next-web
traefik
"
# number of dumps to keep per container
keep=4

main() {
    info "Backup Directory: $backup_dir"

    for con_id in $(docker_database_container_ids); do
        con_name=$(dcon_name "$con_id")

        info "Backup [$con_name] begins"

        backup_file="${backup_dir:-.}/$con_name/$(date -Idate)/$con_name-$(date -Iseconds).sql"
        backup_pipe="/tmp/$(basename "$backup_file")"
        mkdir -p "$(dirname "$backup_file")"

        if cmd_exists "zstd"; then
            compressor="zstd"
            backup_file="$backup_file.zst"
        elif cmd_exists "gzip"; then
            compressor="gzip"
            backup_file="$backup_file.gz"
        elif cmd_exists "zip"; then
            compressor="zip"
            backup_file="$backup_file.zip"
        else
            compressor="cat"
        fi

        # use a named pipe so we can check if the command was successfull
        # before writing anything to a file. To do so, we have to spawn a
        # process to read from the pipe, so writing to is is not blocking AND
        # we can check it's exit code with $?.
        rm "$backup_pipe" >/dev/null 2>&1 || true; mkfifo "$backup_pipe"
        $compressor < "$backup_pipe"> "$backup_file.part" &

        if docker_dump_db "$con_id" > "$backup_pipe"; then
            debug "Create file $(basename "$backup_file")"
            mv "$backup_file.part" "$backup_file"
            rm "$backup_pipe";
        else
            err "Backup [$(dcon_name "$con_id")] failed"
            rm "$backup_file.part"
            rm "$backup_pipe";
        fi

        # prune partial backup files
        find "${backup_dir:-.}/" -type f -name '*.part' -delete

        if [ -n "${keep:-}" ]; then
            old_backups=$(find "${backup_dir:-.}/$con_name/" -type f -not -name "*.part" | sort | head -n -"${keep:-64}")
            for old_file in $old_backups; do
                debug "Prune $(basename "$old_file")"
                rm "$old_file"
            done
        fi

        old_backup_dirs=$(find "${backup_dir:-.}/$con_name/" -type d -empty)
        for old_dir in $old_backup_dirs; do
            debug "Prune $old_dir"
            rmdir "$old_dir"
        done

    done

    info "All backups completed"
}

log() {
    echo "$@" >/dev/stderr
}

debug() {
    if [ -n "${VERBOSE:-}" ]; then log "DEBUG:" "$@"; fi
}

info() {
    log "\033[32mINFO\033[0m:" "$@"
}

err() {
    log "\033[31mERR\033[0m: " "$@"
}

warn() {
    log "\033[33mWARN\033[0m:" "$@"
}

contains() {
    # if echo $ignored_containers | grep -q "$con_name"; then continue; fi
    test "${1#*"$2"}" != "$1"
    return $?
}

cmd_exists() {
    command -v "$1" >/dev/null 2>&1
    return $?
}

dcon_has_cmd() {
    docker exec "$1" "$2" --help >/dev/null 2>&1
    return $?
}

dcon_image() {
    docker inspect --format "{{ .Config.Image }}" "$1"
}

dcon_name() {
    docker inspect --format "{{ .Name }}" "$1" | sed 's;/;;'
}

dcon_status() {
    docker inspect --format "{{ .State.Status }}" "$1"
}

docker_database_container_ids() {
    matches=""

    for con_id in $(docker ps -q --all); do
        con_name=$(dcon_name "$con_id")

        # must use a known image
        case $(dcon_image "$con_id") in
            *mysql*|*mariadb*|*postgres*)
                true
                ;;
            *)
                continue
                ;;
        esac

        # must not be ignored
        contains "$ignored_containers" "$con_name" && {
            debug "$con_name is ignored. Skipping."
            continue
        }

        # should be allowed
        contains "$containers" "$con_name" || {
            warn "$con_name is not configured. Skipping."
            continue
        }

        matches="$matches$con_name\n"
    done

    # strip last newline
    matches=$(echo "$matches" | head -c -1)

    for con_name in $containers; do
        contains "$matches" "$con_name" || {
            err "$con_name not found"
        }
    done

    for con_name in $matches; do
        con_status=$(dcon_status "$con_name")

        # must be running
        case "$con_status" in
            "running")
                true
                ;;
            "stopped"|"exited"|*)
                warn "$con_name is $con_status. Skipping backup."
                continue
                ;;
        esac

        debug "$con_name found"
        docker inspect --format "{{ .ID }}" "$con_name"
    done
}

docker_dump_db() {
    env_vars=$(docker exec -t "$1" env)

    if dcon_has_cmd "$1" "mariadb-dump"; then
        debug "detected mariadb-dump"

        if contains "$env_vars", "MYSQL_ROOT_PASSWORD"; then
            docker exec "$1" sh -c 'mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases' || return $?

        elif contains "$env_vars", "MARIADB_ROOT_PASSWORD"; then
            docker exec "$1" sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --all-databases' || return $?

        else
            err "mariadb without MARIADB_ROOT_PASSWORD env var is not supported"
            return 1
        fi

    elif dcon_has_cmd "$1" "mysqldump"; then
        debug "detected mysqldump"

        if contains "$env_vars", "MYSQL_ROOT_PASSWORD"; then
            docker exec "$1" sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases' || return $?

        else
            err "mysql without MYSQL_ROOT_PASSWORD env var is not supported"
            return 1
        fi

    elif dcon_has_cmd "$1" "pg_dumpall"; then
        docker exec "$1" sh -c 'pg_dumpall -U "$POSTGRES_USER"' || return $?

    else
        err "Failed to determine database type or container has no supported dump utility!"
        return 1
    fi
}

main
