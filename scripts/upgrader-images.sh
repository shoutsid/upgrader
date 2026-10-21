#!/usr/bin/env bash
# Build the era interpreter images the upgrader executes steps on.
#
# One image per entry of the interpreter matrix
# (`lib/agents_fyi/upgrader/data/interpreters.json`), built from the one Dockerfile in
# `images/`. The matrix is the source of truth: this script reads it, passes each entry's
# facts as build arguments, and tags the result with the reference the walker runs. Nothing
# here decides which eras exist — adding an era is a row in the matrix, and the next `build`
# makes it.
#
#   scripts/upgrader-images.sh build             # every era
#   scripts/upgrader-images.sh build 2.2 2.5     # the ones named
#   scripts/upgrader-images.sh list              # the matrix, and which images exist here
#   scripts/upgrader-images.sh prune             # reclaim what builds leave behind
#
# **A rebuild costs disk in two places, and this script cleans up the first itself.** The
# image a `-t` rebuild supersedes becomes untagged, so `build` removes it by id the moment the
# new one is in place (only that one: `docker image prune` would take every other project's
# dangling images with it). The second is the build cache — one `docker build` of six eras
# stores every layer it compiled, and rebuilding the same six five times in a session left
# **8.5 GB** of it here — which is why `prune` exists and why `build` says so when it is done.
#
# A machine that walks old applications needs these images on the same Docker daemon the
# walker talks to; a deployment that only ever walks modern ones does not build any of them,
# and a step at a floor no image meets is refused by name rather than attempted.
#
# Needs: docker, ruby. Nothing is left running — a build is `docker build` and exits.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MATRIX="$ROOT/lib/agents_fyi/upgrader/data/interpreters.json"
DOCKERFILE="$ROOT/images/Dockerfile"
CONTEXT="$ROOT/images"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# The matrix as tab-separated rows, exactly as the build arguments need them. Which
# distribution the base is, and how to reach its packages, is *not* here: the image says so
# itself (`/etc/os-release`), because a column here was wrong about three of the six eras
# within a day.
rows() {
  ruby -rjson -e '
    JSON.parse(File.read(ARGV[0])).fetch("interpreters").each do |entry|
      puts [entry["name"], entry["base"], entry["bundler"], entry["image"], entry["ruby"]].join("\t")
    end
  ' "$MATRIX"
}

selected() {
  local requested=("$@")
  local found=0
  # Four columns out of the five `rows` carries, and this is the *only* place the projection
  # happens: `read` gives the remainder of the line to its last variable, so a five-column
  # row handed to the build's own four-column read arrived as an image reference ending in
  # "\t2.1.10" — "invalid tag … invalid reference format", which is how this was found.
  # The no-names path takes the same projection, because it used to hand `rows` straight
  # through and the bug only showed on a full build.
  while IFS=$'\t' read -r name base bundler image _ruby_version; do
    if [ "${#requested[@]}" -eq 0 ]; then
      printf '%s\t%s\t%s\t%s\n' "$name" "$base" "$bundler" "$image"
      continue
    fi
    for want in "${requested[@]}"; do
      if [ "$want" = "$name" ]; then
        printf '%s\t%s\t%s\t%s\n' "$name" "$base" "$bundler" "$image"
        found=$((found + 1))
      fi
    done
  done < <(rows)
  if [ "${#requested[@]}" -gt 0 ] && [ "$found" -ne "${#requested[@]}" ]; then
    echo "the matrix has no $found of these eras: ${requested[*]}" >&2
    exit 2
  fi
}

build() {
  selected "$@" | while IFS=$'\t' read -r name base bundler image; do
    echo "building $image — Ruby $name (base $base)"
    previous="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)"
    docker build \
      --build-arg "BASE_IMAGE=$base" \
      --build-arg "BUNDLER=$bundler" \
      -t "$image" \
      -f "$DOCKERFILE" "$CONTEXT"
    current="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)"
    # **The image this build superseded, removed by id and by nothing else.** Docker untags
    # the old image rather than deleting it, so a session of rebuilds leaves a stack of them
    # — and a `docker image prune` that would clear them also clears every other project's
    # dangling images on the same daemon. A failed removal is not an error here: a container
    # may still be running from it.
    if [ -n "$previous" ] && [ "$previous" != "$current" ]; then
      if docker image rm "$previous" >/dev/null 2>&1; then
        echo "  removed the superseded image ${previous#sha256:}"
      else
        echo "  the superseded image ${previous#sha256:} is still in use; it stays"
      fi
    fi
    docker image inspect -f "  $image -> {{index .RepoDigests 0}}" "$image" 2>/dev/null || true
  done
  echo
  echo "done. A build leaves its layers in the build cache; this reclaims them:"
  echo "  $0 prune"
}

# What builds leave behind, reclaimed explicitly rather than silently: untagged images (a
# superseded tag's leftovers from before this script removed them itself) and the build cache.
# It does **not** remove tagged images, volumes or containers, so a running deployment and
# every other project on the daemon are untouched.
prune() {
  docker image prune -f
  docker builder prune -f
}

list() {
  rows | while IFS=$'\t' read -r name base bundler image ruby_version; do
    present="$(docker image inspect -f '{{index .RepoDigests 0}}' "$image" 2>/dev/null || true)"
    if [ -n "$present" ]; then
      printf '%-4s ruby %-8s %s\n' "$name" "$ruby_version" "$present"
    else
      printf '%-4s ruby %-8s (not built here)\n' "$name" "$ruby_version"
    fi
  done
}

case "${1:-}" in
  build)
    shift
    build "$@"
    ;;
  list)
    list
    ;;
  prune)
    prune
    ;;
  *)
    usage
    ;;
esac
