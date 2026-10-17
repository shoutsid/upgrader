#!/bin/sh
# What every era container runs first: give the walker's own account a *name*, then keep
# the container alive.
#
# **The passwd entry is the whole reason this script exists.** The walker runs its commands
# inside the container as its own uid (`docker exec --user`), which is the uid that owns the
# mounted home — so files a step creates belong to the account that has to commit them. But
# `initdb` refuses to start without a passwd entry for its effective user ("could not look up
# effective user ID 1000: user does not exist"), libpq's default username resolves through the
# same lookup, and Debian's `psql` wrapper cannot even find the cluster without a group name.
# None of those failures says "the uid has no name"; they say the database is broken. So the
# entry is created here, once, by the only process in the container that runs as root — every
# application-level command is exec'd with `--user` and never sees it.
#
# `--no-create-home` on purpose: the home is the volume mounted at `/agents-fyi/home`, owned
# by this uid on the host, and a `useradd` that created it would replace a mounted directory
# with an empty one.
set -eu

if [ -n "${AGENTS_FYI_UID:-}" ]; then
    if ! getent passwd "$AGENTS_FYI_UID" >/dev/null 2>&1; then
        gid="${AGENTS_FYI_GID:-$AGENTS_FYI_UID}"
        groupadd --gid "$gid" walker 2>/dev/null || true
        useradd --uid "$AGENTS_FYI_UID" --gid "$gid" --shell /bin/sh \
            --home-dir "${HOME:-/agents-fyi/home}" --no-create-home walker 2>/dev/null || true
    fi

    # **The PostgreSQL socket directory, prepared here and not in the image.** `/run` is a
    # tmpfs the container runtime mounts over the image's, so anything the build created
    # there is gone at the first start — found by an image that symlinked
    # `/var/run/postgresql` into scratch and a container where the symlink did not exist,
    # leaving `psql` to report a server it could not reach over a socket nobody was
    # listening on. The directory the Debian package installs is owned by `postgres`; the
    # server here runs as the walker's uid, so it is handed over.
    mkdir -p /var/run/postgresql
    chown "$AGENTS_FYI_UID:${AGENTS_FYI_GID:-$AGENTS_FYI_UID}" /var/run/postgresql 2>/dev/null || true
    chmod 2775 /var/run/postgresql 2>/dev/null || true
fi

exec "$@"
