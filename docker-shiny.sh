#!/bin/bash
# Shiny Server sanitizes the environment it passes to R application processes,
# so container-level configuration (compose env_file, docker -e, ...) must be
# written to .Renviron for the apps to see it.
set -euo pipefail

env_file="/srv/shiny-server/.Renviron"
exclude_pattern="^(PATH|HOME|HOSTNAME|USER|LOGNAME|SHELL|PWD|OLDPWD|TERM|SHLVL|LANG|LANGUAGE|TZ|_|container)=|^(LC|DOCKER|KUBERNETES)_[^=]*="

tmp_file="$(mktemp "${env_file}.XXXXXX")"
env | grep -vE "${exclude_pattern}" > "${tmp_file}" || true
chmod 600 "${tmp_file}"
mv -f "${tmp_file}" "${env_file}"

xtail /var/log/shiny-server/ &
exec shiny-server 2>&1
