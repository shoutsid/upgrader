#!/bin/sh
# The services a Rails application's suite expects, started inside the step's own container.
#
# Called by the walker as `agents-fyi-services` with the application's directory as the
# working directory, once per step, before the baseline runs. Everything it starts lives in
# the container and dies with it, which is the property that matters: an environment that
# survives a step is an environment the next step can silently inherit evidence from.
#
# **PostgreSQL runs here rather than in a sibling container**, and the reason is the
# application's own configuration: a `database.yml` from 2013 says `host: localhost`, and a
# service on a Docker network is not localhost. Putting the server in the step's container
# means the application's configuration keeps working unedited — no connection string has to
# be rewritten for the machine's convenience, and no such rewrite has to travel in a pull
# request as if it were an upgrade. The user the server runs as is the account the container
# runs as (`--user` from the walker), `initdb` refuses root, and authentication is `trust`
# over loopback and the socket: a throwaway server, for one step, on a private namespace.
#
# **The socket directory is `/tmp/agents-fyi-socket`, and `/var/run/postgresql` is a symlink
# to it from the image.** A `database.yml` with no `host:` connects over the Unix socket at
# the directory libpq was compiled with, and the container's account cannot create anything
# under `/var/run`. The image carries the link; see its comment for the failure that found
# this.
#
# Every line of output is evidence for the step's record: which services started, what
# version, and where. A service the application needs that could not start is a *failure*
# rather than a warning — the suite that follows would fail for a reason nobody could see.
set -u

# **The socket directory is the one libpq was compiled with — `/var/run/postgresql` — and
# it is prepared by `start.sh`, not by this image.** `/run` is a per-container tmpfs, so a
# directory or symlink the build made there is gone by the time the server starts; the start
# script (the container's only root process) creates it and hands it to the walker's uid.
# The fallback `mkdir` here is for a native or unusual context where nothing else did it.
DATABASE_CONFIG="config/database.yml"
DATA_DIR="/tmp/agents-fyi-postgres"
SOCKET_DIR="${AGENTS_FYI_PG_SOCKET:-/var/run/postgresql}"
PORT=5432

# The adapter and the usernames a `database.yml` declares, read by Ruby so that anchors,
# aliases and `<%= ENV[...] %>` are handled the way Rails handles them. The ERB pass can
# raise on a variable the walker did not set, so there is a plain-text fallback: this script
# decides whether to start PostgreSQL, and a YAML the reader cannot parse should not be read
# as "no database here".
read_config() {
    ruby - "$DATABASE_CONFIG" <<'RUBY' 2>/dev/null || true
require "yaml"
path = ARGV[0]
adapter = nil
users = []
begin
  require "erb"
  config = YAML.unsafe_load(ERB.new(File.read(path)).result)
  if config.is_a?(Hash)
    config.each_value do |env|
      next unless env.is_a?(Hash)
      adapter ||= env["adapter"].to_s
      users << env["username"].to_s unless env["username"].to_s.empty?
    end
  end
rescue StandardError
  text = begin
    File.read(path)
  rescue StandardError
    ""
  end
  adapter = text[/adapter:\s*["']?([A-Za-z0-9_]+)/, 1]
  users = text.scan(/username:\s*["']?([A-Za-z0-9_.-]+)/).flatten
end
puts "adapter:#{adapter}" unless adapter.to_s.empty?
users.uniq.each { |user| puts "user:#{user}" }
RUBY
}

start_postgres() {
    pg_bin="$(pg_config --bindir 2>/dev/null || true)"
    if [ -z "$pg_bin" ] || [ ! -x "$pg_bin/initdb" ]; then
        pg_bin="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | head -n1 || true)"
    fi
    if [ -z "$pg_bin" ] || [ ! -x "$pg_bin/initdb" ]; then
        echo "agents-fyi-services: database.yml wants PostgreSQL and this image has no server to start" >&2
        return 1
    fi

    mkdir -p "$SOCKET_DIR"
    if [ ! -s "$DATA_DIR/PG_VERSION" ]; then
        rm -rf "$DATA_DIR"
        if ! "$pg_bin/initdb" -D "$DATA_DIR" -U app --auth=trust --encoding=UTF8 --locale=C >/dev/null; then
            echo "agents-fyi-services: initdb failed; the suite would run against no database" >&2
            return 1
        fi
    fi
    if ! "$pg_bin/pg_ctl" -D "$DATA_DIR" status >/dev/null 2>&1; then
        if ! "$pg_bin/pg_ctl" -D "$DATA_DIR" -l "$DATA_DIR/server.log" \
            -o "-c listen_addresses=127.0.0.1 -p $PORT -k $SOCKET_DIR" -w start >/dev/null; then
            echo "agents-fyi-services: pg_ctl could not start the server; see $DATA_DIR/server.log" >&2
            return 1
        fi
    fi
    # The check the echo below depends on: a server that says it started and does not answer
    # is the shape of every failure this script exists to make loud, and the sentence it
    # printed before this check existed was simply false.
    if ! "$pg_bin/pg_isready" -h 127.0.0.1 -p "$PORT" >/dev/null 2>&1; then
        echo "agents-fyi-services: PostgreSQL accepted no connection on 127.0.0.1:$PORT after starting" >&2
        return 1
    fi

    # A role per username the application asks for, plus the two names that stand in for
    # "whatever the operating system user was called": the walker's account has no passwd
    # entry in the container, and a connection with no username resolves through libpq's
    # own default, so both are created rather than discovered.
    # shellcheck disable=SC2086
    for role in app postgres root $users; do
        "$pg_bin/createuser" -h 127.0.0.1 -p "$PORT" -U app --superuser "$role" >/dev/null 2>&1 || true
    done

    echo "agents-fyi-services: PostgreSQL $("$pg_bin/postgres" --version | awk '{print $3}') on 127.0.0.1:$PORT and $SOCKET_DIR"
}

start_redis() {
    if ! command -v redis-server >/dev/null 2>&1; then
        return 0
    fi
    if ! redis-cli -p 6379 ping >/dev/null 2>&1; then
        redis-server --daemonize yes --save '' --appendonly no \
            --bind 127.0.0.1 --port 6379 --dir /tmp >/dev/null 2>&1 || true
    fi
    version="$(redis-server --version 2>/dev/null | sed -n 's/.*v=\([0-9.]*\).*/\1/p')"
    echo "agents-fyi-services: Redis ${version:-unknown} on 127.0.0.1:6379"
}

adapter=""
users=""
if [ -f "$DATABASE_CONFIG" ]; then
    info="$(read_config)"
    adapter="$(printf '%s\n' "$info" | sed -n 's/^adapter://p' | head -n1)"
    users="$(printf '%s\n' "$info" | sed -n 's/^user://p')"
fi

# Redis first and unconditionally: it is cheap, most suites that use it use it only when
# they touch a queue, and a PostgreSQL failure must not leave the rest of the application's
# services unstarted — the record's job is to say which one failed, not to stop at the
# first.
start_redis

case "$adapter" in
    postgresql | postgis)
        start_postgres || exit 1
        ;;
    "")
        echo "agents-fyi-services: no database.yml adapter was read, so PostgreSQL was not started"
        ;;
    *)
        echo "agents-fyi-services: database.yml names the $adapter adapter; this script starts PostgreSQL only"
        ;;
esac

exit 0
