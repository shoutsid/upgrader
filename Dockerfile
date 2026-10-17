# The Rails upgrader, as a client.
#
# A *client* of the API with a client's key, for the same reason the miner is one:
# no database driver, no route to `db`, no `DB_PASSWORD`. The worst it can do to
# the corpus is what any operator could do, and it can be stopped while the API
# carries on. It is a *tool* before it is a service — phase 2 is `plan`, run by
# hand, and the product of a run is a patch and a record rather than a row.
#
# Pinned by digest, and to the same bytes as the Ruby stage in `miner/Dockerfile`.
# That is not tidiness: every refusal message this repository's Ruby rules were
# written against was captured on Ruby 3.3.12 / RubyGems 3.5.22, and the miner has
# been installing gems on that interpreter for weeks. A second Ruby, chosen by a
# tag that moves, is a second set of behaviours nobody verified — and the
# interpreter is a *fact about the step* here, carried as `requires_ruby` on every
# rung of the ladder (`data/rails_ladder.json`), not a preference.
# The base is an argument so that one Dockerfile can build the ladder's several
# images: `requires_ruby` on a step (`data/rails_ladder.json`) decides which interpreter
# may execute it, and that makes the interpreter a *fact about the step* rather than
# a preference this file is allowed to hold. The default keeps the digest, because a
# pin a build can silently drop is not a pin. The other services (`upgrader-27`,
# `upgrader-31`) arrive when that column is what picks the image; each will pass its
# own digest here, and none of those digests may be guessed — one that was never
# pulled is a build that fails, or worse, an image nobody verified.
ARG RUBY_IMAGE=ruby:3.3-slim@sha256:379ffc9ca20cae2655cb80cac53ee23e1e7d859c03a4cceb7f567d6ce4873cee
FROM ${RUBY_IMAGE}

# `git` and nothing else, and `git` is load-bearing: `plan --repo URL` shallow-clones
# once into `$UPGRADER_HOME` and reuses it, because a plan is asked for repeatedly
# while a move is worked out. `ca-certificates` comes with the base image, which is
# what makes that clone an HTTPS one.
#
# Deliberately absent from the default build:
#
# - **A compiler.** `plan` builds no native extension: this side installs no gems at
#   all, and the one thing it needs from the ecosystem — parsing a `Gemfile.lock` — is
#   `Bundler::LockfileParser`, a default gem. `step` is the other half, and it *does*
#   install a real application's bundle, so the compiler arrives with it — see
#   `WITH_BUILD_TOOLS` below, which is how "the step's own image" is spelled without a
#   second Dockerfile that would drift from this one.
# - **Bundler as a program we run.** `bin/agents-fyi-upgrader` puts `lib` on the load
#   path itself; a `bundle exec` in front of a tool with no dependencies is a
#   dependency on Bundler dressed up as hygiene.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

# The toolchain a *step* needs, behind an argument, because whether this image can
# compile is a fact about the job rather than about the client.
#
# Three packages, each earned rather than bundled in for luck: `build-essential` for
# the gems that ship no prebuilt binary (`bootsnap`, `debug`, and anything old enough
# to predate the prebuilt-binary practice), `libsqlite3-dev` for `sqlite3`, and
# `libyaml-dev` for `psych`, which are the two headers a Rails application's bundle
# most often needs and neither of which a prebuilt binary can supply when the gem is
# built from source instead. `pkg-config` because several `extconf.rb`s refuse to
# configure without it.
#
# The default is 0 and it must stay 0: `docker run <image> plan --repo …` is run on
# machines that will never execute a step, `upgrader/test/`'s own suite builds this
# image with no arguments, and ~250 MB of toolchain in the image that only reads a
# lockfile is the wrong default. The service that *does* execute steps passes 1
# (`docker-compose.yml`), and `test/deploy_config_test.rb` holds both halves of that
# sentence — because a service that cannot compile a native gem runs, reports healthy
# and completes no step, which is a failure with no error message anywhere.
ARG WITH_BUILD_TOOLS=0
RUN if [ "$WITH_BUILD_TOOLS" = "1" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends \
           build-essential libsqlite3-dev libyaml-dev pkg-config \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# The repair agent, behind an argument for the same reason the compiler is: whether this
# image may spend a model call is a fact about the *job*, and `plan`/`--help` on a machine
# that will never repair should not carry a Node runtime and a model client.
#
# `opencode` ships as an npm package. It is the same client the harness measures models
# through, so the repair loop and the probe speak one vocabulary.
#
# **The version is an argument and its default is `latest`, which is a decision rather than
# an oversight**: this image cannot know which agent build an operator has authenticated
# against, and a pinned name the deployment never tested is a pin that moves the failure to
# a machine nobody is looking at. A deployment that wants a pin passes it
# (`UPGRADER_REPAIR_AGENT_VERSION` in `.env.example`), and the deployment note in
# `docker-compose.yml` says what a repair needs beyond the binary: an authenticated model.
ARG WITH_REPAIR_AGENT=0
ARG REPAIR_AGENT_VERSION=latest
RUN if [ "$WITH_REPAIR_AGENT" = "1" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends nodejs npm ca-certificates \
      && npm install -g --no-fund --no-audit "opencode-ai@${REPAIR_AGENT_VERSION}" \
      && npm cache clean --force \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# The plan tool runs on one interpreter on purpose, and the matrix below it does not
# exist yet. Reading a lockfile and asking the service a question are the same on
# every Ruby this ladder's last two rungs support; *executing* a step is not, and
# that is phase 3's job: one service per image (`upgrader-27`, `upgrader-31`,
# `upgrader-33`), each claiming only the steps whose `requires_ruby` it satisfies.
# Building that matrix now would be three images and three compose services for a
# mode that does not run an application yet.
WORKDIR /app
COPY bin ./bin
COPY lib ./lib
COPY entrypoint.sh ./entrypoint.sh
COPY README.md ./

# Every directory a mounted volume will sit over is created here, and the reason is
# the trap this image already documents: a named volume mounted at a path the image
# did not create is created owned by *root*, and this account could not write to it.
# A gem cache that cannot be written is a gem cache that is silently unused, and the
# ledger that cannot be written is a service that settles nothing and re-derives
# every step on every restart.
#
# `tmp` is here as well as `/tmp` in the compose service, and it is the half that
# matters: `gem` and `bundle` unpack into `TMPDIR`, and a bundle of a real Rails
# application is hundreds of gems. The miner paid 4.1 GB of tmpfs — RAM — for
# exactly this, so scratch is sent to the volume and the tmpfs is left as a small
# bound for whatever ignores `TMPDIR`.
RUN useradd --system --uid 10003 --create-home upgrader \
    && mkdir -p /home/upgrader/.cache/agents-fyi-upgrader \
        /home/upgrader/.cache/agents-fyi-upgrader/tmp \
        /home/upgrader/.cache/agents-fyi-upgrader/bundle \
        /home/upgrader/.gem \
    && chmod +x /app/bin/agents-fyi-upgrader /app/entrypoint.sh \
    && chown -R upgrader:upgrader /app /home/upgrader
USER upgrader

# `GEM_HOME` is the gem cache, and its path is declared *here* rather than typed into
# the compose file for the reason `PIP_CACHE_DIR` is declared in `miner/Dockerfile`:
# it is the interpreter's own idea of where gems live, so the image is where it is
# read from, and the compose mount is checked against this line rather than against a
# second copy of it (`test/deploy_config_test.rb`). It is a *cache* — a `.gem` is an
# artifact the index published a hash for — and the bundle built from it is not: see
# the note on the mount.
#
# `BUNDLE_USER_HOME` and `TMPDIR` are on the volume because both are written during a
# `bundle install` and neither is. This is an image *ENV*, which applies to the
# runtime as well as the build — which is the whole reason `PIP_NO_CACHE_DIR=1` in the
# miner was wrong in both.
ENV UPGRADER_HOME=/home/upgrader/.cache/agents-fyi-upgrader \
    GEM_HOME=/home/upgrader/.gem \
    BUNDLE_USER_HOME=/home/upgrader/.cache/agents-fyi-upgrader/bundle \
    TMPDIR=/home/upgrader/.cache/agents-fyi-upgrader/tmp

# The entrypoint stays the one-shot CLI, and the *service* is this same image with
# `entrypoint: /app/entrypoint.sh` (see `docker-compose.yml`). That ordering is
# deliberate: `docker run <image> plan --repo …` and `--help` keep working exactly as
# they did, so the loop's waiter is something a service opts into rather than
# something every invocation walks through. The miner's image runs three jobs the same
# way — one image, and the command decides which job it is.
#
# No HEALTHCHECK in the image: the loop's liveness is the age of a heartbeat file the
# *service* owns, and a check that ships in the image would be a check on the wrong
# thing for a one-shot `plan`.
ENTRYPOINT ["/app/bin/agents-fyi-upgrader"]
