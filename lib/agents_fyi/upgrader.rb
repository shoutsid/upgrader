# frozen_string_literal: true

# The Rails upgrader: a client of the agents-fyi service that says what a Rails move
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
require "agents_fyi/upgrader/version"
require "agents_fyi/upgrader/lockfile"
require "agents_fyi/upgrader/corpus"
require "agents_fyi/upgrader/source"
require "agents_fyi/upgrader/tests"
require "agents_fyi/upgrader/applier"
require "agents_fyi/upgrader/ledger"
require "agents_fyi/upgrader/record"
require "agents_fyi/upgrader/checkpoint"
require "agents_fyi/upgrader/filing"
require "agents_fyi/upgrader/plan"
require "agents_fyi/upgrader/step"
require "agents_fyi/upgrader/serve"
require "agents_fyi/upgrader/cli"
