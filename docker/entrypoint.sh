#!/bin/sh
# PgKeeper container entrypoint.
#
#   daemon            run scheduled backups in-process (default CMD)
#   daemon-with-web   daemon + web dashboard together in one container
#   <anything else>   passed straight to the pgkeeper CLI (backup, doctor, ...)
#
# Config comes from /etc/pgkeeper/pgkeeper.yml (mounted by the operator); the
# CLI finds it there without a -c flag.
set -e

pgkeeper() {
  exec bundle exec ruby -Ilib bin/pgkeeper "$@"
}

case "$1" in
daemon-with-web)
  # The dashboard rides alongside the daemon. It refuses to start without
  # auth configured (web.auth in the config); inside a container it must bind
  # 0.0.0.0 for a published port to reach it — set web.bind accordingly.
  bundle exec ruby -Ilib bin/pgkeeper web &
  web_pid=$!
  # If either process dies, take the container down so the orchestrator
  # notices — a silently dead scheduler is the failure mode PgKeeper exists
  # to prevent.
  trap 'kill "$web_pid" 2>/dev/null' EXIT INT TERM
  bundle exec ruby -Ilib bin/pgkeeper daemon
  ;;
*)
  pgkeeper "$@"
  ;;
esac
