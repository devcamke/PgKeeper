# PgKeeper container image: the CLI, the scheduling daemon, and the optional
# web dashboard in one image.
#
#   docker build -t pgkeeper .
#   docker run --rm -v ./pgkeeper.yml:/etc/pgkeeper/pgkeeper.yml:ro pgkeeper doctor
#
# See docker-compose.example.yml for a full deployment (daemon + dashboard
# alongside a database) and docs/SECURITY.md before shipping dumps anywhere.
#
# The base image's PostgreSQL client tools must be at least as new as the
# servers being dumped (pg_dump refuses to dump a newer server). Debian's
# postgresql-client tracks the distro; pin the PGDG repo here if your servers
# are newer than what the base image ships.
FROM ruby:4.0-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    build-essential \
    libyaml-dev \
    zstd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install gems first so source edits don't bust the dependency layer. The
# development/test groups stay out of the image; web (rack + puma) and cloud
# (aws-sdk-s3) stay in so the dashboard and S3 destinations work.
COPY Gemfile pgkeeper.gemspec ./
COPY lib/pgkeeper/version.rb lib/pgkeeper/version.rb
RUN bundle config set --local without "development test" && bundle install

COPY . .

# Config is read from /etc/pgkeeper/pgkeeper.yml (a default search path of the
# CLI) — mount it there. Backups and run history live under /var/backups/pgkeeper.
VOLUME /var/backups/pgkeeper
EXPOSE 8321

ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["daemon"]
