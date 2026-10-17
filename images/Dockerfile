# An era interpreter: the machine one step of a very old application executes on.
#
# The upgrader itself runs on one Ruby (the image in `../Dockerfile`), and it always will —
# its code is written in the language of Ruby 3. A *step*, though, installs a real
# application's bundle and boots it, and an application old enough to be interesting cannot
# be installed on Ruby 3.3 at all: `json 1.7.7` does not compile there, `libv8` does not
# build, and Rails 4 references constants Ruby removed in 3.2. So each era is its own image,
# and this Dockerfile is the one place they are described.
#
# It is parameterised rather than copied five times, because five copies of an apt list
# drift the first time a package is added: the matrix
# (`../lib/agents_fyi/upgrader/data/interpreters.json`) is the data, and
# `scripts/upgrader-images.sh` turns each entry into one `docker build` of this file. The
# default `BASE_IMAGE` is empty on purpose — a build that did not say which interpreter it
# is building fails at the `FROM` line with Docker's own sentence rather than silently
# producing a second Ruby 3.2 image under a different tag.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Which Debian release this base is, and how to reach it. jessie, stretch and buster have
# moved to `archive.debian.org` and their Release files have expired, so a build against
# the live mirrors fails with 404s and a build against the archive needs
# `Check-Valid-Until` turned off. bookworm is still served normally.
ARG APT_SUITE=bookworm
ARG APT_ARCHIVE=0

# The Bundler this era gets. Not "latest": Bundler 2.x does not run on 2.1 or 2.2 at all,
# and Bundler 1.x cannot read a lockfile written by the modern bundler that a later era's
# application arrives with. Each entry of the matrix names its own version.
ARG BUNDLER=2.6.9

# The packages a Rails application's bundle and suite need, and the reason each is here:
#
# * `build-essential`, `pkg-config` — native gems with no prebuilt binary (`libv8`,
#   `rmagick`, `json` in the old eras, `pg` everywhere). An era image without a compiler is
#   an image that cannot install the applications it exists for.
# * `libpq-dev` — the `pg` gem's headers.
# * `libyaml-dev`, `libssl-dev`, `zlib1g-dev`, `libreadline-dev` — psych, OpenSSL, gzip and
#   IRB: the four every Ruby build and most C extensions reach for.
# * `libsqlite3-dev`, `libxml2-dev`, `libxslt1-dev`, `libcurl4-openssl-dev` — sqlite3,
#   nokogiri's native build, and gems that curl an API at compile time.
# * `postgresql`, `postgresql-client` — the database the suite runs against, *inside* the
#   container. That is a deliberate choice over a sibling container: a 2013 application's
#   `database.yml` says `localhost`, and a service on a Docker network is not localhost.
#   Era-matched by the distro: 9.4 on jessie, 9.6 on stretch, 11 on buster, 15 on bookworm.
# * `redis-server` — Resque, Sidekiq and cache stores, and the same localhost argument.
# * `imagemagick`, `libmagickwand-dev` — `rmagick` and ImageMagick-backed uploaders. The
#   distro's own version, which is the version the era's gems were written against (IM6 on
#   every base here, including bookworm).
# * `nodejs` — an ExecJS runtime for `uglifier` and friends, so an asset-pipeline build in
#   the era does not depend on `therubyracer` compiling.
# * `ca-certificates` — HTTPS to rubygems.org from an OpenSSL old enough that the trust
#   store, not the protocol, is what breaks first.
RUN set -eux; \
    if [ "$APT_ARCHIVE" = "1" ]; then \
      printf 'deb http://archive.debian.org/debian %s main\n' "$APT_SUITE" > /etc/apt/sources.list; \
      printf 'deb http://archive.debian.org/debian-security %s/updates main\n' "$APT_SUITE" >> /etc/apt/sources.list; \
      printf 'Acquire::Check-Valid-Until "false";\nAcquire::AllowInsecureRepositories "true";\nAPT::Get::AllowUnauthenticated "true";\n' \
        > /etc/apt/apt.conf.d/99agents-fyi-archive; \
      rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources || true; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential pkg-config \
      libpq-dev libyaml-dev libssl-dev zlib1g-dev libreadline-dev \
      libsqlite3-dev libxml2-dev libxslt1-dev libcurl4-openssl-dev \
      postgresql postgresql-client redis-server \
      imagemagick libmagickwand-dev nodejs ca-certificates; \
    rm -rf /var/lib/apt/lists/*

RUN gem install bundler -v "$BUNDLER" --no-document

# **The libpq socket default is `/var/run/postgresql`, and it must exist for an application
# that names no host to connect at all.** Rails' own generated `database.yml` before 6.0 has
# no `host:`, which means the Unix socket at the directory libpq was *compiled* with — and
# the server this image starts runs as the walker's uid, which does not own that directory.
#
# It is **not** created here, and that is a correction rather than a preference: `/run` is a
# tmpfs the container runtime mounts over this image's, so a directory or symlink made at
# build time is gone by the first start. It is `start.sh`'s job — the container's only root
# process — and it is where the comment about the failure lives.
# The services and the start script, as one copy each: the walker calls the services script
# by name and the start script is what every container begins with. Both are shell, both are
# argument-free by design (the values they need are environment variables the walker sets),
# and both carry the failure that found each of their paragraphs.
COPY services.sh /usr/local/bin/agents-fyi-services
COPY start.sh /usr/local/bin/agents-fyi-start
RUN chmod +x /usr/local/bin/agents-fyi-services /usr/local/bin/agents-fyi-start

# The one directory a step's commands are told about: the walker mounts its home here
# (`Machine::CONTAINER_ROOT`), and everything a step does — the worktree, the bundle, the
# databases' log files — is under it or inside the container. Created so a bind mount onto
# it is over a directory the image knows, which is the same rule the upgrader's own image
# documents for its volumes.
RUN mkdir -p /agents-fyi/home /agents-fyi/tmp
