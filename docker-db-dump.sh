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

backup_dir="$(pwd)/_db_backups"

# list of containers, that must be backed up. One name per line.
containers="shop-next-database"

# list of containers, that should not be backed up. One name per line.
ignored_containers="shop-next-web
traefik
"

main() {
    info "Backup Directory: $backup_dir"
    for con_id in $(docker_database_container_ids); do
        info "Backup $(dcon_name "$con_id") begins"
    done
}

log() {
    echo "$@" >/dev/stderr
}

debug() {
    [ -n "${VERBOSE:-}" ] && log "DEBUG:" "$@"
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

main
