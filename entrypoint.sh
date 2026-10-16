#!/bin/sh
# Start the upgrader's service loop — and wait for the API before asking it anything.
#
# Only `serve` is here. `plan` and `step` are one command each, run by hand or by the
# loop, and the image's own entrypoint is still the CLI: this script is what the
# *compose service* opts into, so a container that is meant to be long-running gets a
# waiter in front of it and a container that is meant to run once does not.
#
# The wait is the miner's, for the miner's reason: a process that started against a
# socket nobody was listening on would spend its first cycle retrying and log an
# outage it did not have. It does not wait forever, because an API that is down for an
# hour is an API the loop should be running alongside rather than a reason for the
# container to refuse to start — the loop already treats an unreachable corpus as
# something to wait out, which is strictly more forgiving than this.
set -eu

: "${API_BASE_URL:=http://service:8001}"
: "${UPGRADER_HOME:=/home/upgrader/.cache/agents-fyi-upgrader}"
# The repository list, as `owner/name@ref` entries separated by spaces.
#
# Empty is a legitimate configuration and it is the default: a deployment that has not
# chosen its targets must not start upgrading somebody's application by accident. The
# loop says so and idles rather than exiting, so an operator who sets this and restarts
# the container does not have to know why it had stopped.
#
# The *service* owns the order a queue would carry and exposes no repository queue yet. So the
# operator names the work here for now, and **this line is what that queue replaces**: when
# the service hands out targets, the list stops being a deployment setting and an empty one
# stops being meaningful.
: "${UPGRADER_REPOS:=}"
# The Rails release each move ends at, and the reason it has no default.
#
# The ladder lives in the service and nowhere else, so a this-tool default would be a second
# copy of "what comes after 7.1" — the one rule the product is built on, and the one a second
# copy is guaranteed to disagree about eventually. Empty means the loop idles and says so,
# exactly as an empty repository list does.
#
# This variable existed nowhere until it was looked for, and that was a bug of the same
# shape as the removed log level: `serve` prints "set `UPGRADER_TO`" when it has no
# target, the container started, came up healthy and walked nothing for as long as nobody
# ran a step by hand and noticed. `deploy_config_test.rb` now asserts that this script
# supplies every flag `serve` needs, so the next required flag to be added fails the suite
# rather than the deployment.
: "${UPGRADER_TO:=}"
# How long a cycle waits between walks. Ten minutes is the miner's cadence and it is
# chosen against the work rather than against the API: a step is a bundle resolve, an
# `app:update` and a whole test suite, so a loop that walked faster would re-read
# ledgers that cannot have changed.
: "${UPGRADER_INTERVAL:=600}"
# How long one step may take before it is killed. Generous on purpose: a Rails step
# includes the application's own suite, and a step killed in the middle of it records
# nothing and costs the attempt. The loop checkpoints after each step, so a restart
# resumes rather than starting over.
: "${UPGRADER_STEP_TIMEOUT:=3600}"
# There is deliberately no log level, and this is a bug fixed rather than a preference.
#
# `--log-level "${UPGRADER_LOG_LEVEL}"` used to be passed from here to a CLI that accepts
# no such flag — `cli.rb`'s `OptionParser` raises `InvalidOption`, `parse` turns that into
# a usage error, and `serve` exited 2 having logged a refusal. The container therefore
# never started, while its compose service, its `start_period: 15m` and its healthcheck all
# described a loop that was working, and the suite was green throughout.
#
# Removed rather than implemented, because this image has no logging framework: its output
# is the CLI's own report and the loop's one line per cycle, and a flag that filters none
# of it is a flag that lies. The alternative rejected was keeping the flag and giving the
# CLI a level to honour — a second vocabulary for what the miner's `LOG_LEVEL` means, with
# none of the machinery behind it. `deploy_config_test.rb` now checks every flag this
# script passes against the CLI's own usage text, which is the check that would have
# caught it.

echo "upgrader: waiting for ${API_BASE_URL}/health"
attempt=0
# The interpreter already in the image is the client, so nothing is installed just to
# probe a URL — the same choice the image's healthcheck makes.
#
# The probe is the miner's entrypoint's, and it was broken here for want of anybody
# compiling it: `exit(0 if RESPONSE.is_a?(Net::HTTPSuccess) else 1)` is a Ruby *syntax
# error* — a postfix `if` cannot carry an `else` — so every attempt exited 1, the loop
# always spent its full five minutes, and it then announced that an API answering
# `/health` "did not come up in 5 minutes". The probe's own stderr went to `/dev/null`,
# which is where the syntax error went with it. `deploy_config_test.rb` now compiles this
# snippet, so a probe that cannot run is a red suite rather than five wasted minutes on
# every boot.
#
# Single quotes and an environment variable rather than a double-quoted argument: the
# snippet is Ruby, so shell interpolation inside it is a chance to produce a program
# nobody wrote. The two four-second ceilings are also the miner's, for its measured
# reason — `Net::HTTP.get_response` waits sixty seconds to connect *and* sixty to read,
# so an address that accepts a connection and then says nothing would turn this loop's
# five minutes into a quarter of an hour.
until UPGRADER_HEALTH_URL="${API_BASE_URL}/health" ruby -rnet/http -ruri -e '
begin
  uri = URI(ENV["UPGRADER_HEALTH_URL"])
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 4, read_timeout: 4) do |http|
    http.get(uri.request_uri)
  end
  exit(response.code == "200" ? 0 : 1)
rescue StandardError
  exit 1
end
' 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
        echo "upgrader: ${API_BASE_URL} did not come up in 5 minutes; starting anyway" >&2
        break
    fi
    sleep 5
done

if [ -z "${UPGRADER_TO}" ]; then
    echo "upgrader: UPGRADER_TO is empty, so this loop will not walk anything —" \
        "set it to the Rails release the move ends at, for example 7.1.0" >&2
elif [ -z "${UPGRADER_REPOS}" ]; then
    # With no target the loop walks nothing whatever the list says, so this is only worth
    # saying once the operator has got the target right: two warnings at once, one of
    # which is moot, is how the real one stops being read.
    echo "upgrader: UPGRADER_REPOS is empty, so this loop has nothing to walk —" \
        "the service's queue is used instead when the client has a key" >&2
fi

# The repository list is several arguments rather than one, so it goes through the
# positional parameters — and only when there *is* a list. Passed unconditionally, an
# empty `${UPGRADER_REPOS}` would leave `--repos` with nothing to take and the next flag
# (`--interval`) would be read as its value: a service that starts, reports healthy and
# has been told a repository called `--interval`. Building the arguments is where that
# is prevented, rather than in the list's own default.
# shellcheck disable=SC2086
if [ -n "${UPGRADER_REPOS}" ]; then
    set -- --repos ${UPGRADER_REPOS}
else
    set --
fi

exec /app/bin/agents-fyi-upgrader serve \
    --to "${UPGRADER_TO}" \
    --api "${API_BASE_URL}" \
    --home "${UPGRADER_HOME}" \
    --heartbeat "${UPGRADER_HOME}/heartbeat" \
    "$@" \
    --interval "${UPGRADER_INTERVAL}" \
    --step-timeout "${UPGRADER_STEP_TIMEOUT}"
