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

# The Bundler this era gets. Not "latest": Bundler 2.x does not run on 2.1 or 2.2 at all,
# and Bundler 1.x cannot read a lockfile written by the modern bundler that a later era's
# application arrives with. Each entry of the matrix names its own version.
ARG BUNDLER=2.6.9

# **Which Debian release this base is, and how to reach its packages, is read out of the
# image rather than passed in.** It was build arguments once, and two of them were wrong the
# first time they were exercised: `ruby:2.5` is a *buster* base (its `VERSION_CODENAME` says
# so, and its glibc is 2.28), `ruby:2.7` is bullseye, and the 3.2/3.3 tags have moved to
# trixie. A matrix carrying an `os` column was a second copy of a fact the image owns, and
# it disagreed with the image exactly where it mattered — apt pointed at the wrong release
# answers "Unable to correct problems, you have held broken packages", which reads as a
# broken package list rather than as a wrong distribution name.
#
# The rule the image gets: every Debian at or below bullseye has moved to
# `archive.debian.org` — their Release files have expired, so `Check-Valid-Until` goes off,
# and their packages are unsigned now, so apt has to be told to take them. jessie through
# buster spell their security suite `<codename>/updates`; bullseye spells it
# `bullseye-security`. bookworm and later are still served normally and their own sources
# are left alone. jessie's `/etc/os-release` predates `VERSION_CODENAME`, which is why the
# numeric file is the fallback rather than the other way round.
#
# The packages, and the reason each is here:
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
#   Era-matched by the distribution the image turned out to be: 9.4 on jessie, 11 on buster,
#   13 on bullseye, 17 on trixie.
# * `redis-server` — Resque, Sidekiq and cache stores, and the same localhost argument.
# * `imagemagick`, `libmagickwand-dev` — `rmagick` and ImageMagick-backed uploaders. The
#   distro's own version, which is the version the era's gems were written against (IM6 on
#   every base here).
# * `nodejs` — an ExecJS runtime for `uglifier` and friends, so an asset-pipeline build in
#   the era does not depend on `therubyracer` compiling.
# * `ca-certificates` — HTTPS to rubygems.org from an OpenSSL old enough that the trust
#   store, not the protocol, is what breaks first.
RUN set -eux; \
    codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"; \
    if [ -z "$codename" ]; then \
      case "$(cat /etc/debian_version)" in \
        8*) codename=jessie ;; \
        9*) codename=stretch ;; \
        10*) codename=buster ;; \
        11*) codename=bullseye ;; \
        12*) codename=bookworm ;; \
        13*) codename=trixie ;; \
      esac; \
    fi; \
    case "$codename" in \
      jessie|stretch|buster|bullseye) \
        if [ "$codename" = "bullseye" ]; then security="bullseye-security"; else security="$codename/updates"; fi; \
        printf 'deb http://archive.debian.org/debian %s main\n' "$codename" > /etc/apt/sources.list; \
        printf 'deb http://archive.debian.org/debian-security %s main\n' "$security" >> /etc/apt/sources.list; \
        printf 'Acquire::Check-Valid-Until "false";\nAcquire::AllowInsecureRepositories "true";\nAPT::Get::AllowUnauthenticated "true";\n' \
          > /etc/apt/apt.conf.d/99agents-fyi-archive; \
        rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources || true; \
        ;; \
    esac; \
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
#
# The services and the start script, as one copy each: the walker calls the services script
# by name and the start script is what every container begins with. Both are shell, both are
# argument-free by design (the values they need are environment variables the walker sets),
# and both carry the failure that found each of their paragraphs.
COPY services.sh /usr/local/bin/agents-fyi-services
COPY start.sh /usr/local/bin/agents-fyi-start
# **`install` cannot chmod a large file on Docker Desktop's bind mounts, and a gem's build is where
# that lands.** Measured on the lighthouse's 6.0 rung: `make install` building `sassc` (which
# `sass-rails 6` brings in) died on `setting permissions for '.gem.…/sassc/libsass.so': Operation not
# permitted` — for a file of about three megabytes, in a directory where a three-byte file installed
# cleanly and `cp` plus `chmod` on the same large file succeeded. The command is mkmf's, taken from
# `RbConfig`, so the walker cannot configure it away — and the whole rung is reported `unverified`
# when a gem's build fails. `install.rb` is the real binary whenever the real binary works, and the
# same operation done with `cp` and `chmod` when it does not.
COPY install.rb /usr/local/bin/agents-fyi-install
RUN mv /usr/bin/install /usr/bin/install.coreutils \
    && cp /usr/local/bin/agents-fyi-install /usr/bin/install \
    && chmod +x /usr/bin/install /usr/bin/install.coreutils
# The `database.yml` reader is a file of its own rather than a heredoc inside `services.sh`,
# and the reason is testability: which roles a database needs, and with what password, is a
# rule — and a rule inside a shell heredoc is a rule no test can run. It is executed by the
# *container's* Ruby, which is the era's, so it is written for Ruby 2.1 (`test/dbconfig_test.rb`
# drives it on the host and the era images are the proof that 2.1 parses it).
COPY dbconfig.rb /usr/local/bin/agents-fyi-dbconfig
RUN chmod +x /usr/local/bin/agents-fyi-services /usr/local/bin/agents-fyi-start \
    /usr/local/bin/agents-fyi-dbconfig

# The two directories the container's own environment points at, created here for the *named
# volume* case — Docker seeds an empty volume from the image, so these arrive with it. A
# bind mount shadows them, and the walker creates them on its side for exactly that reason
# (`Machine::Container#start!`, and the first real application's "`/agents-fyi/home` is not a
# directory" is where that came from).
RUN mkdir -p /agents-fyi/home /agents-fyi/tmp
