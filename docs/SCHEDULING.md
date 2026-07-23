# Scheduling automated jobs

PgKeeper turns a `schedule:` in your config into unattended, recurring jobs. It does **not**
invent its own always-on scheduler daemon that you have to trust — instead it renders the
schedule into whatever your host already runs: **cron**, **systemd timers**, or, for
containers that have neither, a built-in **`pgkeeper daemon`**. The same resolved schedule
drives all three, so you pick the mechanism that fits the box, not the other way around.

Three job *types* are scheduled, not just backups:

| Job | Command | Why it's scheduled |
|-----|---------|--------------------|
| **backup** | `pgkeeper backup` | the dump → compress → encrypt → fan-out pipeline |
| **verify** | `pgkeeper verify [--deep]` | a backup you never restored isn't a backup — prove it |
| **prune**  | `pgkeeper prune [--apply]` | enforce retention so storage doesn't grow forever |

Verify and prune come from a `maintenance:` block so upkeep runs unattended like the backup
itself, rather than as forgotten hand-wired cron lines.

## 1. Configure the schedule

Set a global `schedule:` and let any database override it with its own. Add a
`maintenance:` block to schedule verify and prune too:

```yaml
schedule: daily at 03:15          # global default for every database

databases:
  - name: app
    host: db.internal
    username: backup_user
    password: <%= ENV["PGKEEPER_APP_PASSWORD"] %>
    format: custom
    # inherits the global 03:15 schedule

  - name: analytics
    host: db.internal
    username: backup_user
    password: <%= ENV["PGKEEPER_APP_PASSWORD"] %>
    format: directory
    schedule: every 6 hours       # this DB overrides the global schedule

maintenance:
  verify:
    schedule: weekly on sunday at 04:00
    deep: true                    # Tier-3: restore into a throwaway scratch database
  prune:
    schedule: daily at 05:00
    apply: true                   # actually delete (omit/false = dry-run only)
```

**Resolution rule:** if *any* database declares its own `schedule:`, each database is
scheduled independently (falling back to the global schedule when it has none). If *no*
database overrides it, a single global schedule backs up every database together in one run.

### Schedule expression syntax

Every expression normalizes to a 5-field cron string, so you can write whichever is
clearest:

| Style | Examples |
|-------|----------|
| Shorthand words | `hourly`, `daily`, `nightly`, `weekly`, `monthly`, `yearly` |
| Friendly phrases | `daily at 03:15`, `weekly on sunday at 04:00` |
| Natural language | `every day at 03:15`, `every monday at 9am`, `every 6 hours`, `every 15 minutes` |
| Raw cron | `15 3 * * *` |

## 2. See the resolved plan — `pgkeeper schedule print`

Before installing anything, print exactly what will run. Each line shows the job, its
cadence, the normalized cron, any flags, and which databases it targets:

```console
$ pgkeeper schedule print -c pgkeeper.yml
backup app: daily at 03:15 (cron: 15 3 * * *) (--only app)
backup analytics: every 6 hours (cron: 0 0,6,12,18 * * *) (--only analytics)
verify all: weekly on sunday at 04:00 (cron: 0 4 * * 0) --deep (all databases)
prune all: daily at 05:00 (cron: 0 5 * * *) --apply (all databases)
```

## 3. Install into cron — `pgkeeper schedule install`

The default installer renders crontab lines. Every line is **`flock -n`-guarded** with a
per-job lock so a slow run never overlaps its next tick, and appends stdout/stderr to a log
file so failures aren't lost to cron's mail-to-nowhere default:

```console
$ pgkeeper schedule install -c pgkeeper.yml
# pgkeeper managed
15 3 * * * /usr/bin/flock -n /var/backups/pgkeeper/.cron-app.lock pgkeeper backup --config /etc/pgkeeper/pgkeeper.yml --only app >> /var/backups/pgkeeper/pgkeeper.log 2>&1
0 0,6,12,18 * * * /usr/bin/flock -n /var/backups/pgkeeper/.cron-analytics.lock pgkeeper backup --config /etc/pgkeeper/pgkeeper.yml --only analytics >> /var/backups/pgkeeper/pgkeeper.log 2>&1
0 4 * * 0 /usr/bin/flock -n /var/backups/pgkeeper/.cron-verify-all.lock pgkeeper verify --config /etc/pgkeeper/pgkeeper.yml --deep >> /var/backups/pgkeeper/pgkeeper.log 2>&1
0 5 * * * /usr/bin/flock -n /var/backups/pgkeeper/.cron-prune-all.lock pgkeeper prune --config /etc/pgkeeper/pgkeeper.yml --apply >> /var/backups/pgkeeper/pgkeeper.log 2>&1
```

Notice each job gets its **own** lock file (`.cron-app.lock`, `.cron-verify-all.lock`, …) so
independent jobs don't block each other, but two ticks of the *same* job can never run
concurrently. Pipe the output into your crontab:

```sh
pgkeeper schedule install -c pgkeeper.yml | crontab -
```

## 4. Install as systemd timers — `--systemd`

On modern Linux, timers are preferable: journald captures the logs, `Persistent=true`
catches up a run missed while the box was off, and `RandomizedDelaySec` staggers multiple
databases so they don't all hit the server at once. Each job installs as an independent
`.service` + `.timer` pair:

```console
$ pgkeeper schedule install -c pgkeeper.yml --systemd --jitter 300 --output /etc/systemd/system
Wrote 8 unit file(s) to /etc/systemd/system
Enable with: systemctl daemon-reload && systemctl enable --now pgkeeper-backup-app.timer pgkeeper-backup-analytics.timer pgkeeper-verify-all.timer pgkeeper-prune-all.timer
```

A generated pair (`--jitter 300` adds the stagger):

```ini
# ===== pgkeeper-backup-app.service =====
[Unit]
Description=PgKeeper backup (app)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pgkeeper backup --config /etc/pgkeeper/pgkeeper.yml --only app

# ===== pgkeeper-backup-app.timer =====
[Unit]
Description=PgKeeper backup timer (app)

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

The cron cadence is translated to systemd `OnCalendar` — `every 6 hours` becomes
`OnCalendar=*-*-* 0,6,12,18:00:00`, and `weekly on sunday` becomes
`OnCalendar=Sun *-*-* 04:00:00`. Drop `--output` to print the units to stdout instead of
writing them.

## 5. No cron or systemd? Run the daemon — `pgkeeper daemon`

For containers, `pgkeeper daemon` runs every schedule in-process: it computes each job's next
fire time, sleeps until the soonest, runs the due job (isolated so one failure doesn't stop
the loop), and repeats. `--jitter` adds a random stagger before each run.

```sh
pgkeeper daemon -c pgkeeper.yml --jitter 300
```

This is what the Docker image runs by default, alongside the dashboard. See
`docker-compose.example.yml`.

## 6. Catch a schedule that silently never runs

The worst backup failure is the one where the scheduler itself stops and no backup — and no
failure email — ever fires. Configure a **dead-man's switch** so an external monitor alarms
when an expected run goes missing:

```yaml
notifications:
  deadmans_switch:
    url: https://hc-ping.com/<uuid>   # healthchecks.io, Uptime Kuma, Cronitor, ...
```

A missed ping is caught by the monitor even when the host is wedged and PgKeeper can't send
anything itself.

## See also

- [USAGE.md](USAGE.md) — the full command reference.
- [RPO-RTO.md](RPO-RTO.md) — pick a backup frequency that matches your tolerable data loss.
- [`config/pgkeeper.example.yml`](../config/pgkeeper.example.yml) — the annotated `schedule:`
  and `maintenance:` blocks.
