# PgKeeper runtime image.
#
# Ships the CLI with the PostgreSQL client tools it shells out to. By default it
# runs the in-process scheduler (`pgkeeper daemon`); override the command to run
# one-off `backup` / `verify` / `restore` invocations.
#
#   docker build -t pgkeeper .
#   docker run --rm -v $PWD/pgkeeper.yml:/app/pgkeeper.yml:ro pgkeeper doctor -c /app/pgkeeper.yml
FROM ruby:4.0-slim-bookworm

# postgresql-client provides pg_dump/pg_restore/pg_dumpall/psql (the tools
# PgKeeper drives); the rest are runtime libs. Native gems (sqlite3) need a
# compiler at build time only, so build-essential is installed and removed in
# the same layer that runs bundle install (see below).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      postgresql-client \
      libsqlite3-0 \
      ca-certificates \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install gems in their own layer so code changes don't bust the dependency
# cache. The gemspec is evaluated during `bundle install`, so the files it reads
# (version.rb) must be present.
COPY Gemfile pgkeeper.gemspec ./
COPY lib/pgkeeper/version.rb ./lib/pgkeeper/version.rb
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libsqlite3-dev \
 && bundle config set --local without 'development test' \
 && bundle install \
 && apt-get purge -y --auto-remove build-essential libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/* /usr/local/bundle/cache

COPY . .

# Local staging + default backup destination; mount a volume here to persist.
ENV PGKEEPER_WORKDIR=/var/backups/pgkeeper
RUN mkdir -p "$PGKEEPER_WORKDIR"
VOLUME ["/var/backups/pgkeeper"]

# Run as a non-root user.
RUN useradd --system --create-home --home-dir /home/pgkeeper pgkeeper \
 && chown -R pgkeeper:pgkeeper /app "$PGKEEPER_WORKDIR"
USER pgkeeper

ENTRYPOINT ["bundle", "exec", "pgkeeper"]
CMD ["--help"]
