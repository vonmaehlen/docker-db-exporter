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

containers=""
ignored_containers=""

show_help() {
    cat <<EOF
Usage: $(basename "$0") [flags]
  -c, --container <name>    Add container to the list of backup-tasks.
  -s, --skip <name>         Do not warn that the container is not backed up.
  -d, --backup-dir <path>   Directory to store backups. Default: ./_db_backups
  -n, --keep <count>        Number of backups to keep per container. Default: 4
      --ping <url>          Send a heartbeat after the command ran.
      --ping-error <url>    Send a heartbeat if the command (partially) failed.
      --ping-success <url>  Send a heartbeat if the command succeeded.
  -h, --help                Print this help message and exit.
  -v, --verbose             Increase logging.
EOF
}

main() {
    exit_code=0
    backup_dir="$(pwd)/_db_backups"
    keep=4
    pings_failure=""
    pings_success=""

    # parse flags in front of positional args
    while printf "%s" "${1:-}" | grep -q ^-; do
        case "$1" in
            -c|--container) containers="$containers $2 "; shift; shift;;
            -d|--backup-dir) backup_dir=$2; shift; shift;;
            -h|--help|"-?") show_help; exit 0;;
            -n|--keep) keep=$2; shift; shift;;
            --ping) pings_success="$pings_success $2"; pings_failure="$pings_failure $2"; shift; shift;;
            --ping-error) pings_failure="$pings_failure $2"; shift; shift;;
            --ping-success) pings_success="$pings_success $2"; shift; shift;;
            -s|--skip) ignored_containers="$ignored_containers $2 "; shift; shift;;
            -v|-vv|-vvv|--verbose) VERBOSE=1; shift;;
            *) err "invalid option: $1"; show_help; exit 127;;
        esac
    done

    info "Backup Directory: $backup_dir"
    debug "keep backups per container: $keep"
    debug "containers: $containers"
    debug "ignored: $ignored_containers"

    if [ -z "$containers" ]; then
        show_help >&2
        echo >&2
        err "No containers selected."
        exit 127
    fi

    if ! con_ids=$(docker_database_container_ids); then
        exit_code=2
    fi

    for con_id in $con_ids; do
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
            exit_code=1
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

    if [ $exit_code -eq 0 ]; then
        pings="$pings_success"
    else
        pings="$pings_failure"
    fi

    if [ -n "$pings" ]; then
        if ! send_heartbeats "$pings"; then
            if [ $exit_code -eq 0 ]; then
                exit_code=120
            fi
        fi
    fi

    info "All backups completed"
    exit $exit_code
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
    error_count=0

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
        contains "$ignored_containers" " $con_name " && {
            debug "$con_name is ignored. Skipping."
            continue
        }

        # should be allowed
        contains "$containers" " $con_name " || {
            warn "$con_name is not configured. Skipping."
            error_count=$((error_count + 1))
            continue
        }

        matches="$matches$con_name\n"
    done

    # strip last newline
    matches=$(echo "$matches" | head -c -1)

    for con_name in $containers; do
        contains "$matches" "$con_name" || {
            err "$con_name not found"
            error_count=$((error_count + 1))
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
                err "$con_name is $con_status. Skipping backup."
                error_count=$((error_count + 1))
                continue
                ;;
        esac

        debug "$con_name found"
        docker inspect --format "{{ .ID }}" "$con_name"
    done

    return $error_count
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

send_heartbeats() {
    if cmd_exists "curl"; then
        heartbeat_cmd="curl"
    elif cmd_exists "wget"; then
        heartbeat_cmd="wget"
    else
        err "One of curl or wget must be installed to send pings"
        return 1
    fi

    err=0
    for ping in "$@"; do
        debug "ping: $ping"
        if ! $heartbeat_cmd "$ping"; then
            err=1
            err "Failed to send ping: $ping"
        fi
    done

    return $err
}

main "$@"
