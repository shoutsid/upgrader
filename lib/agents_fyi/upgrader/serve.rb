# frozen_string_literal: true

require "fileutils"
require "time"

module AgentsFyi
  module Upgrader
    # The service: one step per repository per cycle, over a durable ledger.
    #
    # It is the miner's shape because it has the miner's problem — a process that runs
    # for weeks and must never spend a cycle re-deriving what it already settled — and
    # it differs in the one way that matters: a cycle here is hours long (a bundle
    # resolve, an `app:update`, the application's own suite), so a step that is
    # interrupted is a step that settled nothing and is simply retried. That falls out
    # of the ledger rather than needing code: only a finished step is recorded.
    #
    # Three consequences are load-bearing and all three are why this is a class and not
    # a `while true`:
    #
    # * **The heartbeat is touched once a cycle**, and it is what the container's
    #   healthcheck reads. A process that is up and stuck is the failure a healthcheck
    #   exists to catch, and "up" says nothing about it.
    # * **A signal stops the loop between steps**, not in the middle of one: the ledger
    #   is saved and the container exits, and whatever was in flight is retried at the
    #   next start. A stop request that slept through a ten-minute interval would be a
    #   container the runtime SIGKILLs for no reason.
    # * **The step is a class this loop is handed** rather than one it constructs. Not
    #   for elegance: every one of the behaviours above is about a process that has been
    #   running for hours, and a loop that could only be exercised by cloning a
    #   repository and installing a Rails bundle is a loop whose restart, heartbeat and
    #   stop behaviour have never once been run.
    class Serve
      # How many targets one queue read asks for.
      #
      # Bounded, and the bound is refreshed by doing the work rather than by asking for
      # everything: a target stops being offered once a run has been recorded against it. The
      # number is also a reminder from the miner's own history — a client that asks for more
      # than the service will serve gets a refusal rather than a longer list, and a refusal
      # read as "no queue" is how the queue this service computes went unused for as long as
      # it did. expects the *service* to own the order, so this asks for a slice of it and
      # comes back.
      DEFAULT_QUEUE_LIMIT = 100

      # How many rungs `--walk` chains in one cycle. A budget rather than "until the top":
      # one rung is a bundle install and a test suite, and a cycle that never returned would
      # leave the heartbeat untouched for a day — which is the failure the heartbeat is for.
      DEFAULT_RUNGS_PER_CYCLE = 3

      # The first retry delay for a rung that did not pass, doubled while the same rung keeps not
      # passing and capped at the interval. Thirty seconds rather than the interval because the
      # usual reason a rung does not pass is one somebody has just changed something for — and ten
      # minutes of waiting is a window in which nobody can tell whether the change worked.
      BACKOFF_FLOOR = 30

      # `contribute` is passed through to every step, and the default is the difference
      # between this class and `step` run by hand: the loop owns an operator's account and
      # the decision to walk somebody's application at all, so a run made here is the one
      # that goes into the corpus — the run record the queue and the coverage figure are
      # built from, and a report for a failure. A person asking what a move costs is not
      # asking to write into a corpus other operators read, so `step` leaves it off.
      def initialize(api:, home:, heartbeat:, to: nil, repos: [], interval: 600,
                     step_timeout: 3600, out: $stdout, ledger: nil, cycles: nil,
                     corpus: nil, step_class: Step, queue_limit: DEFAULT_QUEUE_LIMIT,
                     contribute: true, walk: false, publish: false, rungs: nil,
                     publish_class: Publish, suite_env: nil, services: nil, env: ENV,
                     force: false, record: nil)
        @api = api
        @home = home
        @to = to
        # The environment the steps are built with, for the same reason the CLI passes one: a knob the loop
        # reads and the step does not is a knob that does nothing.
        @env = env
        # `walk` is the difference between a loop that takes one rung per cycle and one that
        # walks a repository to its target in a cycle: it chains rungs while they pass, up to
        # `rungs` (a budget, because one rung can take half an hour and a cycle that never
        # returned would hold the ledger uncommitted for a day). With it, an empty `--to` is
        # read as "the top of the service's ladder" — the read that exists for exactly this —
        # instead of the deliberate idle an empty target means without it.
        @walk = walk
        # The services a host-run walk talks to, one container for the whole loop (see
        # `Machine::Services`): a step must not own it, because the next step needs it too.
        @services = services
        @publish = publish
        # **`force` reaches the step, because the step is where the ledger's "settled" answer is read.**
        # The loop has no opinion about it of its own, and a flag the loop swallowed would look like it
        # had walked a rung it never touched — measured, `serve --walk --force` printed "already settled:
        # passed" and ran nothing, which reads as a walk that finished rather than one that was skipped.
        @force = force
        # **Where each step writes its patch and its JSON record.** The option was advertised and thrown
        # away: `serve --record DIR` accepted the argument and passed nothing, so a walk's evidence
        # lived only in the corpus — and a record the corpus answers `duplicate` for (which is what
        # every one of the lighthouse's failed 5.1 runs got) was stored nowhere. A step's record is
        # named for the move it made (`<repo>-<from>-<to>.json`), so a walk of several rungs writes one
        # file each rather than overwriting the one before it.
        @record = record
        @rungs = rungs || DEFAULT_RUNGS_PER_CYCLE
        # Injectable so the suite can drive "a passed rung is published" without a token, a
        # remote or a network — the class itself is `publish_test.rb`'s subject.
        @publish_class = publish_class
        # The deployment's own values for the applications it walks, passed to every step this
        # loop makes (see `Step#read_env_file` for the shape and the reason).
        @suite_env = suite_env
        @heartbeat = heartbeat || File.join(home, "heartbeat")
        # `Array(...)` rather than the parameter's own default, and it is not cosmetic:
        # `repos:` defaults to `[]` so a caller may leave it out, but the CLI passes the
        # `--repo` flag's value, which is `nil` when nobody named a repository — and a
        # default does not apply to a key that *is* present. `nil` and `[]` mean the same
        # thing here (no repositories named), so they are one value before any reader sees
        # them. Found in the deployment rather than here: its container crash-looped on
        # `nil.empty?` at startup with no repository list and no target, which is exactly
        # the configuration a loop waiting for a queue has.
        @repos = Array(repos)
        @interval = interval
        @step_timeout = step_timeout
        @out = out
        # **What the loop is doing, where the operator's console can read it.** The step announces
        # its own stages; this is what the loop itself announces — the interval between cycles,
        # which is otherwise indistinguishable from a step that has stopped moving.
        @progress = Progress.new(home: home, out: out)
        @ledger = ledger
        @cycles = cycles
        # Built here rather than lazily, and defaulted rather than required, because the
        # CLI constructs this object without one: a loop that only knows how to read a
        # queue when a test handed it a corpus is a loop whose queue path has never run.
        @corpus = corpus || Corpus.new(base: @api)
        @step_class = step_class
        @queue_limit = queue_limit
        @contribute = contribute
        @stop = false
      end

      def run
        @ledger ||= Ledger.load(File.join(@home, "ledger.json"))
        install_traps

        # The one line that tells an operator whether the volume is still there. A lost
        # `miner_cache`-style volume resets a service to "nothing examined" while the
        # container looks completely healthy, so the count is printed before any work.
        @out.puts("serve: #{@ledger.size} move(s) already settled; #{work_from}")
        # The target is required here for the same reason `plan` requires it: the ladder
        # is the service's and this tool keeps no copy, so a loop that picked "the next
        # release" would be deciding which rung the operator meant.
        if @to.to_s.empty? && !@walk
          @out.puts("serve: no target, so this loop will not walk anything — set " \
                    "UPGRADER_TO to the Rails release the move ends at, or `--walk` to walk " \
                    "to the top of the service's ladder")
        end

        cycle = 0
        pause = 0
        until @stop
          cycle += 1
          outcome = walk
          touch
          break if @cycles && cycle >= @cycles

          pause = delay_for(outcome, previous: pause)
          nap(pause, outcome)
        end

        @ledger.save!
        # **A stopped loop has nothing in flight, and says so.** The file is what the console's Now
        # panel reads, a step clears it when it finishes, and a *loop* that stops between steps — the
        # end of a walk, or an operator's SIGTERM — left its last one behind, so the panel went on
        # saying "running this" until `STALLED_SECONDS` (twenty minutes) caught up. Measured on this
        # deployment: the walk finished at 17:45 and the file still read a step at 17:52 with nothing
        # running. A stopped loop is not a stalled one, and the honest answer is the empty file.
        @progress.clear
        @out.puts("serve: stopped after #{cycle} cycle(s) with #{@ledger.size} move(s) settled")
        0
      end

      private

      # Where this cycle's work comes from, said once at startup so an operator can tell
      # a deployment that names its own repositories from one that is being given them.
      def work_from
        return "#{@repos.size} repository(ies) to walk" unless @repos.empty?

        "the work list comes from the service's queue"
      end

      def walk
        return :idle if target.nil?

        outcomes = work.map { |spec| walk_spec(spec) }
        return :blocked if outcomes.include?(:blocked)

        outcomes.include?(:worked) ? :worked : :idle
      end

      def walk_spec(spec)
        repository, ref = self.class.split(spec)
        return walk_repository(repository, ref) if @walk

        record = run_one(repository, ref)
        return :idle if record.nil?

        record.passed? ? :worked : :blocked
      end

      # The target every step in this cycle moves towards: the one the operator named, or —
      # under `--walk` — the top of the service's ladder. Asked once per cycle and cached,
      # because it is a fact about the service rather than about a repository, and a cycle
      # that walked five rungs should not have asked five times.
      #
      # `nil` means this loop has nothing to walk towards and says so; without `--walk` that
      # is the deliberate idle an unset target has always meant.
      def target
        return @to unless @to.to_s.empty?
        return nil unless @walk

        @target ||= @corpus.ladder.fetch("top")
      rescue Corpus::Unreachable, Corpus::Refused, KeyError => e
        @out.puts("serve: the ladder could not be read (#{e.message}), so this cycle will not walk")
        nil
      end

      # One repository, walked: rungs taken while they pass, up to the cycle's budget, and
      # each passed rung published when the operator asked for that.
      #
      # **The outcome is returned because it decides whether the loop waits**, and inferring it
      # from the log is how the loop came to pause ten minutes after a rung that had just passed:
      # `:blocked` is a rung that ran and did not pass (retry soon, not instantly), `:idle` is a
      # move the ledger had already settled (nothing ran at all), and `:worked` is a passed rung,
      # where the next one is ready now.
      def walk_repository(repository, ref)
        @rungs.times do
          record = run_one(repository, ref)
          return :idle if record.nil?

          return :blocked unless record.passed?

          publish(record) if @publish
        end
        :worked
      end

      # A passed rung's branch and pull request, from the record the step produced. A publish
      # that did not happen is a line rather than a raised exception: the rung *passed*, and
      # a branch that could not be pushed does not un-pass it.
      def publish(record)
        result = @publish_class.new(
          root: record.worktree.to_s.empty? ? @home : record.worktree,
          repository: record.repository, from_version: record.from_version,
          to_version: record.to_version, record: record, out: @out,
          token: ENV[Publish::ENV_TOKEN]
        ).call
        @out.puts("serve: #{record.repository} — #{result}")
      end

      # The operator's list wins when there is one — a deployment that named its repositories
      # meant it, and it is also what this container still ships with — and the service's
      # queue is what answers when there is not.: whoever can reach the network fetches, and
      # the service decides what it means; the whole point of the queue is that the order in
      # it is the corpus's answer rather than a list somebody pasted into a compose file.
      def work
        @repos.empty? ? queued : @repos
      end

      # The queue as shorthand specs, or nothing at all when the service could not be
      # asked.
      #
      # A failed read is *never* silently an empty queue: the loop says which it got and
      # comes back next cycle, because an outage and "there is no work" want opposite
      # responses and the miner's own trap is a fallback that caught everything and turned
      # a permanent refusal into a quiet afternoon. Empty and unreachable both leave the
      # loop running, which is the one thing they have in common and the only thing the
      # caller does about either.
      def queued
        rows = @corpus.targets(limit: @queue_limit)
        specs = rows.to_a.filter_map { |row| self.class.spec_from(row, out: @out) }
        if specs.empty?
          @out.puts("serve: the service's queue is empty, so this cycle has nothing to walk")
        end
        specs
      rescue Corpus::Unreachable => e
        @out.puts("serve: could not read the queue (#{e.message}) — this cycle walks nothing")
        []
      end

      # **The class methods in this file are public, and the `private` markers around them
      # govern instance helpers only** — a bare `private` cannot reach a singleton method,
      # which is what `Lint/IneffectiveAccessModifier` reports. Two callers make that a
      # decision rather than an accident: the upgrader's suite drives `Serve.split` directly
      # (`test/serve_test.rb`), and `walk`/`queued` call `self.class.split` and
      # `self.class.spec_from` with an explicit receiver, which a private method refuses.
      public

      # A queue row as the shorthand `walk` understands. A row naming no repository is
      # *stated* rather than dropped: a target that the loop silently refuses to walk is
      # indistinguishable from an empty queue, and that is the shape of a bug that runs
      # for weeks.
      def self.spec_from(row, out:)
        url = row.is_a?(Hash) ? row["repo_url"].to_s : ""
        if url.empty?
          out.puts("serve: the queue named a target with no repository — skipped")
          return nil
        end

        ref = row["ref"].to_s
        ref.empty? ? url : "#{url}@#{ref}"
      end

      private

      # One repository, one step. `nil` means the move it resolved to was already
      # settled, which is not an error: it is the ledger doing its job, and it is worth a
      # line because it is also what a lost volume would look like from the other side.
      def run_one(repository, ref)
        record = @step_class.new(
          repository: repository, ref: ref, to: target, api: @api, home: @home, out: @out,
          suite_env: @suite_env,
          ledger: @ledger, suite_timeout: @step_timeout, contribute: @contribute,
          corpus: @corpus, reuse: true, services: @services, env: @env, force: @force,
          record: @record
        ).run
        if record.nil?
          @out.puts("serve: #{repository} — already settled, so nothing was run")
          return nil
        end

        @out.puts("serve: #{repository} -> #{record.verdict} (#{record.to_version})")
        settle(record)
        record
      rescue Lockfile::Missing, Lockfile::Unreadable, Source::Failed, Corpus::Unreachable => e
        # One repository's bad minute is not the loop's: it is logged, the next
        # repository is walked, and the cycle's heartbeat still moves — a service that
        # died because one clone failed is a service that stops working for everybody.
        @out.puts("serve: #{repository}: #{e.class}: #{e.message}")
      end

      # What the tree becomes, and this is the difference between a loop and a loop that
      # walks. A step this loop *kept* the tree for has to hand it on in one of two
      # states, and neither is "as the step left it":
      #
      # * **passed** — committed, so the next cycle's base commit is where this step
      #   arrived and the ladder is asked for the rung after it. Without this the next
      #   cycle re-reads the same base, plans the same move, and finds its own ledger
      #   entry: a repository that has been walked once and is now stuck for ever, which
      #   is exactly the failure this project keeps finding in services that look healthy.
      # * **anything else** — reset to the base commit. The tree holds a rewritten pin and
      #   half a move that nobody has shown to work, and the next cycle must retry the same
      #   rung from the same place rather than plan the next one from a release that was
      #   never established.
      def settle(record)
        root = record.worktree.to_s
        return if root.empty? || !File.directory?(root)

        if record.passed?
          commit = Checkpoint.commit(root, from: record.from_version, to: record.to_version, out: @out)
          @out.puts("serve: #{record.repository} — the step is committed as #{commit.to_s[0, 8]}, " \
                    "so the next cycle plans from #{record.to_version}")
        else
          Checkpoint.reset(root)
          @out.puts("serve: #{record.repository} — #{record.verdict} advances nothing, so the tree " \
                    "is back at its base commit")
        end
      end

      # The marker is back for the same reason it is above: the two methods below are
      # public, and the one after them is not.
      public

      # `owner/name@ref` is a person's shorthand, and the ref is optional. A URL is left
      # alone, because somebody who typed one meant it, and so is a **path**.
      #
      # An ssh URL is decided *before* the split, because it has an `@` of its own:
      # `git@github.com:acme/storefront.git` split on `@` would name a repository called
      # `git` and a ref of `github.com:acme/storefront.git`, which is a clone of nothing
      # and a ledger entry under a URL nobody can look up.
      #
      # A path is the other half of that rule, and it was missing: the service's
      # `identity()` deliberately lets an operator name a directory on a machine that has
      # it — a target whose `repo_url` is a path is a legitimate row — and this method
      # turned every bare spec into `https://github.com/<spec>.git`, so a queue the
      # service had accepted became a clone of nothing. The tell was the shorthand's own
      # form: `work/app` is not `owner/name`.
      def self.split(spec)
        return [spec, nil] if spec.start_with?("git@")

        # Split first, then decide what the left half is: a path may carry a ref of its
        # own (`./storefront@main`), and deciding on the whole spec would read that as one
        # path with an `@` in its name.
        repository, ref = spec.split("@", 2)
        return [repository, ref] if repository.include?("://") || path?(repository)

        ["https://github.com/#{repository}.git", ref]
      end

      # Whether a spec names something on this machine — by *spelling*, never by asking the
      # filesystem. Absolute, explicitly relative and `~`-rooted only: a bare `storefront`
      # is a shorthand for a GitHub repository, and a spec that happened to be a directory
      # of the current working directory would be ambiguous, which is the shape a person
      # reads as a repository name.
      def self.path?(spec)
        spec.start_with?("/", "./", "../", "~")
      end

      # Its only caller is `split`, above, so it is the one helper here that can be tight.
      private_class_method :path?

      private

      # The healthcheck's file. Written every cycle, whatever the cycle did.
      def touch
        FileUtils.mkdir_p(File.dirname(@heartbeat))
        File.write(@heartbeat, "#{Time.now.utc.iso8601}\n")
      end

      # A flag checked in short steps, rather than a queue the trap handler pushes to.
      #
      # The tidier idiom is `Queue#pop` under a timeout with the handler pushing to wake
      # it, and it is wrong here for one reason: a trap handler runs in a context where
      # some thread primitives are off limits, and the failure that gets wrong is a
      # container that cannot be stopped at all — the runtime SIGKILLs it after the grace
      # period, mid-step, which is exactly what `stop_grace_period` exists to avoid. Half
      # a second of granularity against an interval measured in minutes costs nothing and
      # is a stop request that is always answered.
      # **How long the loop waits, and why it waits at all.** Its own work is never a reason to
      # pause. The interval's stated justification — "a loop that walked faster would re-read ledgers
      # that cannot have changed" — is an argument against *spinning*, not against doing the next
      # useful thing, and it was applied after **every** cycle: a rung that had just passed waited
      # ten minutes before the next one began, which is latency bought for nothing. Two things are
      # worth waiting for:
      #
      # * **Nothing to do** — an empty queue, or a target whose rungs are settled — where the interval
      #   is genuinely the poll's period.
      # * **A rung that just did not pass** — retrying instantly would spin on the same command, and
      #   retrying in ten minutes wastes a window in which somebody may have just fixed what stopped
      #   it. So that delay starts at `BACKOFF_FLOOR` and doubles while the same rung keeps not
      #   passing, capped at the interval; a passed rung resets it.
      def delay_for(outcome, previous:)
        return 0 if outcome == :worked
        return [previous.zero? ? BACKOFF_FLOOR : previous * 2, @interval].min if outcome == :blocked

        @interval
      end

      # The loop's own rest, said out loud and shown to the console: a *stalled* step and a sleeping
      # loop look nothing alike from outside unless the loop says which it is.
      def nap(seconds, outcome)
        return if seconds <= 0

        reason = outcome == :blocked ? "the rung did not pass; retrying" : "nothing to do"
        @out.puts("serve: sleeping #{seconds}s (#{reason})")
        @progress.cycle(note: "waiting #{seconds}s — #{reason}")
        deadline = Time.now + seconds
        sleep(0.5) until @stop || Time.now >= deadline
      end

      def install_traps
        %w[TERM INT].each do |signal|
          Signal.trap(signal) { @stop = true }
        end
      end
    end
  end
end
