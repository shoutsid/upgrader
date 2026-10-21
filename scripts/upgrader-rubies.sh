#!/usr/bin/env bash
# Install the era interpreters the upgrader executes steps on, natively, through rvm.
#
# The analogue of `upgrader-images.sh`, and which of the two a deployment wants is a fact about
# the host rather than a taste. A container carries the era's *C libraries* as well as its Ruby —
# ImageMagick 6 for rmagick 2.x, libpq, the era's PostgreSQL — so it is the answer for an old
# application on a modern host. A host that has been set up for the era (the right interpreter
# and the right libraries) runs a step with no container start at all, which is the slowest thing
# a walk does: twenty seconds healthy, ninety when the daemon degrades, paid once per interpreter
# candidate. `UPGRADER_RUNTIME=rvm` is that mode, and this script is the setup step it needs.
#
#   scripts/upgrader-rubies.sh list              # the matrix, and which eras are installed here
#   scripts/upgrader-rubies.sh install           # every era
#   scripts/upgrader-rubies.sh install 2.1 2.2   # the ones named
#   scripts/upgrader-rubies.sh check             # exit non-zero if an era the matrix names is absent
#
# Per era it does four things: `rvm install <ruby>`, a gemset of its own
# (`UPGRADER_RVM_GEMSET`, default `agents-fyi-upgrader` — a walk must not install its gems into
# the gemset a developer uses for their own work), the era's **bundler** (a fact of the era, not
# of the host: a Rails 4-era application's lockfile requires bundler < 2, and the era images pin
# 1.17.3 for exactly that reason), and rvm's **wrappers**, which are the seam the walker uses —
# `~/.rvm/wrappers/<ruby>@<gemset>/bundle` is a real executable that sets GEM_HOME, GEM_PATH and
# the interpreter before exec'ing.
#
# **It installs no system packages, and says which are missing.** rvm's own `autolibs` setting is
# respected rather than overridden: a script that ran `sudo apt-get` on somebody's machine because
# they asked for a Ruby is a script that changes that machine in ways nobody read. The two this
# repository's eras need are `libyaml-dev` (psych, which Ruby's own build wants) and `libpq-dev`
# (the `pg` gem). Old rubies additionally need an OpenSSL older than 3 — rvm builds its own when
# asked (`rvm pkg install openssl`), and a failure here says so rather than being worked around.
#
# Needs: rvm, ruby, a compiler. Nothing is left running.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MATRIX="$ROOT/lib/agents_fyi/upgrader/data/interpreters.json"

# Where rvm lives and which gemset the walker's eras go in. Both are the walker's own variables
# (`Machine::Host`), read here so that a deployment that moved either does not get a script that
# installed the eras somewhere the walker will not look.
RVM_ROOT="${UPGRADER_RVM_ROOT:-$HOME/.rvm}"
GEMSET="${UPGRADER_RVM_GEMSET:-agents-fyi-upgrader}"

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# The matrix as tab-separated rows: the era's name, its interpreter version, the rvm name the
# walker will look for, and the bundler that era's applications expect.
rows() {
  ruby -rjson -e '
    JSON.parse(File.read(ARGV[0])).fetch("interpreters").each do |entry|
      rvm = entry["rvm"].to_s.empty? ? "ruby-#{entry["ruby"]}" : entry["rvm"]
      puts [entry["name"], entry["ruby"], rvm, entry["bundler"]].join("\t")
    end
  ' "$MATRIX"
}

# The rows the caller named, or all of them. The projection is written once here rather than at
# each reader, because `read` gives the remainder of a line to its last variable: a four-column
# row read into three names arrives with a bundler version glued to the rvm name.
selected() {
  local requested=("$@")
  rows | while IFS=$'\t' read -r name ruby rvm bundler; do
    if [ "${#requested[@]}" -eq 0 ]; then
      printf '%s\t%s\t%s\t%s\n' "$name" "$ruby" "$rvm" "$bundler"
      continue
    fi
    for want in "${requested[@]}"; do
      if [ "$want" = "$name" ]; then
        printf '%s\t%s\t%s\t%s\n' "$name" "$ruby" "$rvm" "$bundler"
        break
      fi
    done
  done
}

wrapper_for() { printf '%s/wrappers/%s@%s' "$RVM_ROOT" "$1" "$GEMSET"; }

installed() { [ -x "$(wrapper_for "$1")/ruby" ]; }

# What the matrix names and what this host has, in the same order, so a missing era is visible
# rather than inferred from a walk's refusal later.
list() {
  rows | while IFS=$'\t' read -r name ruby rvm bundler; do
    wrapper="$(wrapper_for "$rvm")"
    if [ -x "$wrapper/ruby" ]; then
      printf '%-4s ruby %-8s %s (bundler %s)\n' "$name" "$ruby" "$wrapper" "$bundler"
    else
      printf '%-4s ruby %-8s (not installed here)\n' "$name" "$ruby"
    fi
  done
  echo
  echo "gemset: $GEMSET   rvm root: $RVM_ROOT"
  echo "install an era with: $0 install <name>   (or all of them: $0 install)"
}

# The system packages Ruby's own build and this repository's bundles want. Reported rather than
# installed: see the header.
missing_packages() {
  local missing=()
  for package in libyaml-dev libpq-dev; do
    if command -v dpkg >/dev/null 2>&1 && ! dpkg -s "$package" >/dev/null 2>&1; then
      missing+=("$package")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "note: these system packages are missing and rvm will not install them: ${missing[*]}"
    echo "      (psych needs libyaml-dev; the pg gem needs libpq-dev)"
  fi
}

install() {
  missing_packages
  local count=0
  # Process substitution rather than a pipeline: a loop on the right-hand side of a pipe runs in
  # a subshell, where `exit 1` would leave the script reporting success for an era it failed on.
  while IFS=$'\t' read -r name ruby rvm bundler; do
    echo "installing era $name — ruby $ruby (rvm $rvm), bundler $bundler"
    if ! rvm install "$ruby"; then
      echo "failed: rvm install $ruby — an era older than 3.0 needs an OpenSSL below 3, which" >&2
      echo "        rvm builds on request: \`rvm pkg install openssl\`, then retry" >&2
      exit 1
    fi
    rvm "$ruby" do rvm gemset create "$GEMSET" || true
    rvm "$rvm@$GEMSET" do gem install bundler --version "$bundler" --no-document
    # **The wrappers are the seam, and rvm makes them with the gemset** — `rvm wrapper` is a
    # different tool (it writes a script with a prefix) and calling it here printed its help
    # instead of failing, which is exactly the kind of silence worth not having. So the wrapper
    # is *verified* rather than created: the walker runs `bundle` and `ruby` out of this
    # directory and gets the gemset and the bundler version with them.
    if [ ! -x "$(wrapper_for "$rvm")/bundle" ]; then
      echo "failed: $rvm@$GEMSET was created but has no wrapper at $(wrapper_for "$rvm")" >&2
      echo "        rvm writes them with the gemset; \`rvm use $rvm@$GEMSET --create\` repairs it" >&2
      exit 1
    fi
    count=$((count + 1))
  done < <(selected "$@")
  echo
  echo "done: $count era(s) installed here. A walk on this host runs with:"
  echo "  UPGRADER_RUNTIME=rvm bin/agents-fyi-upgrader step --repo PATH --to VERSION"
}

# The same question a walk asks, asked before the walk: every era the matrix names must be
# installed here, or the step is refused by name at the candidate it needed.
check() {
  local missing=()
  while IFS=$'\t' read -r name _ruby rvm _bundler; do
    installed "$rvm" || missing+=("$name")
  done < <(selected "$@")
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "refused: ${#missing[@]} era(s) of this matrix are not installed here: ${missing[*]}" >&2
    echo "        $0 install ${missing[*]}" >&2
    exit 2
  fi
  echo "every era in the matrix is installed here"
}

case "${1:-}" in
  install)
    shift
    install "$@"
    ;;
  list)
    list
    ;;
  check)
    shift
    check "$@"
    ;;
  *)
    usage
    ;;
esac
