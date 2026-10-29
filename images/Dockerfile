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
# (`../lib/agents/upgrader/data/interpreters.json`) is the data, and
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

# **Before 2.1 there is no official `ruby` image left to start from.** Docker Hub no longer
# serves `ruby:1.9.3` or `ruby:2.0` (nor the `-p551`/`-p648` spellings), and the same is true
# of the community images this was checked against. A Rails 3.2 application that predates
# Ruby 2.0 support cannot be walked without one, so those two eras start from a pinned
# `debian:jessie` and build the interpreter from ruby-lang's source tarball. The empty
# default is what keeps every other era a `FROM ruby:<version>`: a build that did not name a
# source must not silently compile a second copy of an interpreter the base already carries.
#
# **The download is made with `-k` and verified by SHA-256, and the order is the point.**
# jessie's CA bundle predates the chain cache.ruby-lang.org serves now, so a strict TLS
# verification fails on a host whose only job is to compile a 2013 interpreter. The digest
# is the integrity check; TLS would only be a second, and an unavailable, one.
ARG RUBY_SOURCE_URL=
ARG RUBY_SOURCE_SHA256=

# **The browser a live-Debian era ships as its default, pinned, and why the distribution's own is
# not.** bookworm's `chromium` is 156 today and a different number next month, so the pair a step
# drives moves under it — and the application's test stack does not. Measured on the ohana walk:
# the same tree, the same bundle and the same Ruby 3.1 ran **1,557 examples, 0 failures** on
# Chromium 120 and **19 failures** on bookworm's 156, every one of them a `:js` example (one with
# Selenium's own `unhandled inspector error: Node with given id does not belong to the document`).
# The application's `selenium-webdriver 4.0.3` was written for a browser of its own vintage, and a
# baseline the walk cannot run is a rung nobody can measure.
#
# **A browser is project-dependent, so this is the machine's *default* and the declaration decides.**
# `toolchain.chrome` says `pinned` (this pair), `distro` (the release's own package) or nothing,
# which means `pinned` where it exists. A project whose suite needs the newer browser says so; the
# machine states which build it verified rather than leaving the choice to whichever package the
# repository happened to serve that morning.
#
# **Only an era whose Debian is still served by a moving repository needs a pin.** jessie through
# bullseye are rewritten to `archive.debian.org` above, so whatever browser their package list
# holds is already frozen — pinning those would replace the browser the era was measured with,
# not freeze it. bookworm and trixie are live.
#
# Chrome for Testing is Chrome's own downloadable build: no apt repository, no `google-chrome`
# package, and a `chromedriver` that is the same release as the browser it drives.
ARG CHROME_VERSION=120.0.6099.109

# **PhantomJS is the browser an old Capybara/poltergeist suite chooses for itself.** The
# application's `spec_helper` looks for a `phantomjs` executable and uses `:poltergeist` when it
# finds one; without it, 19wu's suite falls back to Firefox, which no era container has. The
# binary is statically linked, so it runs on jessie and every later era; the version is pinned
# because the project is archived, and the digest is the integrity check for a download from a
# host that is no longer the project's main one. `bzip2` is the tarball's decompressor and is not
# in the base image's package list.
#
# **The line is 1.9.8, because 2.1.1 hangs this application's suite rather than driving it.**
# Measured twice on 19wu's 4.0 baseline: poltergeist 1.3.0 starts PhantomJS 2.1.1, reaches the
# first `:js` example, and then both processes sit idle — the browser is alive, the runner has
# been in `visit` for more than fifteen minutes, and no example completes. The 1.9.8 line runs
# the same 393 examples in about three and a half minutes; its one `DeadClient` on
# `group_collaborators_spec` is a startup flake, and the suite after the move passed through the
# same example. Poltergeist 1.3.0 is written for the 1.9 line; the binary is the driver's own.
ARG PHANTOMJS_VERSION=1.9.8
ARG PHANTOMJS_SHA256=a1d9628118e270f26c4ddd1d7f3502a93b48ede334b8585d11c1c3ae7bc7163a

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
# * `cmake` — `rugged` vendors libgit2 and builds it with CMake; `pronto` depends on
#   `rugged`, and an application that keeps its linter in `group :development` (`rubocop`
#   beside `pronto`) makes the whole group load-bearing for its style gate. Measured on the
#   diaspora walk at the 6.1→7.0 rung: every era's `bundle install` died in rugged's build
#   with `cmake: not found`, and the rung was reported unverified — for a build tool, not
#   for the move.
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
# * `mongodb-server` and `mongodb-clients` — MongoMapper, Mongoid and the `mongo` driver, and the
#   same localhost argument again. Debian removed MongoDB after stretch (the SSPL), so the package
#   is installed only where the archive still serves it; `agents-services` starts it only when the
#   application's own lockfile names a Mongo client. Measured on caturday_api: the boot died on
#   `Mongo::ConnectionFailure: Failed to connect to a master node at 127.0.0.1:27017` before the
#   first example, with the application asking for exactly the localhost a step container owns.
# * `imagemagick`, `libmagickwand-dev` — `rmagick` and ImageMagick-backed uploaders. The
#   distro's own version, which is the version the era's gems were written against (IM6 on
#   every base here).
# * `libidn-dev` (or `libidn11-dev` on an older base) — `idn-ruby`, which `twitter-text`
#   requires. The second lighthouse's bundle could not build it: measured, extconf answered
#   `checking for -lidn... no` and the whole rung was unverified for a missing header rather
#   than for the move. The two package names are one fact split by Debian release, so the
#   install tries the current name and falls back to the older one.
# * `nodejs` and `npm`/`yarn` — an ExecJS runtime for `uglifier` and friends, and the
#   package manager the application's own CI uses. A suite that renders a view can import
#   from `node_modules` (the second lighthouse's `perfect-scrollbar`), so the era has to be
#   able to run the `yarn install` the application's lockfile pins.
# * `ca-certificates` — HTTPS to rubygems.org from an OpenSSL old enough that the trust
#   store, not the protocol, is what breaks first.
#
# **`postgresql-17-pgvector` is the one package the Debian release decides.** An application
# whose schema enables the `vector` extension cannot prepare its test database without the
# extension's shared library, and the package name carries the server version. The trixie
# bases here are the PostgreSQL 17 eras; older bases have no package with this name and no
# application in this walk has needed one, so the install is scoped rather than allowed to
# make every era fail.
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
    archived=0; \
    case "$codename" in \
      jessie|stretch|buster|bullseye) \
        archived=1; \
        if [ "$codename" = "bullseye" ]; then security="bullseye-security"; else security="$codename/updates"; fi; \
        printf 'deb http://archive.debian.org/debian %s main\n' "$codename" > /etc/apt/sources.list; \
        printf 'deb http://archive.debian.org/debian-security %s main\n' "$security" >> /etc/apt/sources.list; \
        printf 'Acquire::Check-Valid-Until "false";\nAcquire::AllowInsecureRepositories "true";\nAPT::Get::AllowUnauthenticated "true";\n' \
          > /etc/apt/apt.conf.d/99agents-archive; \
        rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources || true; \
        ;; \
    esac; \
    apt-get update; \
    packages="build-essential pkg-config cmake libpq-dev libyaml-dev libssl-dev zlib1g-dev \
      libreadline-dev libsqlite3-dev libxml2-dev libxslt1-dev libcurl4-openssl-dev \
      postgresql postgresql-client redis-server imagemagick libmagickwand-dev libidn-dev \
      nodejs npm ca-certificates curl unzip bzip2"; \
    # **The distribution's browser is installed here for every era, and for a live one it is not
    # the browser a step uses.** A project's declaration names `chromium` (the package a suite that
    # drives a browser needs), and installing it in the image rather than in the step is what stops
    # every rung of every walk downloading it again. On an archived release this *is* the browser —
    # frozen with the repository — and on a live one it is what a project that says
    # `toolchain.chrome: "distro"` is measured on.
    if [ "$archived" = "0" ]; then packages="$packages chromium chromium-driver"; fi; \
    # **MongoDB is a package only while Debian still serves it.** jessie and stretch carry the
    # 2.4/3.2 server; the SSPL removed it from buster onward, and an application whose lock names
    # a Mongo client on a later era gets a loud refusal from `agents-services` rather than a boot
    # that fails for a reason nobody can see.
    if [ "$codename" = "jessie" ] || [ "$codename" = "stretch" ]; then \
      packages="$packages mongodb-server mongodb-clients"; \
    fi; \
    apt-get install -y --no-install-recommends $packages || \
      apt-get install -y --no-install-recommends $(echo "$packages" | sed 's/libidn-dev/libidn11-dev/'); \
    if [ "$codename" = "trixie" ]; then \
      apt-get install -y --no-install-recommends postgresql-17-pgvector; \
    fi; \
    # **ImageMagick's config scripts are off PATH on Debian, and rmagick 2.x finds the
    # library by running one of them.** The Debian 8 base installs IM 6.8's scripts under
    # `/usr/lib/<arch>/ImageMagick-<version>/bin-Q16/`, which is not on PATH, so
    # `rmagick 2.13.2`'s extconf answers "Can't find Magick-config" even with
    # `libmagickwand-dev` installed — measured on the 4.0 checkpoint of the first real
    # application, where the era was rejected for a missing header rather than for the move.
    # Link all four spellings, whichever the base provides; a base that already has them on
    # PATH is unchanged because the link points at the same script.
    for name in Magick-config MagickCore-config MagickWand-config Wand-config; do \
      config="$(find /usr/lib -maxdepth 4 -name "$name" -type f 2>/dev/null | head -1)"; \
      if [ -n "$config" ]; then ln -sf "$config" "/usr/local/bin/$name"; fi; \
    done; \
    # **The pinned browser, unpacked beside the distribution's rather than over it.** These are two
    # directories the step links `/usr/bin` at, which is why nothing here claims those names: apt
    # owns them on a live release, and a `dpkg` install over a symlink this image wrote is a build
    # that fails on the next run. The step decides which pair a project is measured on.
    if [ "$archived" = "0" ]; then \
      mkdir -p /opt/agents-browser; \
      url="https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VERSION}/linux64"; \
      curl -fsSL -o /tmp/chrome.zip "$url/chrome-linux64.zip"; \
      curl -fsSL -o /tmp/chromedriver.zip "$url/chromedriver-linux64.zip"; \
      unzip -q /tmp/chrome.zip -d /opt/agents-browser; \
      unzip -q /tmp/chromedriver.zip -d /opt/agents-browser; \
      mv /opt/agents-browser/chromedriver-linux64/chromedriver /opt/agents-browser/chromedriver; \
      rm -rf /opt/agents-browser/chromedriver-linux64; \
      rm -f /tmp/chrome.zip /tmp/chromedriver.zip; \
      # **The browser's directory keeps the archive's own name, and that is a correction rather than
      # tidiness.** It was unpacked to `/opt/agents-browser/chrome`, and chromedriver's Linux
      # finder globs `/opt/*/chrome` for the binary — so it found the *directory*, `execvp`'d it, and
      # answered `session not created: Chrome failed to start: exited normally` while
      # `/usr/bin/chromium` pointed at a launcher that ran the browser fine by hand. One level
      # deeper (`/opt/agents-browser/chrome-linux64/chrome`) is not a match for that glob, which
      # is what keeps the driver's own search from outranking the path this image wrote.
      # The launcher, because Chrome for Testing is a binary and not a launcher: the sandbox flags
      # the distro's `chromium` would read from `/etc/chromium.d` have to be passed here.
      printf '#!/bin/sh\nexec /opt/agents-browser/chrome-linux64/chrome --no-sandbox --disable-dev-shm-usage "$@"\n' \
        > /usr/local/bin/agents-browser; \
      chmod +x /usr/local/bin/agents-browser /opt/agents-browser/chromedriver; \
      printf '%s\n' "$CHROME_VERSION" > /opt/agents-browser/VERSION; \
    fi; \
    # **The headless browser an old poltergeist suite runs itself.** The URL is the archived
    # project's own download host, and the digest is the pin because that host is no longer the
    # one a current project would use. A failed download is a build failure rather than an image
    # that silently falls back to Firefox (which is not installed).
    curl -fsSL -o /tmp/phantomjs.tar.bz2 \
      "https://bitbucket.org/ariya/phantomjs/downloads/phantomjs-${PHANTOMJS_VERSION}-linux-x86_64.tar.bz2"; \
    echo "${PHANTOMJS_SHA256}  /tmp/phantomjs.tar.bz2" | sha256sum -c -; \
    mkdir -p /opt/agents-phantomjs; \
    tar -xjf /tmp/phantomjs.tar.bz2 -C /opt/agents-phantomjs --strip-components=1; \
    ln -sf /opt/agents-phantomjs/bin/phantomjs /usr/local/bin/phantomjs; \
    rm -f /tmp/phantomjs.tar.bz2; \
    rm -rf /var/lib/apt/lists/*; \
    npm install -g yarn@1.22.22

# **The source-built eras get the same gem home the official images have**, so the walker's
# `bundle` is the one this image installed and `start.sh`'s chown hands the same directory
# over. Without it, a 1.9.3 build installs Bundler into `/usr/local/lib/ruby/gems/1.9.1`,
# the walker's `GEM_HOME` names an empty directory, and the first `bundle install` resolves
# against a different set of gems than the image was built with.
ENV GEM_HOME=/usr/local/bundle
ENV PATH=/usr/local/bundle/bin:${PATH}

# **A login shell is how a stated suite command is run, and `/etc/profile` resets `PATH`.**
# `bundle exec rspec` is a string, so the machine hands it to `sh -lc`; on the official images
# the profile keeps the gem bin directory, but a source-built era had only the `ENV` above, and
# the first suite on 1.9.3 died with `sh: 1: bundle: not found` — after the pin, the edits and
# the bundle had all succeeded. The profile fragment is what makes the shell see the same
# `PATH` the direct `docker exec` commands do, for every era rather than just the two that
# happened to carry a profile of their own.
RUN printf 'export PATH="/usr/local/bundle/bin:$PATH"\n' > /etc/profile.d/agents-path.sh

# Build the interpreter only for the eras Docker Hub no longer serves. The configure line is
# the one the official images use: no docs, shared libruby so native extensions can link it.
RUN set -eux; \
    if [ -n "$RUBY_SOURCE_URL" ]; then \
      curl -kfsSL -o /tmp/ruby.tar.gz "$RUBY_SOURCE_URL"; \
      echo "$RUBY_SOURCE_SHA256  /tmp/ruby.tar.gz" | sha256sum -c -; \
      mkdir -p /usr/src/ruby; \
      tar -xzf /tmp/ruby.tar.gz -C /usr/src/ruby --strip-components=1; \
      cd /usr/src/ruby; \
      ./configure --disable-install-doc --enable-shared; \
      # **A 2013 interpreter does not need every core, and the Docker VM has less memory than
      # the host.** `-j$(nproc)` on a 20-core host built the 1.9.3 extensions until the linker
      # failed in `dl/callback.so`; the same build at four jobs succeeds. The bound is a fact
      # about the build's memory, not about the interpreter's support.
      make -j4; \
      make install; \
      rm -rf /usr/src/ruby /tmp/ruby.tar.gz; \
      ruby -v; \
    fi

# **1.9.3's RubyGems predates `--no-document`**, so the modern spelling is tried first and
# the 2014 one is the fallback. Both are the same request: install Bundler without the
# documentation that would otherwise be built for a gem the image never reads.
RUN gem install bundler -v "$BUNDLER" --no-document || \
    gem install bundler -v "$BUNDLER" --no-ri --no-rdoc

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
COPY services.sh /usr/local/bin/agents-services
COPY start.sh /usr/local/bin/agents-start
# **`install` cannot chmod a large file on Docker Desktop's bind mounts, and a gem's build is where
# that lands.** Measured on the lighthouse's 6.0 rung: `make install` building `sassc` (which
# `sass-rails 6` brings in) died on `setting permissions for '.gem.…/sassc/libsass.so': Operation not
# permitted` — for a file of about three megabytes, in a directory where a three-byte file installed
# cleanly and `cp` plus `chmod` on the same large file succeeded. The command is mkmf's, taken from
# `RbConfig`, so the walker cannot configure it away — and the whole rung is reported `unverified`
# when a gem's build fails. `install.rb` is the real binary whenever the real binary works, and the
# same operation done with `cp` and `chmod` when it does not.
COPY install.rb /usr/local/bin/agents-install
RUN mv /usr/bin/install /usr/bin/install.coreutils \
    && cp /usr/local/bin/agents-install /usr/bin/install \
    && chmod +x /usr/bin/install /usr/bin/install.coreutils
# The `database.yml` reader is a file of its own rather than a heredoc inside `services.sh`,
# and the reason is testability: which roles a database needs, and with what password, is a
# rule — and a rule inside a shell heredoc is a rule no test can run. It is executed by the
# *container's* Ruby, which is the era's, so it is written for Ruby 2.1 (`test/dbconfig_test.rb`
# drives it on the host and the era images are the proof that 2.1 parses it).
COPY dbconfig.rb /usr/local/bin/agents-dbconfig
RUN chmod +x /usr/local/bin/agents-services /usr/local/bin/agents-start \
    /usr/local/bin/agents-dbconfig

# The two directories the container's own environment points at, created here for the *named
# volume* case — Docker seeds an empty volume from the image, so these arrive with it. A
# bind mount shadows them, and the walker creates them on its side for exactly that reason
# (`Machine::Container#start!`, and the first real application's "`/agents/home` is not a
# directory" is where that came from).
RUN mkdir -p /agents/home /agents/tmp
