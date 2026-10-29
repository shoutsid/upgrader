# frozen_string_literal: true

# The Rails upgrader: a client of the agents service that says what a Rails move
# costs, and — as the later phases land — makes the part of it a machine can make.
#
# Two decisions shape everything in this directory, and both are argued in:
#
# * **The ladder is the service's.** Nothing here knows that 4.2 is followed by 5.0.
#   A copy of that knowledge in this repository would be a second implementation of
#   the one rule the product is built on, and the two would disagree the first time a
#   step was added.
# * **A refusal is an output.** Every change a step carries that this tool will not
#   apply comes back in the plan with the reason and the chapter it came from.
#
# No non-stdlib dependency, deliberately: the image then needs no `bundle install`
# and no gem cache, and there is nothing to pin before the first real run. `bundler`
# itself is a default gem of the interpreter, and its lockfile parser is the
# ecosystem's own reader rather than a second one of ours.
#
# Nothing in here writes to a *caller's* source. `plan` reads; `step` edits a worktree
# this tool made (`Source.worktree`) and hands back a patch, because a tool that could
# touch an application is a tool that has to be trusted with one. `serve` keeps that
# worktree between cycles — one per repository, not one per run — because a walk is a
# sequence of steps and a tree thrown away after each one could never reach the second
# rung (`Checkpoint`).
require "agents/upgrader/version"
require "agents/upgrader/shell"
require "agents/upgrader/lockfile"
require "agents/upgrader/corpus"
require "agents/upgrader/processes"
require "agents/upgrader/repository"
require "agents/upgrader/source"
require "agents/upgrader/project"
require "agents/upgrader/projects_feed"
require "agents/upgrader/sealed"
require "agents/upgrader/bundle_groups"
require "agents/upgrader/stacks"
require "agents/upgrader/bootstrap"
require "agents/upgrader/brief"
require "agents/upgrader/effects"
require "agents/upgrader/tests"
require "agents/upgrader/suite_failures"
require "agents/upgrader/routes"
require "agents/upgrader/template_repairs"
require "agents/upgrader/sql_fragments"
require "agents/upgrader/redirect_bodies"
require "agents/upgrader/response_content_types"
require "agents/upgrader/translation_settings"
require "agents/upgrader/missing_translations"
require "agents/upgrader/errors_keys"
require "agents/upgrader/associations"
require "agents/upgrader/yaml_columns"
require "agents/upgrader/missing_gems"
require "agents/upgrader/checks"
require "agents/upgrader/applier"
require "agents/upgrader/rewrites"
require "agents/upgrader/bundler_trailer"
require "agents/upgrader/zeitwerk"
require "agents/upgrader/companions"
require "agents/upgrader/defaults"
require "agents/upgrader/ledger"
require "agents/upgrader/record"
require "agents/upgrader/interpreters"
require "agents/upgrader/machine"
require "agents/upgrader/preflight"
require "agents/upgrader/research"
require "agents/upgrader/repair"
require "agents/upgrader/publish"
require "agents/upgrader/preview"
require "agents/upgrader/republish"
require "agents/upgrader/checkpoint"
require "agents/upgrader/progress"
require "agents/upgrader/control"
require "agents/upgrader/deliveries"
require "agents/upgrader/environment"
require "agents/upgrader/filing"
require "agents/upgrader/plan"
require "agents/upgrader/block"
require "agents/upgrader/step"
require "agents/upgrader/serve"
require "agents/upgrader/cli"
