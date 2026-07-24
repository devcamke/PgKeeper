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
  bundle exec ruby -Ilib bin/pgkeeper daemon &
  daemon_pid=$!

  # Forward shutdown to both children — the daemon traps TERM and exits
  # cleanly between jobs. POSIX sh defers traps while a foreground command
  # runs, so the watch loop below sleeps in the *background* to stay
  # interruptible (a plain `wait $daemon_pid` would swallow the signal until
  # the daemon exited on its own, i.e. never).
  trap 'kill -TERM "$web_pid" "$daemon_pid" 2>/dev/null' INT TERM

  # If either process dies, take the container down so the orchestrator
  # notices — a silently dead scheduler *or dashboard* is the failure mode
  # PgKeeper exists to prevent.
  while kill -0 "$web_pid" 2>/dev/null && kill -0 "$daemon_pid" 2>/dev/null; do
    sleep 1 &
    wait $! || true
  done

  kill -TERM "$web_pid" "$daemon_pid" 2>/dev/null || true
  daemon_status=0
  wait "$daemon_pid" || daemon_status=$?
  wait "$web_pid" || true
  exit "$daemon_status"
  ;;
*)
  pgkeeper "$@"
  ;;
esac
