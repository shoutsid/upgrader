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

# The adapter, hosts, databases and credentials a `database.yml` declares, read by
# `/usr/local/bin/agents-fyi-dbconfig` — a *file* rather than a heredoc here, because which
# roles a database needs and with what password is a rule, and a rule inside a shell heredoc
# is a rule no test can run (`test/dbconfig_test.rb` drives that file directly, one fixture
# per shape an application actually has). The fallback below is for a context where the
# reader is not installed: a plain-text scan that answers the two questions this script
# cannot do without — which adapter, and which usernames.
DBCONFIG="/usr/local/bin/agents-fyi-dbconfig"
read_config() {
    if [ -x "$DBCONFIG" ]; then
        ruby "$DBCONFIG" "$DATABASE_CONFIG" 2>/dev/null || true
        return
    fi
    # A best-effort scan for a context without the reader: the adapter and the usernames,
    # with the quotes and spaces stripped. It deliberately does not try to be the reader —
    # that is a file with tests — and it never prints a line the caller could read as "no
    # database" for a file it could not follow.
    adapter="$(sed -n 's/^[[:space:]]*adapter:[[:space:]]*//p' "$DATABASE_CONFIG" 2>/dev/null | head -n1 | tr -d ' \"')"
    [ -n "$adapter" ] && printf 'adapter:%s\n' "$adapter"
    sed -n 's/^[[:space:]]*username:[[:space:]]*//p' "$DATABASE_CONFIG" 2>/dev/null | tr -d ' \"' | sed 's/^/user:/'
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
        # **`listen_addresses=localhost`, not `127.0.0.1`**, and the difference is a
        # `database.yml` that says `host: localhost`: libpq resolves that to either loopback
        # family, and a server listening only on IPv4 is one a connection to `::1` cannot
        # reach. Postgres reads `localhost` as both.
        if ! "$pg_bin/pg_ctl" -D "$DATA_DIR" -l "$DATA_DIR/server.log" \
            -o "-c listen_addresses=localhost -p $PORT -k $SOCKET_DIR" -w start >/dev/null; then
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

    # **The passwords the application's own file names, set on those roles.** The server
    # authenticates over `trust`, so a password is not what lets a suite in — but a role that
    # exists *without* the password its configuration names is a fact a deployment discovers
    # only by switching the server to password authentication and watching a suite fail. One
    # statement per credential removes that trap, and a password the line protocol cannot
    # carry (one with a newline) was never emitted by the reader.
    printf '%s\n' "$credentials" | while IFS= read -r credential; do
        [ -n "$credential" ] || continue
        user="${credential%%:*}"
        password="${credential#*:}"
        [ -n "$user" ] || continue
        # `psql` quotes both values itself: `:"role"` is an identifier and `:'pw'` is a string
        # literal, so a password with a quote or a backslash in it needs no escaping here —
        # the shell never builds the SQL.
        "$pg_bin/psql" -h 127.0.0.1 -p "$PORT" -U app -q -t \
            -v "role=$user" -v "pw=$password" \
            -c "ALTER ROLE :\"role\" WITH LOGIN PASSWORD :'pw'" >/dev/null 2>&1 || true
    done

    echo "agents-fyi-services: PostgreSQL $("$pg_bin/postgres" --version | awk '{print $3}') on 127.0.0.1:$PORT and $SOCKET_DIR"
    # What the file said, in the record: a suite that cannot reach its database is a failure
    # whose cause is usually in this line.
    echo "agents-fyi-services: database.yml: adapter ${adapter:-unread}, host ${host:-default}, database ${database:-unset}, user(s) ${users:-none (libpq default)}"
    case "$host" in
        ""|localhost|127.0.0.1|::1) ;;
        *) echo "agents-fyi-services: note: database.yml names host $host, which is not this container — the suite will connect there, not to the server started here" ;;
    esac
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
host=""
database=""
users=""
credentials=""
if [ -f "$DATABASE_CONFIG" ]; then
    info="$(read_config)"
    adapter="$(printf '%s\n' "$info" | sed -n 's/^adapter://p' | head -n1)"
    host="$(printf '%s\n' "$info" | sed -n 's/^host://p' | head -n1)"
    database="$(printf '%s\n' "$info" | sed -n 's/^database://p' | head -n1)"
    users="$(printf '%s\n' "$info" | sed -n 's/^user://p')"
    credentials="$(printf '%s\n' "$info" | sed -n 's/^credential://p')"
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
