# frozen_string_literal: true

require "fileutils"
require "open3"

module AgentsFyi
  module Upgrader
    # One step of a move, executed on a working copy this tool owns.
    #
    # The pipeline is, in its order, and the two stages that make the rest mean anything are
    # the first two: a **worktree** the caller's files are not in, and a **baseline** run of
    # the unmodified copy. Without the baseline, "the upgrade broke the suite" and "the suite
    # was already red" are one sentence, and the second files a report blaming a release for a
    # pre-existing breakage.
    #
    # The third thing that makes the rest mean anything arrived when the lighthouse did: an
    # **interpreter**. An application old enough to be interesting cannot be installed on the
    # Ruby running this tool, so the step *chooses a machine* before it installs anything —
    # this process when the caller says so and its interpreter meets the step's floor, an era
    # container otherwise (`Machine`, `Interpreters`) — and every application-level command
    # from then on goes through it. A step records which machine produced its verdict, because
    # "the bundle could not be installed" is a different sentence on Ruby 2.1 than on 3.3.
    #
    # Everything external is injectable — the runner, the corpus, the applier, the
    # suite detector, the source resolver, the machine — because a step that installs a
    # bundle and boots an application is not a thing a unit test can do, and the parts that
    # decide (the verdict, the pin rewrite, which files `app:update` may keep, which
    # interpreter is tried) are exactly the parts that must be tested.
    class Step
      # One step, never a walk: `--to` names where the operator wants to end up, and this
      # executes the *first* rung towards it. — one minor release at a time, never skipped.
      DEFAULT_SUITE_TIMEOUT = 1800

      # What a scan will carry. The service bounds a request body and an application's
      # source is not a payload, so the walk sends the files a plan is about — and says
      # in the record when it stopped, rather than sending a slice and calling it done.
      SCAN_SUFFIXES = %w[.rb .rake .erb .yml .ru].freeze
      SCAN_SKIP = %w[.git vendor node_modules tmp log public/assets storage coverage].freeze
      MAX_SCAN_FILES = 240
      MAX_SCAN_BYTES = 262_144

      # Which machine executes this step's application-level commands. `docker` means the
      # era matrix; `native` means this process; empty means `native`, and that default is a
      # decision rather than a shrug. A deployment that walks other people's applications sets
      # `docker` explicitly (`docker-compose.yml` does), a person runs `step` by hand on a
      # machine with the right interpreter, and — the measured half — the unit suite runs
      # with no daemon at all, so a default of "docker if it happens to be there" would make
      # every test of the pipeline a test that could talk to a container runtime.
      # Which machine this step executes on — see `Machine::RUNTIME_ENV` for the three answers.
      RUNTIME_ENV = Machine::RUNTIME_ENV

      # How many new framework defaults one step may try. **Off unless a number says otherwise**,
      # because every toggle is a suite run: the same posture as the repair budget, for the same
      # reason — a deployment decides what it spends.
      DEFAULTS_ENV = "UPGRADER_DEFAULT_STEPS"

      # How many times the pin may be re-run with the gems bundler named. Each round is a
      # resolve, and bundler names what it could not leave alone, so a real application needs
      # one or two; the cap is what keeps a pathological cascade from spending a walk.
      # **A build failure is a chain, and each round names the next link.** Measured at the 7.2 rung: the
      # first install died on `nio4r 2.3.1`, the update that named it resolved all three gems the output
      # was building (`nio4r 2.7.5`, `msgpack 1.8.5`, `ruby-prof 2.0.5`), and the install that followed
      # died on `bootsnap 1.4.5`, which the same output had announced. The bound is there because a lock
      # can name a gem whose newest release still will not build, and a walk that never ended would be
      # worse than one that stopped.
      BUNDLE_REPAIR_ROUNDS = 4

      PIN_ROUNDS = 5

      # Whether this run goes into the shared corpus: the run record the queue and the
      # coverage figure are built from, and — for a failure — a report filed through
      # precheck. Off by default, and `serve` is what turns it on. The reason is that a
      # person who runs `step` by hand asked what a move costs, not to write into a
      # corpus other operators read; the loop is the thing that owns an account, a cycle
      # and the decision to walk somebody's application at all.
      def initialize(
        repository:, to:, ref: nil, api: nil, home:, out: $stdout,
        work: nil, record: nil, ledger: nil, suite_timeout: DEFAULT_SUITE_TIMEOUT,
        runner: Shell, corpus: nil, source: Source, tests: Tests, applier: Applier,
        contribute: false, reuse: false, machine: nil, machine_factory: nil, runtime: nil,
        research: nil, env: ENV, repair: nil, force: false, suite_env: nil, services: nil
      )
        @repository = repository
        @to = to
        @ref = ref
        @api = api
        @home = home
        @out = out
        @work = work
        @record_dir = record
        @ledger = ledger
        @suite_timeout = suite_timeout
        @runner = runner
        @corpus = corpus
        @source = source
        @tests = tests
        @applier = applier
        @contribute = contribute
        # Whether this step owns its working copy or shares the loop's. A hand-run step
        # takes a fresh copy per run — two runs of the same move measured in the same
        # directory are two runs whose second one starts from the first one's edits — and
        # a *walk* keeps one tree per repository, because the second rung of a move starts
        # where the first one arrived (`Source.kept`).
        @reuse = reuse
        # Three seams for the machine, and each has a caller:
        #
        # * `machine` is a machine a test hands in whole — the pipeline is driven without a
        #   container runtime, and the machine it runs on is a stub that composes argv the way
        #   the real one does.
        # * `machine_factory` builds one per *era*, which is what makes the selection
        #   testable: a test states what each era's `bundle install` would do and asserts which
        #   era the step ends up on and why the others were rejected.
        # * `runtime` pins the mode ("docker"/"native") instead of reading `RUNTIME_ENV` from
        #   the process, so a test does not have to mutate the environment to ask the
        #   question.
        @machine = machine
        @machine_factory = machine_factory
        @runtime_mode = runtime
        # The research pass, injectable so the suite can drive the routing's `unknown` path
        # without fetching an index — the one thing in this file that reaches a third party.
        @research = research
        # The repair loop, injectable for the same reason one layer out: a test of what a
        # repaired step *does* must not spend a model call. `nil` is the real class, and the
        # environment is where its budget lives (`Repair.budget`), so a deployment turns it
        # on with a number and a step by hand stays off.
        @repair = repair
        @env = env
        @services = services
        # **The ledger is a memory, not a lock.** `--force` is the operator saying "walk this
        # rung now" — after fixing whatever made the last attempt unverifiable, after an image
        # rebuild, or simply to see it again — and the record says the ledger was set aside so
        # a forced attempt is never read as an ordinary one. The loop never passes it: a walk
        # that ignored its own memory would re-derive every rung every cycle.
        @force = force
        # **The application's own environment, when the deployment knows it.** A repository
        # that carries no secrets is the ordinary case, not the exception: this walk's first
        # real application reads `ENV["RAILS_SECRET_TOKEN"]` and that value lives in a
        # git-ignored `config/application.yml` (figaro), so a fresh clone cannot boot its own
        # suite. Nothing here invents a value — the file is the operator's, its lines are
        # `KEY=VALUE`, and they are merged into every command that runs *the application*
        # (the suite, the database preparation, the update, the boot) and never into the
        # bundle or the machine commands, which are this tool's own.
        @suite_env = read_env_file(suite_env)
      end

      def run
        stages = []
        @applied = []
        @refused = []
        @decisions = []
        @out.puts("step: #{@repository} -> #{@to}") if @out

        # What finished runs left behind, reclaimed before this one adds to it: the home is the
        # bind mount the step's own container is given, and its size is paid at `docker run`.
        Source.prune_bundles(home: @home, out: @out)

        prepared = prepare(stages)
        record = prepared if prepared.is_a?(Record)
        return finish(record) if record

        @worktree, @lockfile, pinned = prepared
        @from = pinned.version

        # The plan comes from the service and nowhere else: this tool keeps no copy of
        # the ladder, so a move it cannot ask about is a move it cannot make.
        step = planned(stages)
        return finish(step) if step.is_a?(Record)

        @out.puts("  step: #{step["name"]} (#{step["from_version"]} -> #{step["to_version"]}), " \
                  "requires Ruby #{step["requires_ruby"] || "unstated"}") if @out

        # The ledger, consulted *before* anything runs: a settled move is the whole
        # point of keeping one, and a step costs a bundle resolve and a suite. `nil`
        # means "nothing ran because there was nothing to do", which the loop reports
        # as such rather than as a step that produced a verdict.
        entry, settled = settled_entry(step)
        if settled
          @out.puts("  already settled: #{entry.verdict} — #{entry.note}") if @out
          return nil
        end

        # The machine, before the bundle: `bundle install` is what decides whether the
        # interpreter can serve this application at all, so it is the probe and the install
        # in one command (see `choose_machine`). But first the *Gemfile* has to be
        # installable at all, and that is the preflight's half — a `git://` remote GitHub
        # no longer accepts, a fork that has been deleted, a pin that cannot sit beside the
        # framework. Its repairs are edits this step made; everything it will not rewrite
        # travels as a decision.
        preflight = preflight_stage(stages, step)
        @applied.concat(preflight.repairs)
        @decisions.concat(preflight.decisions)

        choice = choose_machine(stages, step, preferred: entry&.era)
        return finish(choice) if choice.is_a?(Record)

        @machine, install = choice
        @out.puts("  interpreter: #{@machine.interpreter}" \
                  "#{@machine.image.to_s.empty? ? "" : ", image #{@machine.image}"}") if @out
        return finish(install_record(install, stages)) unless install.ok?

        # The services the suite expects, started before anything is measured, and a
        # required stage: a suite that ran without its database failed for a reason nobody
        # reading the record could see.
        services = services_stage(stages)
        if services && !services.ok?
          verdict, why = Record.verdict(baseline: nil, suite: nil, stages: stages)
          return finish(build(step, stages, verdict, why))
        end

        database_stage(stages)

        # The baseline, on the unmodified copy, before anything is written.
        # The baseline, on the unmodified copy, before anything is written — the
        # *move's* edits, that is: the preflight above has already made the Gemfile
        # installable, and that is a precondition of measuring anything rather than a
        # change the move is being judged for. Both halves are in the record, under their
        # own stages.
        @baseline = baseline(stages)

        # **The baseline first, and this is the case old applications actually arrive in.** A
        # suite that was red before the step makes everything after it unmeasurable
        # (`Record.verdict`), and for an application from 2013 that is ordinary rather than
        # exceptional: the lighthouse's own suite was 133 examples red on `You must set
        # config.secret_key_base in your app's config`, which is a 4.0.0.rc1-era generator
        # writing `secret_token` while the framework already wanted `secret_key_base`. The
        # repair is bounded exactly as the post-move one is, the re-run baseline is what makes
        # it green, and the patch carries it — so a reviewer reads "the suite was red; this
        # made it green; then the move", in that order.
        if @baseline && !@baseline.ok?
          repaired = repair(stages, step, subject: @baseline, before_the_move: true,
            rerun: -> { @baseline = run_suite(stages, Record::BASELINE) })
          @baseline = repaired || @baseline
        end

        applied, refused, decisions = apply(stages, step)
        @applied.concat(applied)
        @refused.concat(refused)
        @decisions.concat(decisions)

        # The gems that have to move with this rung, before the Rails pin is rewritten: the
        # routing's `move` verdicts are what a `bundle update rails` cannot work out for
        # itself, and applying them first is what makes the pin's failure (if it fails) be
        # about Rails.
        gem_moves(stages, step)

        pin = rewrite(stages, step)
        return finish(pin) if pin.is_a?(Record)

        update(stages)
        migrate_after_update(stages)
        boot(stages)
        @suite = suite(stages)

        # **The new defaults, stepped, and only after the move's own suite passed.** A red run here
        # is then about the toggle and never about the move, which is what makes "revert this one"
        # the right answer rather than a guess. Off unless a number says otherwise: every toggle is
        # a suite run, and a deployment that has not decided to spend that must not have it spent.
        step_defaults(stages, step)

        # **The agentic half, and the last thing before the verdict.** A step that ran a green
        # baseline and a red suite has a failure attributable to the move, which is what makes
        # repair a measurement rather than a hope; the attempt(s) and the suite they were
        # followed by are stages, so the record says how the rung was reached.
        repair(stages, step, subject: @suite, rerun: -> { @suite = run_suite(stages, Record::SUITE) })

        verdict, why = Record.verdict(baseline: @baseline, suite: @suite, stages: stages)
        finish(build(step, stages, verdict, why))
      ensure
        # **The container is a step's, and the step's process is what ends it.** `--rm` only
        # removes a container whose own process exits, and this one is a keepalive that never
        # does: without this line every step — passed, failed or refused halfway — leaves a
        # container running, and eight of them had accumulated before the first `docker ps`
        # looked. It is in an `ensure` because the paths that matter most are the ones that
        # raise, and `stop!` never raises for the same reason. A process that is *killed* runs
        # no `ensure` at all, which is what `Machine::Container.reap!` answers.
        @machine&.stop!
      end

      private

      # A working copy, and the two facts about the application that decide whether the
      # rest is worth doing.
      #
      # A kept tree is put back to its base commit first, and the reason is the shape of a
      # process that runs for weeks: a cycle killed mid-step — the memory limit, a
      # SIGKILL after the grace period, the machine going away — leaves a tree that is
      # half a move, and the next cycle would otherwise plan from a Gemfile.lock the
      # interrupted step had already rewritten. That is a *skipped rung*, reported as a
      # step that passed. An interrupted step settled nothing, so the tree it was
      # measured in holds nothing either.
      def prepare(stages)
        @worktree = @source.worktree(@repository, ref: @ref, home: @home, run: run_id, reuse: @reuse)
        if @reuse && Checkpoint.dirty?(@worktree.root)
          Checkpoint.reset(@worktree.root)
          @out.puts("  working copy: reset to #{@worktree.commit.to_s[0, 8]} — a step was interrupted here") if @out
        end
        @lockfile = Lockfile.read(@worktree.root)
        pinned = @lockfile.rails
        unless pinned
          return Record.refused(
            repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
            from_version: "unknown", to_version: @to,
            why: "no Rails release is pinned under #{@worktree.root}: neither the meta-gem " \
                 "nor any framework component is in Gemfile.lock, so there is nothing to step from"
          )
        end
        [@worktree, @lockfile, pinned]
      rescue Source::Failed => e
        Record.refused(repository: @repository, from_version: "unknown", to_version: @to, why: e.message)
      rescue Lockfile::Missing, Lockfile::Unreadable => e
        Record.refused(repository: @repository, from_version: "unknown", to_version: @to, why: e.message)
      end

      # The ledger entry for this move, and whether it is settled *for the machine that
      # would run it now*. The expected machine is computed cheaply — the era the selection
      # would try first, or this process — and never by starting a container: the check
      # exists to avoid spending a cycle, and a probe here would spend most of one.
      def settled_entry(step)
        return [nil, false] unless @ledger

        entry = @ledger.find(repo: @repository, commit: @worktree.commit,
          from_version: step["from_version"], to_version: step["to_version"])
        return [nil, false] unless entry
        if @force
          @out.puts("  ledger: #{entry.verdict} for this move is set aside (--force)") if @out
          return [entry, false]
        end

        settled = @ledger.settled?(
          repo: @repository, commit: @worktree.commit,
          from_version: step["from_version"], to_version: step["to_version"],
          machine: expected_machine(step, entry)
        )
        [entry, settled]
      end

      # The machine a step would run on, as the stamp the ledger compares. Deliberately the
      # *first candidate* rather than the one that would be probed into: the stamp's job here
      # is to answer "is what is already recorded still the machine this step would get", and
      # after a probe the ledger records the era that worked, which the next cycle prefers and
      # therefore computes first again (`Interpreters.candidates`).
      def expected_machine(step, entry)
        return @machine.stamp if @machine
        return native_stamp unless docker_mode?

        candidates = candidates_for(step, entry&.era)
        return native_stamp if candidates.empty?

        build_machine(candidates.first).stamp
      end

      # This process's own identity, asked of the ledger when there is one: `Ledger.machine`
      # is the one place that stamp is decided, and a step that computed its own would be a
      # second copy of the rule — which is how two answers to one question start disagreeing.
      def native_stamp
        @ledger ? @ledger.machine : Machine::Native.new.stamp
      end

      def planned(stages)
        stages << command(Record::PREPARE, ["git", "rev-parse", "--short", "HEAD"],
          chdir: @worktree.root)
        corpus = @corpus || Corpus.new(base: @api)
        payload = corpus.upgrade(from: @from, to: @to)
        step = payload.fetch("steps", []).first
        unless step
          return Record.refused(
            repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
            from_version: @from, to_version: @to,
            why: "the service returned no step for #{@from} -> #{@to}: #{payload["next_step"]}"
          )
        end
        step
      rescue Corpus::Refused => e
        # The service's own sentence, kept whole: it says which direction this ladder
        # reads, or which release it has no chapter for, and that is the part that
        # changes what the caller does next.
        Record.refused(repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
          from_version: @from, to_version: @to, why: e.message)
      rescue Corpus::Unreachable => e
        Record.refused(repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
          from_version: @from, to_version: @to,
          why: "#{e.message} (a step needs the ladder, so nothing was attempted)")
      end

      # The agentic half: a green-baseline/red-suite step gets a bounded number of attempts by
      # a model in the worktree, with the failure as its brief, before the verdict is written.
      #
      # The preconditions are the whole of what makes it measurable. The baseline was green, so
      # the failure is the move's rather than the application's; the suite actually ran, so
      # there is a failure to repair at all; and the suite is red. A repaired step is still
      # `passed` only because the *suite* says so afterwards — the model's word is never what
      # passes a rung, and the attempt is in the record either way.
      def repair(stages, step, subject:, rerun:, before_the_move: false)
        return nil if subject.nil? || !subject.ran || subject.ok?
        # A post-move repair is only meaningful against a green baseline: with a red one, the
        # failure is the application's and there is nothing to attribute to the move. The
        # baseline's own repair is the one case where "red" is the subject.
        return nil if !before_the_move && (@baseline.nil? || !@baseline.ok?)

        repairer = @repair || Repair
        budget = repairer.budget(@env)
        return nil if budget.nil?

        result = repairer.new(
          root: @worktree.root,
          evidence: {
            repository: @repository, from_version: step["from_version"],
            to_version: step["to_version"], suite_command: @suite_plan&.command,
            interpreter: @machine.interpreter, image: @machine.image,
            applied: @applied, refused: @refused,
            # **The residue, not the blanket.** A decision with a path and a line is a call site
            # this application has; one without is a change this rung carried that the application
            # does not use, and a brief that listed both equally taught the agent to hunt for
            # sixteen things when three exist.
            decisions: @decisions.select { |decision| !decision.path.to_s.empty? },
            carried: @decisions.count { |decision| decision.path.to_s.empty? },
            unapplied_rules: @unapplied_rules || [],
            output_tail: subject.output_tail
          },
          budget: budget, env: @env, out: @out, rerun: rerun, before_the_move: before_the_move,
          config_dir: File.join(@home, "repair"),
          on_attempt: ->(attempt) { stages << repair_stage(attempt) }
        ).run
        @out.puts("  repair: #{result}") if @out && !result.attempts.empty?
        return nil if result.attempts.empty?

        # The re-run happened inside the loop (`rerun` assigns the ivar it was built around),
        # so what this returns is the *latest* reading of the stage, green or not.
        before_the_move ? @baseline : @suite
      end

      def repair_stage(attempt)
        tail = attempt.output_tail.to_s
        unless attempt.changed.empty?
          tail = "#{tail}\nfiles changed by this attempt: #{attempt.changed.join(", ")}"
        end
        Record::Command.new(stage: Record::REPAIR, command: attempt.command, ran: attempt.ran,
          exit_code: attempt.exit_code, seconds: attempt.seconds, output_tail: tail)
      end

      # The application's own Gemfile, made installable where a machine may: the protocol
      # GitHub stopped speaking and the moves the service's digest documents. One stage,
      # because it is one action with one outcome, and the details travel in its tail —
      # the repairs' before-and-after lines and the decisions' reasons.
      #
      # A repository with no Gemfile at all still gets a stage, saying so: `planned`
      # requires a lockfile but not a Gemfile, and a preflight that silently did nothing
      # would leave an install failure to report it in a sentence about gems.
      # **A digest entry's condition is read against the rung's own floor and the rung itself.** This
      # stage runs before the machine is chosen — the choice *is* a `bundle install`, so the Gemfile has
      # to be installable first — so the honest interpreter to name here is the lowest one the move may
      # run on, which is the ladder's own statement of it (the lockfile's `RUBY VERSION` is the fallback
      # for a rung that states no floor). The release the move ends at is `@to`, which is what lets an
      # entry be scoped to a rung: measured, the digest's `devise ~> 3.0.0` is the line 4.0 and 4.1 need
      # and the wrong one at 4.2. With neither fact available a conditioned entry is a *note* rather
      # than a silent pass.
      def preflight_stage(stages, step)
        corpus = @corpus || Corpus.new(base: @api)
        @preflight = Preflight.new(root: @worktree.root, corpus: corpus,
          ruby: step["requires_ruby"] || @lockfile.locked_ruby, rails: rung_of(step))
        result = @preflight.run
        # **What the preflight could not do because the Gemfile and the pin did not agree yet.**
        # A rung-scoped entry — a declaration *or* a rewrite of a line the application already
        # declares — is applied by `declare_for_the_rung`, after the pin is rewritten and before
        # its resolve (`rewrite`).
        @deferred = result.deferred
        stages << Record::Command.new(
          stage: Record::PREFLIGHT, command: "preflight: #{result.summary}",
          ran: true, exit_code: 0, seconds: 0.0,
          output_tail: result.details.first(20).join("\n")
        )
        @out.puts("  preflight: #{result.summary}") if @out
        result
      rescue Preflight::NotAnApplication => e
        stages << Record::Command.new(stage: Record::PREFLIGHT, command: e.message,
          ran: false, exit_code: nil, seconds: 0.0, output_tail: e.message)
        @deferred = []
        Preflight::Result.new(repairs: [], decisions: [], notes: [e.message], deferred: [])
      end

      # **The rung this step executes, which is what a digest entry's condition names.** The
      # constructor's `@to` is where the *caller* wants to end up — a walk to the top of the
      # ladder asks for 8.1.0 at every rung — so evaluating `rails_at_least` against it would
      # apply an entry for the last release to the first rung. Only the rung knows its own
      # release, and that is the fact the digest states.
      def rung_of(step)
        step["to_version"] || @to
      end

      # The machine this step will run on, and the install it performed while deciding.
      #
      # Three paths, and the order is the decision:
      #
      # * a machine handed in (a test, or a caller that knows better) is used as it is;
      # * `native` — or no mode at all — means this process, and the floor is checked
      #   against this process's interpreter, because running a Rails 5 step on a 3.3
      #   interpreter "successfully" is not a thing that can happen and saying so before
      #   spending a bundle resolve is the cheaper answer;
      # * `rvm` and `docker` walk the era candidates in order and *probe by installing*: the
      #   interpreter that can install the application's own bundle is the one that can run
      #   its suite, and every candidate's attempt — the reason it was tried and the reason
      #   it was rejected — travels in the record. When none works, the record is
      #   `unverified`, because a machine that could not make the measurement established
      #   nothing about the move (`AGENTS.md`'s probe rule).
      def choose_machine(stages, step, preferred:)
        return [@machine, install_bundle(stages, @machine)] if @machine

        native = Machine::Native.new
        floor = step["requires_ruby"]
        unless docker_mode? || rvm_mode?
          if Interpreters.meets?(native.ruby_version, floor) == false
            return Record.unverified(
              repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
              from_version: @from, to_version: @to,
              why: "this step requires Ruby #{floor} and this interpreter is #{native.interpreter}: " \
                   "run it with `#{RUNTIME_ENV}=docker` so the step executes in an era container " \
                   "(`scripts/upgrader-images.sh build`), or on an interpreter that meets the floor"
            )
          end
          return [native, install_bundle(stages, native)]
        end

        candidates = candidates_for(step, preferred)
        if candidates.empty?
          return Record.unverified(
            repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
            from_version: @from, to_version: @to,
            why: "this step requires Ruby #{floor} and no interpreter in the matrix meets it " \
                 "(the matrix holds #{Interpreters.matrix.map(&:ruby).join(", ")}); add an era " \
                 "or move the step to a release this matrix can run",
            machine: no_interpreter_stamp(floor)
          )
        end

        attempts = []
        candidates.each do |entry|
          machine = build_machine(entry)
          unless machine.start!(stage: Record::INTERPRETER, stages: stages)
            attempts << "#{entry.name}: #{machine.unavailable}"
            machine.stop!
            next
          end

          install = install_bundle(stages, machine)
          return [machine, install] if install.ok?

          attempts << "#{entry.name}: #{Record.first_line(install.output_tail)}"
          machine.stop!
        end

        Record.unverified(
          repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
          from_version: @from, to_version: @to,
          stages: stages,
          why: "no interpreter installed the application's bundle — " \
               "#{attempts.empty? ? "the matrix is empty" : attempts.join("; ")}",
          machine: no_interpreter_stamp(floor)
        )
      end

      # The stamp a "no interpreter could be built for this step" verdict carries. It names
      # what was asked for rather than the process's own machine, so the verdict is re-opened
      # when the matrix grows an era that meets the floor — a refusal that would stand for
      # ever against a matrix somebody has since extended is the settled-work trap with the
      # sign flipped.
      def no_interpreter_stamp(floor)
        "no interpreter: requires ruby #{floor} (#{Interpreters.matrix.size} era(s) known)"
      end

      def candidates_for(step, preferred)
        Interpreters.candidates(
          requires_ruby: step["requires_ruby"],
          declared: @lockfile.declared_ruby,
          locked: @lockfile.locked_ruby,
          preferred: preferred
        )
      end

      def docker_mode?
        %w[docker container].include?(runtime_mode)
      end

      # **The application on the host, through the era's own Ruby.** `rvm` and `docker` both
      # walk the era candidates; what differs is where a candidate executes — the era's
      # container, or the host's rvm gemset — and what serves it (`Machine::Services` is a
      # sibling container with published ports, because the application on the host reaches
      # `localhost` and a `database.yml` from 2013 says exactly that).
      def rvm_mode?
        %w[rvm host].include?(runtime_mode)
      end

      def runtime_mode
        mode = @runtime_mode.nil? ? ENV[RUNTIME_ENV] : @runtime_mode
        mode.to_s.strip.downcase
      end

      # The services a host-run step talks to, owned by the *walk* rather than by the step: a
      # container per step — and per interpreter candidate — is the cost this exists to remove.
      # Built lazily, so a docker-mode step, whose services live inside its own container,
      # never creates one.
      def services
        @services ||= Machine::Services.new(home: @home, run_id: run_id, out: @out)
      end

      def build_machine(entry)
        return @machine_factory.call(entry) if @machine_factory
        return Machine::Host.new(entry: entry, home: @home, out: @out, services: services) if rvm_mode?

        Machine::Container.new(entry: entry, home: @home, out: @out, run_id: run_id)
      end

      # The application's own bundle on the unmodified checkout, recorded like every other
      # command. `bundle install` and not `bundle update`: this is the environment the
      # baseline needs, and resolving a *new* Rails is the pin stage's business. It is also
      # the interpreter probe (`choose_machine`), which is why it takes the machine rather
      # than defaulting to the one the step settled on.
      def install_bundle(stages, machine = @machine)
        drop_unrunnable_bundler(machine, stages)
        @out.puts("  install: bundle install#{machine.respond_to?(:era) && machine.era ? " (ruby #{machine.era})" : ""}") if @out
        stage = command(Record::BUNDLE, %w[bundle install], chdir: @worktree.root,
          env: @worktree.bundle_env(machine: machine), machine: machine, excerpt_bytes: Shell::RESOLVER_BYTES)
        stages << stage
        if (version = missing_bundler(stage))
          stages << command(Record::BUNDLE,
            ["gem", "install", "--user-install", "bundler", "-v", version, "--no-document"],
            chdir: @worktree.root, env: @worktree.bundle_env(machine: machine), machine: machine,
            excerpt_bytes: Shell::RESOLVER_BYTES)
          stage = command(Record::BUNDLE, %w[bundle install], chdir: @worktree.root,
            env: @worktree.bundle_env(machine: machine), machine: machine)
          stages << stage
        end
        return stage if stage.ok?

        # **A native extension that will not build needs the gem to *move*, and `--conservative` is
        # exactly what stops it.** Measured at the 7.2 rung on the 3.2 era: `bundle update rmagick
        # nio4r --conservative` resolved `rmagick 4.3.0 (was 2.16.0)` and then *installed nio4r 2.3.1
        # again* — the flag keeps every version the lock holds unless a dependency forces otherwise, and
        # nothing forces a *transitive* gem. The installer names it (`An error occurred while installing
        # nio4r (2.3.1), and Bundler cannot continue. In Gemfile: rails … depends on actioncable …`), and
        # a plain update of that one gem is measured to work: `Using nio4r 2.7.5 (was 2.3.1)`.
        #
        # So the named gem is updated on its own, without the flag, and the conservative update of the
        # gems this tool's own repairs moved still follows when there is no such gem — a build failure is
        # a fact about a version, and a repaired line is a fact about the application's Gemfile.
        # **A build failure is a chain, and each round names the next link.** Measured at the 7.2 rung:
        # the first install died on `nio4r 2.3.1`, the update that named it (with `msgpack` and
        # `ruby-prof`, which the output was also building) resolved all three — `nio4r 2.7.5`,
        # `msgpack 1.8.5`, `ruby-prof 2.0.5` — and then died on `bootsnap 1.4.5`, which the *same*
        # output had announced. **The update is itself an install**, so a round that fails still names
        # the next link; the loop continues while it names a gem it has not tried, and the bound is
        # there because a lock can name a gem whose newest release still will not build — a walk that
        # never ended would be worse than one that stopped.
        tried = []
        BUNDLE_REPAIR_ROUNDS.times do
          broken = broken_extensions(stage) - tried
          break if broken.empty?

          tried += broken
          stage = command(Record::BUNDLE, ["bundle", "update", *broken], chdir: @worktree.root,
            env: @worktree.bundle_env(machine: machine), machine: machine,
            excerpt_bytes: Shell::RESOLVER_BYTES)
          stages << stage
          break if stage.ok?
        end

        return stage if stage.ok?
        return stage if moved_gems.empty?

        conservative_update(stages, moved_gems, stage: Record::BUNDLE, machine: machine)
      end

      # **Every gem the installer was building a native extension for, because it builds them in
      # parallel and names only one of them.** Measured at the 7.2 rung: `bundle update nio4r` fixed
      # `nio4r` (`Using nio4r 2.7.5 (was 2.3.1)`) and the very same attempt died on `ruby-prof 0.13.0`,
      # which the output had already announced as `Installing ruby-prof 0.13.0 with native extensions`.
      # Moving them one at a time converges, but it converges at one *install* per gem, and the output
      # says which ones are in flight — so they all move at once.
      #
      # A name the lock does not hold is not one this can move, and an empty list is "the failure was
      # something else".
      def broken_extensions(stage)
        text = stage.output_tail.to_s
        named = text.scan(/^Installing ([a-zA-Z0-9_-]+) \S+ with native extensions/).flatten
        named += text.scan(/An error occurred while installing ([a-zA-Z0-9_-]+) \(/).flatten
        named.uniq.select { |name| @lockfile.specs.key?(name) }
      end

      # **A lock whose `BUNDLED WITH` names a bundler the era cannot run has to lose that trailer, and
      # the era is what says so.** `BundlerTrailer` carries the measurement; this is the question and
      # the edit. The question is `bundle --version` in the era's own container — one cheap command,
      # and the only honest way to ask whether a bundler runs on an interpreter — and the edit is the
      # lock, which this tool already moves (`rewrite_pin`, `drop_leaked_dependencies`). The era's
      # bundler then reads the lock and writes its own version back on the install that follows.
      #
      # **The probe's own output is kept when it refuses.** A stage that asked a question and got "no"
      # is the evidence for the edit beside it, and a record that dropped the trailer without it would
      # read as a lock nobody explained.
      def drop_unrunnable_bundler(machine, stages)
        path = File.join(@worktree.root, "Gemfile.lock")
        return unless File.file?(path)

        before = File.binread(path)
        after = BundlerTrailer.drop(before)
        return if after.nil?

        probe = command(Record::BUNDLE, %w[bundle --version], chdir: @worktree.root,
          env: @worktree.bundle_env(machine: machine), machine: machine)
        return if probe.ok?

        stages << probe
        File.binwrite(path, after)
        @applied << Applier::Applied.new(path: "Gemfile.lock", line: nil,
          text: "BUNDLED WITH\n   #{BundlerTrailer.version(before)}",
          after: "the era's own bundler, which writes its version back on the install",
          subject: "BUNDLED WITH", origin: nil,
          note: "the lock names bundler #{BundlerTrailer.version(before)}, and RubyGems activates the " \
                "version a lock names — so on an interpreter that cannot run it, no install happens " \
                "at all: measured at the 7.2 rung, `bundle install` exits 1 with " \
                "`undefined method `untaint' for an instance of Pathname` from the 1.17.3 the era had " \
                "just installed. The trailer is dropped so the era's own bundler reads the lock, and " \
                "the install writes its version back")
      end

      # **The bundler the lock names, which an era may not ship.** RubyGems activates the version in
      # `Gemfile.lock`'s `BUNDLED WITH`, so an era whose image pins a newer bundler cannot install the
      # application *at all* — and the message says so in the imperative: measured at the 6.0 rung on the
      # 2.7 era, `bundle install` answered `Could not find 'bundler' (1.17.3) required by your
      # Gemfile.lock. … To install the missing version, run gem install bundler:1.17.3`, while the same
      # tree installs on 2.5 whose image's *default* bundler is 1.17.3. **The lock is the application's
      # own statement about its toolchain**, so this installs the version it names rather than rewriting
      # the lock — into the walker's own home (`--user-install`), because the container runs as the
      # walker's uid and not as root: measured, that install makes the same `bundle install` succeed and
      # resolve the Gemfile's own line. A version that cannot *run* on the era is a different fact and a
      # different rung's problem (bundler 1.17.3 calls `Pathname#untaint`, which Ruby 3.2 removed), and
      # the retry it produces fails loudly rather than silently.
      def missing_bundler(stage)
        return nil if stage.ok?

        stage.output_tail.to_s[/Could not find 'bundler' \(([0-9][^)]*)\)/, 1]
      end

      # **A digest move that changes a *requirement* has to re-resolve the lock, and the
      # snapshot is what says so.** `bundle install` is right for the environment the baseline
      # needs — it adds what the Gemfile gained and leaves the rest where the move found it —
      # but a preflight move can rewrite a line into a *different line of that gem's own
      # releases*, and then the lock's pins are what bundler refuses. Measured on the
      # lighthouse's `rspec-rails ~> 2.14.0` against a snapshot holding `rspec-core (= 2.13.1)`:
      # `bundle install` and `bundle update rspec-rails --conservative` both answer "could not
      # find compatible versions for gem rspec-mocks … `rspec (~> 2.13)` was resolved to
      # 2.13.0 … `rspec-rails (~> 2.14.0)` was resolved to 2.14.2", because `--conservative`
      # keeps the *meta*-gem where the lock has it and the meta-gem drags its siblings back.
      # Naming the whole line resolves it, and the retry is the pin's own mechanism — a
      # conservative update widened by the gems bundler itself names — because that is the one
      # that does not rebuild the snapshot from scratch (the unconstrained resolve that moved
      # rake).
      def moved_gems
        @applied.map { |edit| edit.subject.to_s }.uniq & @lockfile.specs.keys
      end

      # A conservative update of `gems`, widened by what bundler names as stuck, and bounded.
      # The resolver knows this application's requirement graph, so the next round is read out
      # of its message rather than guessed — which is why the pin and the bundle's fallback
      # share it rather than each keeping their own idea of what usually moves together.
      def conservative_update(stages, gems, stage:, machine: nil)
        gems = gems.dup
        PIN_ROUNDS.times do
          attempt = command(stage, ["bundle", "update", *gems, "--conservative"],
            chdir: @worktree.root, env: @worktree.bundle_env(machine: machine || @machine), machine: machine,
            excerpt_bytes: Shell::RESOLVER_BYTES)
          stages << attempt
          return attempt if attempt.ok?

          named = stuck_gems(attempt.output_tail) - gems
          return attempt if named.empty?

          gems += named
        end
        stages.last
      end

      # Nothing ran, and the sentence is why: the answer to "why is the baseline red" a
      # reader needs is the bundle's own output, not a verdict about Rails.
      def install_record(install, stages)
        Record.unverified(
          repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
          from_version: @from, to_version: @to, stages: stages,
          machine: @machine&.stamp, era: @machine.respond_to?(:era) ? @machine.era : nil,
          why: "the application's bundle could not be installed (`bundle install` " \
               "#{install.ran ? "exited #{install.exit_code}" : 'did not run'}), so no " \
               "baseline could be taken and nothing is established about this step: " \
               "#{Record.first_line(install.output_tail)}"
        )
      end

      # The services the application's suite expects, started inside the step's container.
      # The script is the image's (`images/services.sh`): it reads the application's own
      # `database.yml` for the adapter and the usernames, starts PostgreSQL and Redis on
      # localhost, and reports what it started. A native machine has no services stage at
      # all — the host's own databases are the caller's business, and starting one on
      # somebody's laptop because they ran a step is not this tool's to do.
      def services_stage(stages)
        return nil unless @machine.services?

        stages << command(Record::SERVICES, ["agents-fyi-services"], chdir: @worktree.root)
        stages.last
      end

      # **One default at a time, each judged by the application's own suite.**
      #
      # `app:update` writes `config/initializers/new_framework_defaults_<version>.rb` commented out
      # on purpose — the guide's advice is to turn the defaults on one by one and read what each
      # does. A walker can do better than reading: enable one, run the suite, keep it if it is green
      # and put it back if it is not. What a toggle *does* travels in the record beside its verdict,
      # because the file's own comment above it is Rails' sentence about the change.
      #
      # The guide's last step is taken only when every toggle passed: the file and the
      # `config.load_defaults` line say the same thing, and the line is the one that survives. Both
      # files are saved first, so a red run there is reverted exactly rather than approximately.
      def step_defaults(stages, step)
        budget = @env[DEFAULTS_ENV].to_s.to_i
        return nil unless budget.positive?
        # The move's own measurement comes first, and this pass is about the defaults rather than
        # about the move: a suite that was already red is not a verdict on a toggle.
        return nil unless @suite&.ok?

        path = Defaults.file_in(@worktree.root)
        unless path
          stages << Record::Command.new(stage: Record::DEFAULTS, command: "defaults: nothing to step",
            ran: true, exit_code: 0, seconds: 0.0,
            output_tail: "no config/initializers/new_framework_defaults_*.rb in this application")
          return nil
        end

        defaults = Defaults.new(path: path, root: @worktree.root)
        all = defaults.toggles
        kept = []
        reverted = []
        all.first(budget).each do |toggle|
          defaults.enable(toggle)
          stage = run_suite(stages, Record::DEFAULTS)
          stage.output_tail = "#{stage.output_tail}\nnew default: #{toggle} — " \
                              "#{stage.ok? ? "kept" : "reverted"}"
          if stage.ok?
            kept << toggle
          else
            defaults.disable(toggle)
            reverted << toggle
          end
        end

        if reverted.empty? && all.any? && kept.size == all.size
          # One run, after the edits, and not one before them: the suite that matters is the one
          # that sees the state which survives (`finish_defaults`).
          finish_defaults(stages, defaults, step, path)
        elsif all.size > kept.size
          stages << Record::Command.new(stage: Record::DEFAULTS,
            command: "defaults: #{all.size - kept.size} toggle(s) left",
            ran: true, exit_code: 0, seconds: 0.0,
            output_tail: "#{kept.size} of #{all.size} new default(s) are on; the rest stay in " \
                         "#{File.basename(path)} with their own comments — a default this " \
                         "application cannot take is a decision, not a silent flip")
        end
        [kept, reverted]
      end

      # The last step of the guide, with the revert kept exact: both files are read before anything
      # is written, and a suite that goes red puts them back byte for byte. The file is *not* dropped
      # until the line is in place and the suite has run, because the file is what a reviewer needs if
      # it fails.
      def finish_defaults(stages, defaults, step, path)
        application = File.join(@worktree.root, "config", "application.rb")
        before_file = File.binread(path)
        before_app = File.file?(application) ? File.binread(application) : nil
        line = defaults.load_defaults!(step["to_version"])
        defaults.drop!
        stage = run_suite(stages, Record::DEFAULTS)
        if line && stage.ok?
          stage.output_tail = "#{stage.output_tail}\n#{line} and #{File.basename(path)} dropped — " \
                              "every new default is on, and the suite is green with all of them"
        else
          File.binwrite(path, before_file)
          File.binwrite(application, before_app) if before_app
          stage.output_tail = "#{stage.output_tail}\n#{line ? "`#{line}` did not hold" : "the " \
                              "application's class line was not found"}: #{File.basename(path)} is " \
                              "back and every default it carries is on"
        end
        stages.last
      end

      # The gems that have to move with this rung.
      #
      # The scan above reads *Rails'* changes; this asks the service what the application's
      # own gems need, which is a different question with a different answer: `rspec-rails
      # 2.13.1` declares `railties ~> 3.1`, so a 4.1 rung cannot keep it, and no amount of
      # reading Rails' guide would say so. The service answers from facts its clients
      # recorded, and this client is the one that can close a gap: what a gem's index
      # declares is fetched here — the service has no route to an index — and recorded
      # through the operator-authenticated facts route.
      #
      # What the routing says is treated exactly as the digest's entries are: a move this tool can
      # rewrite is rewritten and recorded, and everything else is a decision. **A `replace`/`remove`
      # the preflight already made is not made twice** (`already_applied?`, consulted by both the
      # `move` and the `replace` branch — a facts-derived `move` for a line the digest had just
      # written was the hole the `move` branch left), and one the preflight left as a *decision* is
      # made here: this pass runs after the baseline, at the rung where the move belongs.
      def gem_moves(stages, step)
        path = File.join(@worktree.root, "Gemfile.lock")
        return nil unless File.file?(path)

        corpus = @corpus || Corpus.new(base: @api)
        ruby = @machine.ruby_version
        rails = step["to_version"]
        route = corpus.route(ruby: ruby, rails: rails, lockfile: lockfile_text)
        route = research(corpus, route, ruby: ruby, rails: rails, stages: stages) if
          route.dig("counts", "unknown").to_i.positive?

        applied = []
        companions = []
        route.fetch("gems", []).each do |gem|
          case gem["verdict"]
          when "move"
            # **A line the preflight already wrote is not rewritten by the routing.** The digest is
            # keyed by gem *name* while the lock still pins the old release, so a route asked after
            # the preflight can answer `move` for a line that has already moved — and the `replace`
            # branch's guard did not cover this one, so a facts-derived `move` could overwrite the
            # line the digest had just written.
            next if already_applied?(gem)

            edit = apply_gem_change(gem, step)
            applied << edit
            companions.concat(apply_companions(gem))
          when "replace", "remove"
            # The preflight applies the digest's *mechanical* entries, and it must not apply
            # the others: an entry that can only move once Rails itself has moved is exactly
            # the one that blocks the pin when the move is finally made — measured on the
            # first real walk, where `simple_form 3.0.0.rc` (the git pin) requires
            # `actionpack < 4.1` and `bundle update rails` answered "could not find compatible
            # versions for actionpack". This pass runs after the baseline, at the rung where
            # the move is being made, so it is where that entry belongs.
            next withdraw_decision(gem) if already_applied?(gem)

            edit = apply_gem_change(gem, step)
            applied << edit
            companions.concat(apply_companions(gem))
          when "blocked", "unknown"
            # **A framework gem the pin itself moves is not a decision.** The routing reads recorded
            # facts, and for the framework's own components it has none for the target release — so
            # it answers `blocked` with "no recorded release of rails fits the target", while the pin
            # resolves exactly that, by naming those gems in its own `bundle update` (measured: six
            # such verdicts in the first real rung's sixteen decisions, all of them handled). The
            # pin's stage is the evidence; a decision that says the opposite of what happened is
            # worse than no decision.
            next if pin_gems.include?(gem["name"].to_s)

            @decisions << routing_decision(gem)
          end
        end
        applied = applied.compact

        stages << Record::Command.new(
          stage: Record::GEMS,
          command: "gems: #{route.dig("counts", "move")} move(s), " \
                   "#{route.dig("counts", "unknown")} unknown, #{applied.size} applied",
          ran: true, exit_code: 0, seconds: 0.0,
          output_tail: (companion_lines(companions) +
                        route.fetch("gems", []).reject { |gem| gem["verdict"] == "keep" }.map { |gem|
                          heading = "#{gem["verdict"].upcase} #{gem["name"]} #{gem["version"]}"
                          heading += " -> #{gem["to"]}" if gem["to"]
                          heading += " -> #{gem["replacement"]} #{gem["requirement"]}" if gem["replacement"]
                          "#{heading}: #{gem["reason"] || gem["note"]}"
                        } +
                        [route.fetch("next_step", "").to_s]).first(20).join("\n")
        )
        @out.puts("  gems: #{route.dig("counts", "move")} move(s), " \
                  "#{route.dig("counts", "unknown")} unknown — #{applied.size} applied") if @out
        @out.puts("  companions: #{companions.size} edit(s) — #{companions.map(&:subject).uniq.join(", ")}") if
          @out && !companions.empty?
        applied
      rescue Corpus::Unreachable, Corpus::Refused => e
        stages << Record::Command.new(stage: Record::GEMS, command: "gems: not routed",
          ran: false, exit_code: nil, seconds: 0.0,
          output_tail: "the routing read failed: #{e.message}")
        []
      end

      # A digest move the preflight already made. The digest is keyed by gem *name* while the
      # lockfile still pins the old release, so a route asked after the preflight still answers
      # `replace` for a line that no longer exists — and recording the same move twice would
      # read as two.
      def already_applied?(gem)
        @applied.any? { |edit| edit.subject.to_s == gem["name"].to_s }
      end

      # **One statement per gem, not two.** A digest entry the preflight may not apply is
      # recorded there as a decision ("this needs a person or a later rung"), and when this
      # rung *makes* that move the decision is withdrawn: the list a reviewer reads is "what
      # still needs a person", and a gem the routing has just moved is not that any more. The
      # applied edit carries the digest's own reason, so the record still says what moved and
      # why — in one place rather than in two that disagree about the tense.
      def withdraw_decision(gem)
        @decisions.reject! { |decision| decision.subject.to_s == gem["name"].to_s }
      end

      def routing_decision(gem, reason: nil)
        Record::Decision.new(
          path: "Gemfile.lock", line: nil,
          subject: "#{gem["name"]} #{gem["version"]}".strip,
          reason: (reason || gem["reason"] || gem["note"]).to_s,
          kind: gem["verdict"], replacement: gem["to"] || gem["replacement"],
          source: "GET /releases/route"
        )
      end

      # Which routing verdicts a reader has to act on. The digest's `replace`/`remove` are the
      # preflight's job when a machine may make them (`mechanical`), and a *decision* when it
      # may not — the first real application's simple_form entry is exactly that case: the
      # released line only fits once Rails itself has moved, so the preflight leaves it and
      # this records it. `blocked` and `unknown` are always decisions.
      def decision_worthy?(gem)
        return true if %w[blocked unknown].include?(gem["verdict"])

        %w[replace remove].include?(gem["verdict"]) && gem["mechanical"] != true
      end

      # One gem change, as a Gemfile rewrite: the same line-level caution the preflight takes,
      # and the same refusal to touch a declaration it cannot rewrite in full. A `move`'s target
      # is the release the routing named (`~> <to>`); a digest entry's is the requirement the
      # digest states — one rule, because they are the same edit with a different target.
      def apply_gem_change(gem, step)
        name = gem["name"].to_s
        replacement = gem["replacement"].to_s.empty? ? name : gem["replacement"].to_s
        requirement = gem["to"].to_s.empty? ? gem["requirement"].to_s : "~> #{gem["to"]}"
        found = declaration_line(name)
        if found.nil?
          # **A framework gem the pin moves is not a decision, however the routing spells it.**
          # The guard on the `blocked`/`unknown` branch reads a verdict, and the verdict for the
          # framework's own components is not stable: the first real rung routed them `blocked`
          # ("no recorded release of rails fits the target") and the walk after the digest grew
          # routed the same five `move`, so they fell through to here — five *located* decisions,
          # each naming a line of `Gemfile.lock` for a gem whose line the pin's own `bundle update`
          # names. The question this branch answers is whether a person has a line to edit, and for
          # a gem the pin moves the answer is no.
          return nil if pin_gems.include?(name)

          @decisions << routing_decision(gem, reason:
            "#{gem["reason"] || gem["note"]}; #{name} is not declared in the Gemfile, so " \
            "whatever pulls it in is the gem whose line moves")
          return nil
        end

        index, line = found
        after =
          if gem["verdict"] == "remove"
            ""
          elsif requirement.empty?
            "#{line[/\A\s*/]}gem \"#{replacement}\""
          else
            "#{line[/\A\s*/]}gem \"#{replacement}\", \"#{requirement}\""
          end
        # **A line that already reads the way the digest says is a move nobody owes.** The preflight
        # records a non-mechanical entry as a decision — it must not rewrite a line that can only move
        # once Rails has — and here, at the rung where the move is made, the line may already say it:
        # the 4.1 rung moved `simple_form` to `~> 3.1`, and the 5.0 rung's route then answers `replace`
        # for a line that is already there. Leaving the decision in place asks a person to make a move
        # the tree has made, and the residue is what a person works from. Measured on the lighthouse's
        # 5.0 record: `decide: simple_form` sat beside a Gemfile reading `gem "simple_form", "~> 3.1"`.
        if after == line
          withdraw_decision(gem)
          return nil
        end

        lines = File.binread(File.join(@worktree.root, "Gemfile")).split("\n", -1)
        unless lines[index] == line
          @decisions << routing_decision(gem, reason: "the declaration moved while this step " \
            "was running, so nothing was rewritten")
          return nil
        end

        if after.empty?
          lines.delete_at(index)
        else
          lines[index] = after
        end
        File.binwrite(File.join(@worktree.root, "Gemfile"), lines.join("\n"))
        edit = Preflight::Repair.new(path: "Gemfile", line: index + 1, text: line, after: after,
          subject: name,
          note: "#{gem["reason"] || gem["note"]} (routed for Rails #{step["to_version"]})")
        @applied << edit
        withdraw_decision(gem)
        edit
      end

      # **The edits a gem's own upgrade needs, keyed to the move's own line rather than to whether this
      # pass rewrote it.** A tree whose line already reads `~> 3.5.0` — a person moved it, or a run died
      # between the Gemfile write and the companion — must still get the edits, and the companion's own
      # guards make that idempotent (the insert asks the file, the rules ask the line). The edits go
      # through the same applier every other repair does — line-checked against what the file said when
      # it was read, refused rather than half-written, and carried into the patch — and a refusal is
      # recorded where every other refusal is, so an edit that could not be made is not a silent zero.
      def apply_companions(gem)
        requirement = gem["to"].to_s.empty? ? gem["requirement"].to_s : "~> #{gem["to"]}"
        companion = Companions.for(gem["name"], requirement)
        return [] if companion.nil?

        edits = Companions.edits(companion, root: @worktree.root)
        return [] if edits.empty?

        result = @applier.new(@worktree.root).apply(edits.map(&:to_h))
        @applied.concat(result.applied)
        @refused.concat(result.refused)
        result.applied
      end

      # What the gems stage's tail says about a companion's edits, in the same one-line-per-edit shape
      # the preflight's repairs use — a change no ladder documents has to be as readable as one that is.
      def companion_lines(edits)
        Array(edits).map do |edit|
          "companion #{edit.path}:#{edit.line} `#{edit.text.to_s.strip}` -> `#{edit.after.to_s.strip}` " \
            "(#{edit.subject})"
        end
      end

      # The declaration line for a gem, or nil — the preflight's own rule, asked of the same
      # file with the same pattern, so a move and a digest repair can never disagree about
      # which line a gem is on.
      def declaration_line(name)
        path = File.join(@worktree.root, "Gemfile")
        return nil unless File.file?(path)

        File.binread(path).split("\n", -1).each_with_index do |line, index|
          match = Preflight::DECLARATION.match(line)
          return [index, line] if match && match[2] == name
        end
        nil
      end

      # **Research is asked for as many times as the unknowns need, because one pass is a slice of
      # the lockfile.** `Research::MAX_GEMS` bounds a single pass, and the pins beyond it stay
      # unknown: measured at the 5.0 rung, the first pass recorded 60 of 104 and the gem the pin
      # then failed on — `sass-rails`, whose `railties < 5.0` is the very conflict — was in the other
      # 44, so the route answered `unknown` for the line the resolve needed moved and the rung failed
      # with a conflict the corpus could have answered. Each pass covers what the last one left, and
      # the loop stops when a pass records nothing new, so a gem the index will not answer is asked
      # about once rather than for ever. Both halves are reported: a pass that fetched ten documents
      # and closed nothing is a fact about the index, and a walk that hid it would look like a walk
      # that had nothing to fetch.
      RESEARCH_PASSES = 4

      def research(corpus, route, ruby:, rails:, stages:)
        pass = @research || Research.new(corpus: corpus, cache: File.join(@home, "index"), out: @out)
        RESEARCH_PASSES.times do
          unknown = route.fetch("gems", []).select { |gem| gem["verdict"] == "unknown" }
          break if unknown.empty?

          result = pass.run(unknown.map { |gem| [gem["name"], gem["version"]] })
          stages << Record::Command.new(
            stage: Record::RESEARCH, command: "research: #{result}",
            ran: true, exit_code: 0, seconds: 0.0, output_tail: result.details.first(20).join("\n")
          )
          break if result.researched.empty?

          route = corpus.route(ruby: ruby, rails: rails, lockfile: lockfile_text)
        end
        route
      rescue Corpus::Unreachable, Corpus::Refused => e
        stages << Record::Command.new(stage: Record::RESEARCH, command: "research: not run",
          ran: false, exit_code: nil, seconds: 0.0,
          output_tail: "the facts could not be recorded: #{e.message}")
        route
      end

      def lockfile_text = File.read(File.join(@worktree.root, "Gemfile.lock"), encoding: "utf-8")

      # The environment an application-level command runs under: the test environment a Rails
      # suite expects, the bundle this run installed, and the deployment's own values for the
      # application on top. One method, so a command cannot be added with two of the three.
      def application_env
        @tests.machine_test_env.merge(@worktree.bundle_env(machine: @machine)).merge(@suite_env)
      end

      # `KEY=VALUE` lines, `#` comments and blank lines ignored, and a missing file is an
      # empty environment rather than a failure — the operator named a path, and a path that
      # is not there says "nothing to add" rather than "refuse to walk".
      def read_env_file(path)
        return {} if path.to_s.empty?

        file = File.expand_path(path)
        unless File.file?(file)
          @out.puts("  suite env: #{file} is not a file, so no values were added") if @out
          return {}
        end

        values = {}
        File.read(file, encoding: "utf-8").each_line do |line|
          text = line.strip
          next if text.empty? || text.start_with?("#")

          key, value = text.split("=", 2)
          next if key.to_s.strip.empty? || value.nil?

          values[key.strip] = value.strip.sub(/\A(["'])(.*)\1\z/m, "\\2")
        end
        @out.puts("  suite env: #{values.size} value(s) from #{file}") if @out && !values.empty?
        values
      end

      # The application's test database, prepared the way it documents. Best-effort by
      # design: `Record.verdict` names a failed preparation beside a suite failure rather
      # than making one out of it, because a suite that manages its own schema is a normal
      # application and the stage is here for the ones that do not.
      def database_stage(stages)
        root = @worktree.root
        return nil unless File.file?(File.join(root, "config", "database.yml"))

        # **`rails db:create` arrived in Rails 5.0, and `bin/rails` arrived in 4.0** — so the
        # presence of a binstub says nothing about which spelling the application can run. The
        # first real walk's repository has both and runs Rails 4.0.0.rc1, where `bin/rails
        # db:create` answers "Command 'db:create' not recognized" and leaves the suite to fail
        # on a database that was never created. The version at hand is the application's own
        # (`Gemfile.lock`, read before the pin is rewritten) because that is the Rails that
        # would run the command.
        argv =
          if rails_five_or_newer?
            ["bin/rails", "db:create", "db:test:prepare"]
          elsif File.file?(File.join(root, "Rakefile"))
            ["bundle", "exec", "rake", "db:create", "db:test:prepare"]
          end
        unless argv
          stages << Record::Command.new(stage: Record::DATABASE,
            command: "no Rakefile and no bin/rails: nothing to prepare the database with",
            ran: false, exit_code: nil, seconds: 0.0, output_tail: "")
          return nil
        end

        @out.puts("  database: #{argv.join(" ")}") if @out
        stages << command(Record::DATABASE, argv, chdir: root, env: application_env)
        stages.last
      end

      # **`app:update` can write a migration, and the database the baseline prepared is then stale.**
      # Measured at the 6.0 rung: `app:update` adds
      # `db/migrate/*_add_foreign_key_constraint_to_active_storage_attachments_for_blob_id.rb` to an
      # application that has no ActiveStorage tables at all — the generated migration is guarded, so
      # it is a no-op, but it is a *migration* — and the application's own `spec_helper` calls
      # `ActiveRecord::Migration.check_pending!`, so the suite died before a single example ran:
      # "Migrations are pending. To resolve this issue, run: rails db:migrate RAILS_ENV=test".
      # `db:test:prepare` is not the command for it: that loads `db/schema.rb`, which only
      # `db:migrate` has brought up to date. So the second preparation is the one Rails' own message
      # names, it runs in the environment the first one did, and it runs **only when a migration
      # actually arrived** (`@adopted`, which is what `app:update` added and this tool kept) — a rung
      # that wrote no migration has nothing to re-prepare, and this touches the database the suite
      # reads.
      def migrate_after_update(stages)
        arrived = @adopted.grep(%r{\Adb/migrate/})
        return nil if arrived.empty?
        return nil unless File.file?(File.join(@worktree.root, "config", "database.yml"))

        argv = rails_five_or_newer? ? ["bin/rails", "db:migrate"] : ["bundle", "exec", "rake", "db:migrate"]
        @out.puts("  database: #{argv.join(" ")} (#{arrived.size} migration(s) from app:update)") if @out
        stage = command(Record::DATABASE, argv, chdir: @worktree.root, env: application_env)
        stage.output_tail = "#{arrived.join(", ")} arrived with app:update, so the database the " \
                            "baseline prepared is stale: #{stage.output_tail}"
        stages << stage
        stage
      end

      # The suite on the unmodified copy. Its *absence* is a fact about the application and is
      # recorded as one: `nil` here is what makes the verdict `unverified` rather than
      # `passed`, which is's fourth rule.
      def baseline(stages)
        @suite_plan = @tests.detect(@worktree.root)
        unless @suite_plan
          reason = @tests.respond_to?(:no_suite_reason) ? @tests.no_suite_reason(@worktree.root) : "no suite"
          stages << Record::Command.new(stage: Record::BASELINE, command: reason, ran: false,
            exit_code: nil, seconds: 0.0, output_tail: reason)
          return nil
        end
        @out.puts("  baseline: #{@suite_plan.command}") if @out
        run_suite(stages, Record::BASELINE)
      end

      def suite(stages)
        return nil unless @suite_plan

        run_suite(stages, Record::SUITE)
      end

      # Under the run's own bundle. `Tests.run` merges its `RAILS_ENV`/`RACK_ENV` in first
      # and this over it, so a Rails suite gets both and the gems it loads are the ones
      # `bundle install` put in this run's directory — the alternative is a suite that
      # silently runs against whatever the image happens to have. The `machine` is what
      # decides whether that directory is on this host or inside the step's container.
      def run_suite(stages, stage)
        result = @tests.run(@worktree.root, @suite_plan, timeout: @suite_timeout,
          env: application_env, machine: @machine)
        stages << Record::Command.new(stage: stage, command: @suite_plan.command, ran: result.ran,
          exit_code: result.exit_code, seconds: result.seconds,
          output_tail: result.output_tail)
        stages.last
      end

      # Ask the service which call sites this step needs, then apply the mechanical half. The
      # manual half is a decision for a person and travels in the record as one —'s fifth
      # rule: a refusal is an output.
      def apply(stages, step)
        files = source_files
        if files.empty?
          stages << Record::Command.new(stage: Record::APPLY, command: "no Ruby source found to scan",
            ran: false, exit_code: nil, seconds: 0.0,
            # **A bridge and a survey are skipped here too, and that is said rather than silent**: both
            # read the files the scan would have sent, so a repository with none gets neither. It is the
            # degenerate case — a Rails application has Ruby — but a stage that quietly did less than its
            # name says is the shape `AGENTS.md` keeps paying for.
            output_tail: "no bridge declared, no survey run and no rule's own file read: all three " \
                         "read what the scan would have sent")
          # The plan's half is still this step's half: a repository with no Ruby source
          # this tool reads has not thereby moved, and the changes no machine may make
          # are exactly the ones a person still has to.
          return [[], [], decisions_for(step, nil)]
        end

        corpus = @corpus || Corpus.new(base: @api)
        scan = corpus.scan(from: scan_from(step, corpus), to: step["to_version"], files: files)
        if @out
          @out.puts("  scan: #{scan["counts"].inspect} — #{files.size} file(s) sent")
          # The counts alone read as one thing and mean three: a window whose documented
          # changes are all patterns that match nothing, a window with *no* pattern at all
          # (the service returns before reading a line, so `lines` is 0 beside 35 files),
          # and a scan that found no call site in this application. The service already
          # writes that sentence for a caller, and this client is one — the alternative is
          # a log where "35 files, 0 lines" looks like a read that did nothing.
          found = scan["counts"].to_h.values_at("automatic", "manual").compact.sum(0)
          @out.puts("  scan: nothing to apply here — #{scan["next_step"]}") if found.zero? && scan["next_step"]
        end

        # **This tool's own rules, applied to the call sites the service located and stopped at.**
        # The service's contract is a statement about the ladder; a rule that edits code is this
        # tool's (`Rewrites`), and it goes through the same line-checked write as the service's own
        # edits — the scan's `text` is what the applier compares against, so a line that moved
        # between the read and the write is refused rather than half-rewritten. A change a rule
        # applies stops being a decision, because it is no longer one.
        manual = scan["manual"] || []
        # **Read once, and three things read it**: a rule's context, a survey, and a rule that finds its
        # own call sites in a file the scan never sends. The scan bounded which files *it* read; the rules
        # name their own, and the two maps are merged rather than kept apart so that "the file's lines"
        # means one thing everywhere.
        named = rule_sources
        tree = file_lines(files).merge(named)
        rules = Rewrites.apply(manual, files: tree, sources: named, changes: step["changes"] || [],
          rung: step["to_version"])
        inert = Rewrites.inert(step["changes"] || [])
        # **What the surveys found, before the decisions are built** — the evidence travels *in* the
        # decision rather than beside it, because a residue read one line at a time is what a person
        # actually works from.
        evidence = Rewrites.survey(step["changes"] || [], tree: tree, located: manual)
        # A rule that *knows* the change and would not touch this line is the most specific thing
        # anything downstream can be told, so it is kept rather than counted: the repair agent's
        # brief carries it (`Repair#prompt_for`).
        @unapplied_rules = rules.left
        result = @applier.new(@worktree.root).apply((scan["edits"] || []) + rules.edits)
        created = write_scaffolds(rules.scaffolds)
        created += write_scaffolds(Zeitwerk.spellings(root: @worktree.root))
        # **The changes whose fix is a gem**, applied to the call sites the scan located: the call
        # sites need no edit, so what handles them is a declaration in the application's Gemfile.
        declared, bridged = declare_bridges(
          Rewrites.bridges(manual, changes: step["changes"] || [], tree: bridge_evidence)
        )
        handled = rules.applied + bridged + bridges_the_gemfile_answers
        decisions = decisions_for(step, scan, evidence: evidence).reject do |decision|
          handled.include?(decision.subject.to_s) ||
            already_reads_the_new_way?(decision, tree) ||
            the_changes_own_scaffold?(decision)
        end
        # **A change the application has already made is not a decision.** A rule whose own idempotence guard
        # matches a line has *read* it and found nothing to do — an answer about the application rather than a
        # refusal — and leaving the decision in place asks a person to look at a line that already reads the
        # new way. The first real walk is what made this worth separating: its three located entries were
        # `:confirm option on link_to` lines that already carry `data: { confirm: … }`, and the residue said
        # three decisions were owed. They are named in the tail rather than dropped, because a change that
        # disappears without a sentence is the empty answer this pipeline keeps paying for.
        decisions.reject! { |decision| rules.satisfied.include?(decision.subject.to_s) }
        stages << Record::Command.new(
          stage: Record::APPLY,
          command: "apply #{scan["edits"].to_a.size} edit(s) to #{files.size} scanned file(s)",
          ran: true, exit_code: 0, seconds: 0.0,
          output_tail: apply_summary(result, decisions, rules, inert, created, declared)
        )
        [result.applied + declared, result.refused, decisions]
      end

      # **The scan looks below this rung, and a real walk is why.** An application can declare a release
      # and never have made the work that release's own rung asked for: the lighthouse says 4.0.0.rc1 and
      # still calls `find(:all, conditions: ...)`, a change the ladder documents for the rung that *arrives
      # at* 4.0. It kept working until 4.1 because Rails 4.0 depended on `activerecord-deprecated_finders`,
      # and at 4.1 that gem is gone — so the suite failed on a change no step had been asked about, and the
      # residue said nothing, because the change is not in this rung's plan.
      #
      # So the window starts at the ladder's own `earliest` rather than at the application's version. The
      # rules are what make that safe: each one's pattern matches the *old* form, so a rule for a rung the
      # application has already crossed finds nothing to rewrite, and one it missed finds exactly the line
      # its note describes. What the wider window must not do is flood the residue, and it does not: an
      # entry carries the rung that named it, so a decision for an earlier rung says so.
      def scan_from(step, corpus)
        ladder = (@ladder ||= corpus.ladder)
        earliest = ladder["earliest"].to_s
        return step["from_version"] if earliest.empty?

        earliest
      rescue Corpus::Refused => e
        # A ladder this client cannot read is not a reason to refuse the move: the rung's own window is
        # what the step was asked about, and it is what a service that answers the scan but not the ladder
        # can still be asked.
        @out.puts("  scan: the ladder could not be read (#{e.message}), so this rung's window was used") if @out
        step["from_version"]
      end

      # What the apply stage's tail says: the counts, then what this tool's own rules did, then the
      # rules that name no change in this rung. The last two are evidence rather than decoration —
      # a rule that applied nothing and a rule whose change has left the ladder look identical from
      # the outside, which is the shape `AGENTS.md` keeps paying for.
      def apply_summary(result, decisions, rules, inert, created = [], declared = [])
        parts = ["applied #{result.applied.size}, refused #{result.refused.size}, " \
                 "#{decisions.size} change(s) need a decision"]
        parts << "#{rules.edits.size} by this tool's own rules (#{rules.applied.uniq.join(", ")})" if
          rules.edits.any?
        # **A line a rule's own guard recognised is named, not counted.** It is the difference between "this
        # application already reads the new way" and "nobody can read this line", and only the second is work.
        parts << "#{rules.satisfied.size} change(s) this application already has " \
                 "(#{rules.satisfied.uniq.join(", ")})" if rules.satisfied.any?
        # **A gem declared for a change whose fix is one**, named by the gem rather than the subject:
        # what a reviewer has to check is the Gemfile line, and whether it landed in the right group.
        parts << "#{declared.size} gem(s) declared for a change (#{declared.map { |edit| edit.subject }.uniq.join(", ")})" if
          declared.any?
        # **The files a rule's edit depends on**, named rather than counted: a reader of the patch
        # needs to know the diff is not the whole change (`ApplicationRecord` is in a file the patch
        # does not show).
        parts << "#{created.size} file(s) created for a rule (#{created.join(", ")})" if created.any?
        # **A rule's glob that matched more files than it read is named**, because a rule that read a slice
        # and found nothing looks exactly like a rule with nothing to find.
        parts << "a rule's file glob was truncated: #{@truncated_sources.join("; ")}" if
          @truncated_sources.to_a.any?
        parts << "#{inert.size} rule(s) name no change in this rung (#{inert.join(", ")})" if
          inert.any?
        unless rules.left.empty?
          parts << "#{rules.left.size} line(s) a rule knows and would not touch " \
                   "(#{rules.left.uniq.join(", ")})#{left_reasons(rules.left)}"
        end
        parts.join("; ")
      end

      # **A line a rule knows and will not touch is a *reason* before it is a count.** The count alone
      # reads as work left, and for `belongs_to` the reason is the opposite: the model already validates
      # the association, so the new default agrees with it and there is nothing to write. That sentence
      # is the `PARTIAL` beside the rule — and a `left` line produces no *decision*, so without this the
      # record would be the one place the explanation cannot be found.
      def left_reasons(subjects)
        sentences = subjects.uniq.filter_map { |subject| Rewrites.gap_for(subject) }
        sentences.empty? ? "" : " — #{sentences.join("; ")}"
      end

      # **The files a rule's edit depends on, written after the edits and before the suite.** A model
      # cannot inherit from `ApplicationRecord` before that class exists, so the rule that renames the
      # superclass carries the file that defines it. This is a write outside the applier, and it is the
      # applier's *contract* that says why: an edit is checked against the line the scan read, and a
      # file that does not exist has no line to check — the same reason `Defaults` writes the
      # `new_framework_defaults` file it then steps through. The path is this tool's own constant
      # rather than the application's or the service's, and a file that is already there is left alone:
      # an application that has already made this move has its own, with whatever it has added to it.
      # **Rails 7.0 deleted classic mode, so Zeitwerk owns the application's autoload paths and an
      # acronym is a spelling it cannot guess.** The scan is `Zeitwerk.spellings`, whose own file carries
      # the measurement; this is where its result is written, beside the rule scaffolds, because both are
      # files a change depends on rather than lines of one.
      def write_scaffolds(scaffolds)
        root = @worktree.root
        Array(scaffolds).filter_map do |scaffold|
          path = File.join(root, scaffold.path)
          next if File.exist?(path)

          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, scaffold.content)
          scaffold.path
        end
      end

      # **A bridge: the change's fix is a gem, so its call sites are handled by a declaration.** The
      # declaration goes into the block that names the gem's group, or at the end of the file when the
      # gem belongs everywhere. A gem already declared is left alone and still counts as handled — the
      # change is satisfied whether this step declared it or the application did — and a gem whose
      # group has no block is *not* handled, which is the one refusal here: appending a test-only gem
      # to the end of the file installs it in production, and that is a fact about the deployment
      # rather than about the line.
      #
      # The record's shape is a line and what it became, so a new declaration travels as the line the
      # insert is anchored to and that line with the declaration beside it. A `Repair` with an empty
      # `text` would read as "the line was empty" rather than "the file did not have it".
      def declare_bridges(bridges)
        path = working_copy_gemfile
        return [[], []] unless File.file?(path)

        lines = File.binread(path).split("\n", -1)
        repairs = []
        handled = []
        bridges.each do |bridge|
          bridge.gems.each do |gem|
            declared = declaration_line(gem)
            wanted = bridge.requirement || bridge.floor
            # **A floor is about a gem the application already has.** "Spring 3.0.0 or newer" is not an
            # instruction to install Spring, and an application without it is not asked to.
            if declared.nil? && bridge.floor
              handled << bridge.subject
              next
            end

            if declared
              # A bridge with no requirement is whole when the gem is declared — the change is satisfied
              # whether this step declared it or the application did. A requirement's work *is* that
              # declaration, and it only has anywhere to go when the line asks for no version at all:
              # `gem "spring"` becomes `gem "spring", ">= 3.0.0"`, while a line that already names one is
              # a person's call and stays a decision rather than being counted as handled.
              if wanted.nil?
                handled << bridge.subject
              elsif declaration_requirement(declared.last).nil?
                index, line = declared
                lines[index] = "#{line.to_s.sub(/\s*\z/, "")}, #{wanted.inspect}\n"
                repairs << Preflight::Repair.new(path: "Gemfile", line: index + 1, text: line,
                  after: lines[index], subject: bridge.subject, note: bridge.why)
                handled << bridge.subject
              end
              next
            end

            at = bridge.group ? group_end(lines, bridge.group) : [last_line(lines), ""]
            next if at.nil?

            index, indent = at
            line = lines[index].to_s
            # **A bridge that inserts a line writes the requirement it declares with onto it.** The
            # requirement only ever reached a line the application had already declared, so a bridge whose
            # whole work is a version inserted an unversioned line and the resolver took the newest
            # release: measured at the 5.2 rung, where `gem 'bootsnap'` resolved to 1.10.3, whose own
            # `ruby (>= 2.3.0)` cannot sit on the 2.2 era, and the pin failed on it.
            inserted = "#{indent}gem '#{gem}'#{bridge.requirement ? ", #{bridge.requirement.inspect}" : ''}\n"
            # **A declaration at the end of the file needs a separator and one before a block does
            # not**: the lines came from `split("\n", -1)`, so they carry no terminator — appending
            # `gem 'x'` to the last line produced `gem "rails", "4.2.11"gem 'x'`, which is a Gemfile
            # bundler refuses. Inserting *before* a line is fine, because `inserted` ends in its own
            # newline.
            lines[index] = bridge.group ? "#{inserted}#{line}" : "#{line}\n#{inserted}"
            repairs << Preflight::Repair.new(path: "Gemfile", line: index + 1, text: line,
              after: lines[index], subject: bridge.subject, note: bridge.why)
            handled << bridge.subject
          end
        end
        File.binwrite(path, lines.join("\n")) if repairs.any?
        [repairs, handled.uniq]
      end

      # **A bridge the working copy's Gemfile already carries answers its change, whatever rung the scan
      # found the call site at.** `declare_bridges` runs only for the changes *this step* carries,
      # because declaring a gem is an edit made for this rung's move; but the scan starts at the
      # ladder's `earliest`, so an earlier rung's call sites arrive as decisions — and a change whose
      # whole fix is a name the Gemfile holds has been answered. Nothing about the line can say so: the
      # call site is *supposed* to still read `assigns`. Measured at the 5.1 rung, where the 5.0 rung's
      # `rails-controller-testing` bridge was already in the test group and the scan's 19
      # `assigns`/`assert_template` call sites came back as located decisions whose reason said they
      # were "still in its old form" — 19 decisions that asked a person to do work already done.
      #
      # A floor is excluded, and that is `declare_bridges`' own rule read from the other side: a floor's
      # work is the *version* on the line, so a declared `gem "spring"` is not answered by its name and
      # stays a decision, which is exactly what that method does with it.
      def bridges_the_gemfile_answers
        declared = declared_gems
        Rewrites::BRIDGES.select do |bridge|
          bridge.floor.nil? && bridge.gems.all? { |gem| declared.include?(gem) }
        end.map(&:subject)
      end

      # The gem names the working copy's Gemfile declares.
      def declared_gems
        path = working_copy_gemfile
        return [] unless File.file?(path)

        gem_names(File.binread(path))
      end

      # Every gem name a `gem` line declares. Read rather than parsed, for the same reason
      # `declaration_requirement` is: the shape of a line is the application's, and the only question
      # here is which names the file holds.
      def gem_names(text)
        text.to_s.scan(/^\s*gem\s+["']([^"']+)["']/).flatten
      end

      # The Gemfile this step declares into.
      def working_copy_gemfile = File.join(@worktree.root, "Gemfile")

      # **What a declaration asks for beyond the name**, or nil. `gem "spring"` asks for nothing and
      # `gem "spring", "~> 2.0"` asks for a version; read rather than parsed, because the shape of the
      # line is the Gemfile's and the only question here is whether a floor has anywhere to go.
      def declaration_requirement(line)
        rest = line.to_s[/\A\s*gem\s+["'][^"']+["'](.*)\z/, 1].to_s.strip
        rest.empty? ? nil : rest
      end

      # The line that closes the block declaring this group, and the indentation its body uses — which
      # is where a gem for that group goes. **The block whose list is exactly this group first**, then
      # one that also names others: a block declared for the group alone is where a gem for that group
      # belongs, and a block that also names others still loads in the right environment, so it is the
      # fallback rather than a refusal. The nesting is counted over *masked* lines, so a `do` inside a
      # string or a comment cannot be mistaken for a block.
      def group_end(lines, group)
        blocks = []
        lines.each_with_index do |line, index|
          found = Rewrites.mask(line).match(/\A\s*group\s+(?<names>.+?)\s+do\b/)
          next if found.nil?

          blocks << [index, found[:names].scan(/:(\w+)/).flatten]
        end
        chosen = blocks.find { |_, names| names == [group.to_s] } ||
          blocks.find { |_, names| names.include?(group.to_s) }
        return nil if chosen.nil?

        start = chosen.first
        depth = 0
        closing = nil
        (start...lines.size).each do |index|
          masked = Rewrites.mask(lines[index])
          depth += masked.scan(/\bdo\b|\bif\b|\bunless\b|\bwhile\b|\bcase\b/).size
          depth -= masked.scan(/\bend\b/).size
          if index > start && depth.zero?
            closing = index
            break
          end
        end
        return nil if closing.nil?

        [closing, body_indent(lines, start, closing)]
      end

      # **The block's own indentation, not the `end`'s.** A Gemfile puts `end` at the margin and its
      # declarations two spaces in, so copying the closing line's indent wrote an unindented
      # declaration into the middle of a block — which is a diff a reviewer has to fix rather than
      # read. A block with no body yet gets one level more than its `end`.
      def body_indent(lines, start, closing)
        body = lines[(start + 1)...closing].to_a.find { |line| !line.strip.empty? }
        return body[/\A\s*/].to_s if body

        "#{lines[closing][/\A\s*/]}  "
      end

      # The last line with anything on it — where a gem with no group goes. A Gemfile that ends inside
      # a block is not a Gemfile (it would not parse), so the last real line is either the `end` of one
      # or a declaration at the top level.
      def last_line(lines)
        lines.rindex { |line| !line.strip.empty? } || 0
      end

      # **The evidence a plan-driven bridge needs**: the files this tool's own bridge table names, read
      # from the working copy. Read here rather than up front because the whole point of `bootsnap`'s
      # evidence is that `app:update` is what writes it — and only the named paths, because a tool that
      # read the tree would be reading everything.
      def bridge_evidence
        Rewrites::BRIDGES.filter_map { |bridge| bridge.evidence if bridge.evidence.is_a?(Rewrites::Evidence) }
          .to_h do |evidence|
          path = File.join(@worktree.root, evidence.path)
          [evidence.path, File.file?(path) ? File.read(path, encoding: "utf-8") : ""]
        end
      end

      # **The files this tool's own rules name for themselves**, read from the working copy — the same
      # shape as `bridge_evidence`, and bounded (`Rewrites::SOURCE_LIMIT`). The bound is stated rather than
      # silent: a glob a rule writes matches a handful of files in any application, and one that matched
      # thousands would be a rule reading a tree rather than a file.
      def rule_sources
        @truncated_sources = []
        Rewrites::RULES.filter_map(&:file).uniq.flat_map do |glob|
          matched = Dir.glob(glob, base: @worktree.root).sort
          # **A truncated glob is said rather than silent.** `SOURCE_LIMIT` bounds how many files one rule's
          # pattern is tried against, and a rule whose glob is broader than the limit would otherwise read a
          # slice and report "no call sites here" — which is the empty answer this pipeline keeps paying for,
          # in a rule instead of a scan. The bound is not raised here: it is a rule reading a tree rather than
          # a file at that point, and the honest thing is to say so and let the rule be narrowed.
          if matched.size > Rewrites::SOURCE_LIMIT
            @truncated_sources << "#{glob} (#{matched.size} file(s), first #{Rewrites::SOURCE_LIMIT} read)"
          end
          matched.first(Rewrites::SOURCE_LIMIT).filter_map do |path|
            full = File.join(@worktree.root, path)
            [path, File.file?(full) ? File.read(full, encoding: "utf-8").lines.map(&:chomp) : nil]
          end
        end.to_h
      end

      # The file contents the scan sent, by path and line — what a rule that reads more than its own
      # line gets (`Rewrites::Rule#context`). Built from the same read the scan used, so a rule and the
      # service are looking at the same bytes.
      def file_lines(files)
        files.to_h { |path, text| [path, text.to_s.lines.map(&:chomp)] }
      end

      # Every change this rung carries that no machine may make, located where the
      # application uses it when the scan found it there.
      #
      # Driven by the *plan's* list rather than by the scanner's findings, and that is a bug
      # found by driving a real step rather than by a test: the 7.1 -> 7.2 rung documents
      # `alias_attribute` as `automatic: false`, an application that never mentions it has no
      # call site to find, so the scan's `manual` list was empty and the record read "0
      # need(s) a decision" beside a plan naming one. The refusal list is half the product and
      # the coverage figure is measured from it, so an empty list that means "nothing was
      # found here" while reading as "nothing was carried" is the empty-answer trap with the
      # count raised. A change this application does not use today is still a change this step
      # carried.
      def decisions_for(step, scan, evidence: {})
        found = (scan && scan["manual"] || []).group_by { |entry| entry["subject"].to_s }
        carried = (step["changes"] || []).reject { |change| change["automatic"] }

        located = carried.map do |change|
          decision(change, found[change["subject"].to_s]&.first, evidence: evidence,
            rung: step["to_version"], from: step["from_version"])
        end
        # And a manual call site the plan does not name is a change nobody has written
        # into the ladder, which is the most useful thing a refusal can say. Dropping it
        # because the digest has no row for it would hide exactly that.
        #
        # **"The plan does not name it" and "nobody wrote it into the ladder" are two claims, and the wider
        # scan separates them**: an entry carries the rung that named it, so an earlier rung's change is
        # reported as exactly that rather than as a change the ladder is missing. The second claim is kept
        # for an entry with no rung at all.
        unplanned = found.keys - carried.map { |change| change["subject"].to_s }
        located + unplanned.flat_map do |subject|
          found[subject].map do |entry|
            decision(nil, entry, evidence: evidence, rung: step["to_version"], from: step["from_version"])
          end
        end
      end

      # One decision, from whichever side named the change — the plan when it did, the
      # scan's own entry otherwise. The reason joins both notes when they are two, in the
      # order a reader wants them: what the guide says the change is, then what this
      # application's line looks like.
      def decision(change, entry, evidence: {}, rung: nil, from: nil)
        subject = ((change && change["subject"]) || entry["subject"]).to_s
        # **The gap travels with the change, and that is the point of it.** A change no rule covers
        # is not a verdict about the application: it is a queue entry, and `Rewrites.gap_for` says
        # what would close it — so the next lighthouse (or the next agent) starts from what is
        # missing rather than from the same blank list. A permanent refusal is the settled-work trap
        # with the sign flipped (`Step#no_interpreter_stamp` is the same posture one layer down).
        gap = Rewrites.gap_for(subject)
        reason = [change && change["note"], entry && entry["note"]]
                 .compact.reject { |note| note.to_s.empty? }.uniq.join(" — ")
        reason = [reason, earlier_rung(entry, rung, from), survey_note(evidence[subject]),
                  gap && "not automated yet: #{gap}"]
                 .compact.reject(&:empty?).join(" — ")
        Record::Decision.new(
          path: entry && entry["path"], line: entry && entry["line"],
          subject: subject, reason: reason,
          kind: (change && change["kind"]) || (entry && entry["kind"]),
          replacement: (change && change["replacement"]) || (entry && entry["replacement"]),
          source: (change && change["source"]) || (entry && entry["source"])
        )
      end

      # **A call site from a rung below this one is a different kind of work from this rung's**, and the
      # scan's own answer says which: every entry carries the rung that named it. The walker scans from the
      # ladder's `earliest` so that a rule can fix a change an application never made — and the residue has
      # to say so, or an application that is behind reads as one that is merely unfinished.
      #
      # **Whether the application has crossed that rung is a fact this step knows, and the sentence said
      # the opposite of it.** Measured at the 5.1 rung: its `protect_from_forgery` entry is a change of the
      # rung that arrives at 5.0.0, and the tree *is* 5.0.0 — a call site that has been carried unfixed
      # since, not one the application has not reached yet. The two want different work: the first asks
      # why the rung that owned it left it, the second asks whether the rung has run at all.
      def earlier_rung(entry, rung, from = nil)
        named = (entry && entry["step"]).to_s
        return nil if named.empty? || rung.to_s.empty? || named == rung.to_s

        if crossed?(from, named)
          "carried by an earlier rung — the one that arrives at #{named}, which this application has " \
            "already crossed, so this call site has been carried unfixed since"
        else
          "carried by an earlier rung — the one that arrives at #{named} — which this application has " \
            "not crossed, so this call site is still in its old form"
        end
      end

      # Whether the application's own version is at or past a rung. An unparseable version answers "not
      # crossed", which is the sentence that asks a person to look rather than the one that claims they
      # already have.
      def crossed?(from, named)
        return false if from.to_s.empty?

        Gem::Version.new(from.to_s) >= Gem::Version.new(named.to_s)
      rescue ArgumentError
        false
      end

      # **What a survey found, in the decision's own words.** "None found" and "no survey" are two
      # different sentences on purpose: the first is an observation about *this* application, and the
      # second is a change nobody has written a reader for. A residue that collapsed them would read as
      # if the analysis had been done.
      def survey_note(found)
        return nil if found.nil?

        detail = found.findings.empty? ? "none found" : Rewrites.findings_sentence(found.findings)
        "this application: #{found.sentence} — #{detail}"
      end

      # Which files to send. Bounded, and the bound is stated rather than silently
      # applied: a scan that read a slice and reported "nothing found" would be the
      # empty answer that means four things (`/rails/scan`'s own caveat).
      def source_files
        root = @worktree.root
        paths = Dir.glob("**/*", base: root).reject do |path|
          SCAN_SUFFIXES.none? { |suffix| path.end_with?(suffix) } ||
            path.split("/").any? { |part| SCAN_SKIP.include?(part) }
        end.sort

        chosen = []
        bytes = 0
        paths.each do |path|
          break if chosen.size >= MAX_SCAN_FILES
          text = File.read(File.join(root, path)) rescue next
          break if bytes + text.bytesize > MAX_SCAN_BYTES

          bytes += text.bytesize
          chosen << [path, text]
        end
        @out.puts("  scan: #{chosen.size} of #{paths.size} file(s) (#{bytes} bytes)" \
                  "#{chosen.size < paths.size ? " — bounded" : ""}") if @out
        chosen
      end

      # The one edit this tool makes outside the applier, and it is one line. Only the
      # meta-gem is rewritten: an application that pins the framework as components has a
      # different line for each one, and choosing which of them move together is a decision
      # —'s fourth rule. A repository in that shape is refused, with the sentence saying what
      # to do instead.
      def rewrite(stages, step)
        path = File.join(@worktree.root, "Gemfile")
        text = File.read(path)
        updated = rewrite_pin(text, step["to_version"])
        unless updated
          why = "Gemfile does not pin the meta-gem (`gem \"rails\", \"x\"`), so this tool " \
                "will not choose which of the framework's components move: change the pin " \
                "to #{step["to_version"]} yourself and re-run"
          return Record.refused(repository: @repository, commit: @worktree.commit,
            worktree: @worktree.root, from_version: @from,
            to_version: step["to_version"], why: why)
        end

        File.write(path, updated)
        # **The digest's rung-scoped entries wait for this line, and this is the line.** A `declared`
        # entry is about a gem the *target* framework brings in; rung-scoped entries — declarations
        # and rewrites alike — are deferred by the preflight (which runs before this rewrite, because
        # the machine choice is a `bundle install` of the Gemfile as it stands) and are applied here,
        # between the pin and the resolve. Measured at the 4.2 rung: `responders ~> 2.0`
        # beside `rails 4.1.0` makes the resolver answer `railties (< 5, >= 4.2.0.alpha)`
        # against `railties (= 4.1.0)` for every era, so no interpreter installs the bundle;
        # declared here it resolves to 2.4.1 and the pin succeeds.
        declare_for_the_rung(stages)
        pin(stages)
        nil
      end

      # The rung-scoped entries the preflight held because the Gemfile still named the release
      # the move starts from, applied now that the pin agrees with the rung. Its own stage,
      # because "the digest declared a gem this application never had" — or moved a line it could
      # not move yet — is a fact a reader of the record has to see beside the pin it made
      # possible, and because an entry that silently did not happen is the empty answer this
      # pipeline keeps paying for.
      def declare_for_the_rung(stages)
        entries = @deferred.to_a
        result =
          if entries.empty?
            Preflight::Result.new(repairs: [], decisions: [], notes: [], deferred: [])
          else
            @preflight.declare_deferred(entries)
          end
        @applied.concat(result.repairs)
        @decisions.concat(result.decisions)
        stages << Record::Command.new(
          stage: Record::DECLARATIONS,
          command: entries.empty? ? "declarations: none held for this rung" :
            "declarations: #{result.repairs.size} declared for this rung",
          ran: true, exit_code: 0, seconds: 0.0,
          output_tail: result.details.first(20).join("\n")
        )
        @out.puts("  declarations: #{result.summary}") if @out && entries.any?
        result
      end

      # **The pin is a conversation with the resolver, and the resolve moves what it must and puts
      # back what it must not.** A rung moves Rails and not the world: the lighthouse proved what
      # the alternative costs — the application pinned rake 10.0.4, the unconstrained `bundle
      # update rails` resolved 12.3.3 (railties 4.1 only asks `rake >= 0.8.7`), and Rails 4.1's own
      # `rails:update` then died on `Rake::Application#last_comment`, which rake 11 removed. So the
      # first attempt names the framework's own gems and keeps everything else where the
      # application put it.
      #
      # **A locked gem the move *requires* is then named by bundler itself.** Its message is
      # the authority on what the resolve could not leave alone — "could not find compatible
      # versions for gem i18n: rails (= 4.1.0) ... activesupport (= 4.1.0) ... depends on i18n
      # (>= 0.6.9, ~> 0.6)" — a fact no compatibility matrix here could have, because it is the
      # resolver's own answer for this application. Each round unlocks exactly the gems named,
      # so `i18n` and `coffee-rails` move with the framework. The rounds are capped because a
      # cascade is finite but a walk is not: every round adds at least one gem, and the cap is
      # what stops a pathological one from spending the step.
      #
      # **`--conservative` does not keep `rake` where the application put it, and that is measured
      # rather than read off the flag's name**: it moved rake 10.0.4 → 12.3.3 anyway, and the next
      # rung's `db:create` died on the API rake 11 removed. So the resolve is followed by a hold:
      # the gems it moved *without being asked to* go back to the versions it found them at, by a
      # constraint that lives only for the length of a second resolve. The lock is what keeps them
      # there afterwards, because `bundle install` honours a lock that already satisfies the
      # Gemfile — the other candidate, `bundle lock --update`, holds correctly and cannot resolve
      # at all here (measured: the probe's `bundle install` fails on the rspec family and no era
      # installs the bundle, which is worse than the problem it fixes). A constraint the resolver
      # refuses is *released* rather than forced, and bundler names it, the same way it names what
      # has to move: a gem the move really needs is a gem that has to move.
      def pin(stages)
        resolved = conservative_update(stages, pin_named, stage: Record::PIN)
        return resolved unless resolved.ok?

        hold_what_the_move_did_not_need(stages, @lockfile)
      end

      # **The framework plus every gem this step has rewritten a line for.** The pin's own rounds are
      # the widening, and a widening spends a round per conflict — so a gem the step has already decided
      # to move has to be named from the first round, or the resolve spends its early rounds on a line
      # this step has already changed and may run out before it reaches the real one. Measured at the
      # 5.0 rung: `guard-rspec 3.1.0` declares `rspec ~> 2.13`, rspec-rails 3.5 needs `rspec-core
      # ~> 3.5.0`, and the resolve named `rspec-core`, `rspec` and `rspec-rails` over two rounds and
      # never named `guard-rspec` — the line the routing had already moved at this rung — so the pin
      # failed with the move made. The bundle stage's fallback already names exactly this set
      # (`moved_gems`), and the two naming the same gems is the point rather than a coincidence.
      def pin_named
        (pin_gems + moved_gems).uniq
      end

      # The gems the resolve moved that it was not asked to, and the versions it moved them from.
      # Read out of the two locks rather than reasoned about from a dependency graph: what moved is
      # a fact, and "what usually moves with Rails" is the guess this exists to avoid.
      def moved_without_need(before, named, after)
        before.select { |name, was| after.key?(name) && after[name] != was && !named.include?(name) }
      end

      # The hold, as the Gemfile lines it is spelled in — pure, because they are the only lines this
      # tool writes that are not the application's own, and a test can hold them still.
      def hold_lines(held)
        held.map { |name, version| %(gem "#{name}", "= #{version}") }
      end

      # **A gem the application declares is the application's line, not this tool's.** Appending a
      # second line for one is not a hold at all: bundler refuses the Gemfile outright — "You cannot
      # specify the same gem twice with different version requirements. You specified: capistrano
      # (>= 0) and capistrano (= 2.15.4)" — and the pin fails. Rewriting the line is not the answer
      # either, because the preflight will not touch a declaration that carries an option (`require:`,
      # `platforms:`, `group:`) and `capistrano` carries one. So the hold is only for the gems the
      # Gemfile does not mention.
      def undeclared(held, gemfile_text)
        declared = gem_names(gemfile_text)
        held.reject { |name, _| declared.include?(name) }
      end

      def held_gemfile(text, held)
        lines = hold_lines(held)
        return text if lines.empty?

        "#{text.chomp}\n#{lines.join("\n")}\n"
      end

      # **A located line that already reads the new way is not work, and the line is what says so.** A
      # rule's own `already` guard answers exactly that question — "this line is what I would write" —
      # and `rules.satisfied` asks it per *subject*, which is right for a change whose lines are all of
      # one kind and wrong for one whose subject spans lines that are not: the 5.1 record's `belongs_to`
      # entries are four model lines this tool itself answered with `optional: true` at the 5.0 rung and
      # four migration columns the change never applied to, so a subject-level answer has to call them
      # all the same thing. The line's own answer does not.
      def already_reads_the_new_way?(decision, tree)
        path = decision.path.to_s
        return false if path.empty? || decision.line.nil?

        line = Array(tree[path])[decision.line.to_i - 1]
        return false if line.nil?

        Rewrites::RULES.select { |rule| rule.subject == decision.subject.to_s }
          .any? { |rule| rule.satisfied?(line, Rewrites.mask(line)) }
      end

      # **A located line inside a rule's own scaffold is the change's own artifact, not work.** The
      # `ActiveRecord::Base` change writes `app/models/application_record.rb` and moves every model onto
      # it; the definition itself has to keep naming `ActiveRecord::Base`, so the rule excludes it *by
      # name* — and the scan locates it on every rung, which is why both the 5.1 and the 5.2 residues
      # carried that one line as a decision. The ladder's own note says to expect the file in the list;
      # the rule's scaffold is what says the line is not a person's work.
      def the_changes_own_scaffold?(decision)
        path = decision.path.to_s
        return false if path.empty?

        Rewrites::RULES.any? do |rule|
          rule.subject == decision.subject.to_s && rule.scaffold && rule.scaffold.path == path
        end
      end

      # The gems to put back right now: what the resolve has moved without being asked to, minus the
      # application's own declarations, minus the ones the resolver has already refused to hold.
      # Recomputed after every round rather than carried, because unlocking a gem to restore it can
      # move something else, and the property this stage is for is about the lock it ends on.
      def holdable(before, gemfile_text, refused)
        lockfile = Lockfile.read(@worktree.root)
        moved = moved_without_need(before.specs, pin_named, lockfile.specs)
        undeclared(moved, gemfile_text)
          .select { |name, was| fits_both_ways?(before, lockfile, name, was) }
          .except(*refused)
      end

      # **A version fits both ways or it does not fit.** Nothing the resolved graph requires of the gem
      # may rule its old version out, *and* nothing the gem itself required of its own dependencies may
      # have moved past what it asks for. The first half alone is not enough — measured, it admits
      # `rspec 2.13.0` against `rspec-core 2.14.8` — and a hold that cannot be satisfied does not just
      # fail to restore a gem: it makes every resolve impossible and takes the pin with it.
      def fits_both_ways?(before, after, name, was)
        return false unless after.accepts?(name, was)

        before.requires_of(name).all? do |dependency, requirement|
          !after.specs.key?(dependency) ||
            requirement.satisfied_by?(Gem::Version.new(after.specs[dependency]))
        end
      end

      # **A hold that exists only for the length of a resolve, and names what it holds.** The
      # constraints go in, the resolve runs, and the Gemfile is put back exactly as it was — in an
      # `ensure`, because a resolve that dies must not leave this tool's lines in somebody's Gemfile.
      # What survives is the lock.
      #
      # **Naming the held gems is not an optimisation, it is the mechanism.** `bundle update <the
      # framework> --conservative` re-resolves the named gems and their dependencies, so a gem it
      # moved that is *not* named cannot be put back at all: measured on the lighthouse, holding
      # `bcrypt-ruby` — a transitive dependency of the application's own `capistrano` line — made
      # bundler answer "You have requested: bcrypt-ruby = 3.0.1 / The bundle currently has
      # bcrypt-ruby locked at 3.1.5" and exit 7, which failed the pin. Named, it comes back.
      #
      # **A restore the resolver will not make is a gem that stays where the resolve put it.** The
      # move is what this stage exists to make; a gem the move had no reason to touch is not worth
      # failing it for. Bundler names the gem when it can — the same sentence the widening reads —
      # and when it names none of them the whole restore is what is in the way, so it goes and the
      # resolve is made once more without it.
      def hold_what_the_move_did_not_need(stages, before)
        gemfile = File.join(@worktree.root, "Gemfile")
        original = File.binread(gemfile)
        lock_before = File.binread(File.join(@worktree.root, "Gemfile.lock"))
        refused = []
        attempt = stages.last
        PIN_ROUNDS.times do
          held = holdable(before, original, refused)
          break if held.empty? && attempt.ok?

          File.binwrite(gemfile, held_gemfile(original, held))
          attempt = conservative_update(stages, pin_named + held.keys, stage: Record::PIN)
          return attempt if attempt.ok? && holdable(before, original, refused).empty?
          # A resolve that succeeded and still moved something is not a failure: the next round holds
          # that too. Only a *failed* resolve is read for a name.
          next if attempt.ok?

          named = stuck_gems(attempt.output_tail) & held.keys
          if named.empty?
            # **A conflict that names none of the holds is not the holds' doing, and the move is what
            # the rung is for.** The Gemfile goes back exactly as it was and the resolve is made once
            # more without them: a rung that moves Rails and leaves one gem where the resolve put it is
            # the outcome this stage must never trade for a failure.
            File.binwrite(gemfile, original)
            return conservative_update(stages, pin_named, stage: Record::PIN)
          end

          refused |= named
        end
        attempt
      ensure
        File.binwrite(gemfile, original) if original
        drop_leaked_dependencies(lock_before) if lock_before
      end

      # **A hold must not leave a claim in the lockfile that the Gemfile does not make.** A resolve
      # writes the gems it was asked to hold into the lock's own `DEPENDENCIES` section, because for the
      # length of that resolve the Gemfile really did declare them — measured, the 4.1 rung's lock ended
      # listing `rake (= 10.0.4)` and `thread_safe (= 0.1.0)` beside the application's own lines. The
      # Gemfile is put back, so that claim is false, and a lock that disagrees with its Gemfile is one
      # the next `bundle install` re-resolves — which is precisely how the gem this stage exists to hold
      # gets moved again. The pinned *versions* are the point and they stay; the claim goes.
      def drop_leaked_dependencies(lock_before)
        path = File.join(@worktree.root, "Gemfile.lock")
        after = File.binread(path)
        leaked = declared_dependencies(after) - declared_dependencies(lock_before)
        return if leaked.empty?

        File.binwrite(path, after.lines.reject { |line|
          leaked.any? { |name| line.match?(/^\s{2}#{Regexp.escape(name)}(?![-\w])/) }
        }.join)
      end

      # The names a lockfile's own `DEPENDENCIES` section lists.
      def declared_dependencies(text)
        section = text[/^DEPENDENCIES\n(.*?)(?=\n\S|\z)/m, 1].to_s
        section.lines.filter_map { |line| line[/^\s{2}([^\s(!]+)/, 1] }
      end

      # The gems bundler said it could not leave alone, as its own message names them. Read
      # rather than guessed: the resolver knows this application's requirement graph, and a
      # list of "gems that usually have to move with Rails" would be a second, worse answer.
      # Names the lockfile does not pin are dropped — nothing outside it can be unlocked.
      def stuck_gems(text)
        quoted = text.to_s.scan(/could not find compatible versions for gem "([^"]+)"/).flatten
        bare = text.to_s.scan(/could not find compatible versions for gem ([\w.-]+)/).flatten
        # **The other shape of the same answer, and it is why a digest declaration can be
        # narrowed at all.** A Gemfile line the move *added* — a `declared` entry — is a
        # requirement the lock does not satisfy, and bundler answers by naming the gem to unlock
        # rather than with a version conflict: measured at the 4.2 rung, `responders ~> 2.0`
        # declared beside a lock holding 1.1.2 exits 7 with "You have requested: responders
        # ~> 2.0 / The bundle currently has responders locked at 1.1.2. / Try running `bundle
        # update responders`". The pin's first round names only the framework, so without this
        # the rung fails on a gem the digest had already declared and the resolve never runs.
        requested = text.to_s.scan(/The bundle currently has ([\w.-]+) locked at/).flatten +
                    text.to_s.scan(/Try running `bundle update ([^`]+)`/).flatten
        # **And the requirer whose own requirement is on the gem bundler could not place — directly,
        # and no further.** The gem bundler cannot place is often not the gem holding it back: measured on
        # the lighthouse's rspec-rails move, bundler named `rspec-mocks`, `rspec-expectations` and
        # `rspec-core` in three rounds while the pin that made all three impossible was the `rspec`
        # *meta*-gem's own `~> 2.13.0` — which the message names only as the requirer, with the
        # dependency line it contributes directly underneath it.
        #
        # **"And no further" is measured, not tidy.** The message nests, and a requirer three hops
        # down is a gem that merely *reaches* the conflict: on the 4.2 rung `resque` appeared as a
        # requirer of `rack` through `sinatra` and `rack-protection`, naming it unlocked resque
        # itself, and it resolved to 2.7.0 — a release that needs Ruby 2.3 while the era's interpreter
        # is 2.1, which bundler 1.17 reports but does not resolve around. The pin then failed on a gem
        # the move never had to touch, and the same run with `rack` named and resque left alone
        # resolves. So the requirer is the name on the line whose *next* line begins with the gem
        # bundler could not place.
        #
        # **And the name carries its requirement.** Bundler writes a requirer as
        # `sinatra (>= 0.9.2) was resolved to 1.4.2`, and the first pattern here required the name to
        # be followed straight by " was resolved to" — so every requirer line with a parenthesised
        # requirement was invisible: measured at the 5.0 rung, the conflict on `rack` named
        # `sinatra`, `rack-protection`, `vegas` and `warden` that way, the widening extracted none of
        # them, and the pin was asked once and failed on a `rack` four other gems could have unlocked.
        # A dependency line that is the bare name is matched too, because bundler writes a
        # requirement-less dependency as just the gem.
        named = quoted + bare
        requirers = text.to_s.lines.each_cons(2).filter_map do |line, following|
          requirer = line[/^\s*([A-Za-z0-9_.-]+)(?:\s*\([^)]*\))?\s+was resolved to/, 1]
          next unless requirer
          next unless named.any? { |gem| following.strip.match?(/\A#{Regexp.escape(gem)}(?:\s|\()|\A#{Regexp.escape(gem)}\z/) }

          requirer
        end
        # **A conflict name is filtered by the lock; a name the resolver says the *bundle* holds is
        # not, and that difference is measured.** For a version conflict the gem is in the snapshot
        # (that is why it conflicts), and a name outside it cannot be unlocked. But "The bundle
        # currently has responders locked at 1.1.2" names a gem the *new* resolution brought in and
        # the old lock never held — measured at the 4.2 rung, where responders is not in the 4.1
        # lockfile at all and filtering it out left the pin asked once, failing on the gem the digest
        # had just declared.
        ((named + requirers).uniq & @lockfile.specs.keys) + requested
      end

      # **The gems that move with the meta-gem, and the measurement that says they must be
      # named.** Rails releases its framework components in lockstep, so `rails (= 4.1.0)`
      # requires `activemodel (= 4.1.0)` — and a conservative resolve that left `activemodel`
      # where the move found it cannot find a compatible set at all: bundler answered "could
      # not find compatible versions for gem activemodel ... rails (= 4.1.0) ... depends on
      # activemodel (= 4.1.0)", with its own advice to rebuild the snapshot from scratch,
      # which is the unconstrained update that moved rake. The set is read from the
      # application's lockfile — the gems pinned at the version the move leaves — rather than
      # from a component list kept here, because such a list would have to be extended by hand
      # for every Rails release that adds one (`actioncable`, `activestorage`, `actiontext`)
      # and would be silently wrong for the release this tool has not met yet.
      def pin_gems
        ["rails", *@lockfile.pinned_at(@from)].uniq
      end

      # Pure, and its own method, because it is the one thing that rewrites a line of
      # somebody's Gemfile and a test can hold it still.
      def rewrite_pin(text, version)
        lines = text.lines
        found = lines.index { |line| line =~ /^\s*gem\s+["']rails["']/ }
        return nil unless found

        line = lines[found]
        if line =~ /^(\s*gem\s+["']rails["']\s*,\s*)(["'])([^"']*)(\2)/
          lines[found] = "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{version}#{Regexp.last_match(4)}\n"
        elsif line =~ /^(\s*gem\s+["']rails["'])(\s*)$/
          lines[found] = "#{Regexp.last_match(1)}, \"#{version}\"\n"
        else
          # A pin this does not understand — `gem "rails", github: ...`, a version
          # inside a group with other arguments — is left alone rather than guessed at.
          return nil
        end
        lines.join
      end

      # `app:update` proposes new files and new versions of files the application
      # already owns, and "take theirs" is how an application loses its configuration.
      # So: run it, keep what is additive, put everything it modified back, and record
      # the conflicts. `config.load_defaults` is never flipped, and that falls out of
      # this rule rather than being a special case — `config/application.rb` is a file
      # the application already owns, so its version stays.
      def update(stages)
        runner, task = update_runner
        unless runner
          stages << Record::Command.new(stage: Record::RAILS_UPDATE,
            command: "bin/rails app:update",
            ran: false, exit_code: nil, seconds: 0.0,
            output_tail: "no bin/rails and no Rakefile: nothing to run")
          return
        end

        before = self.class.dirty_paths(@worktree.root)
        # **`app:update` is a generator, and a generator runs in the application's own default
        # environment.** The walker runs everything else in `test` — the suite is a test suite and the
        # database it prepares is the test one — and that was right for every stage until this one. It
        # is wrong here in a way a real walk showed: the update task loaded `shoulda-matchers 2.1.0`
        # from the application's test group, and that gem cannot load under the minitest 5 the release
        # brought, so a task about config files failed on a test gem. Nothing about `app:update` is
        # test-specific; a person runs it in development, which is what this does.
        answers = overwrite_answers
        begin
          stages << command(Record::RAILS_UPDATE, runner + [task], chdir: @worktree.root,
            env: application_env.merge("RAILS_ENV" => "development", "RACK_ENV" => "development"),
            stdin: answers)
        ensure
          answers.close
        end
        @adopted, @conflicts = self.class.adopt_added_only(@worktree.root, before)
        drop_engine_migrations(@adopted)
      end

      # **A migration `app:update` copies for an engine this application does not have is not kept.**
      # Measured at the 6.1 rung: `app:update` runs `active_storage:update`, which copies
      # `db/migrate/*.active_storage.rb` into the application — `add_service_name_to_active_storage_blobs`
      # and `create_active_storage_variant_records` — and this 2013 application has **no** Active
      # Storage at all: `db/schema.rb` mentions it zero times, and 6.0's own generated migration was
      # guarded for exactly that. The first of the two is not guarded, so the step's own database
      # preparation fails on it —
      #
      #     PG::UndefinedTable: ERROR:  relation "active_storage_blobs" does not exist
      #     db/migrate/…_add_service_name_to_active_storage_blobs.active_storage.rb:4:in `up'
      #
      # — and the suite then aborts on `ActiveRecord::Migration.check_pending!` before a single
      # example runs. Rails' engines name their migrations with their own suffix (`.active_storage.rb`),
      # which is what makes this a mechanical test rather than a guess: an addition under `db/migrate/`
      # whose engine suffix names an engine whose tables the application's schema does not declare is a
      # migration for a component this application does not use. It is removed and the reason recorded
      # as a decision, because an application that *does* want the component installs it
      # (`bin/rails active_storage:install`) — and a migration kept for a table that does not exist is
      # a rung that cannot pass. The safe direction when there is no `db/schema.rb` to read is to keep
      # it: the failure is then the one this mechanism exists to name, not a silent deletion.
      def drop_engine_migrations(adopted)
        schema = File.join(@worktree.root, "db", "schema.rb")
        return if adopted.empty? || !File.file?(schema)

        declared = File.read(schema)
        adopted.dup.each do |path|
          engine = path[/\Adb\/migrate\/[^\/]+\.([a-z_]+)\.rb\z/, 1]
          next if engine.nil?
          next if declared.match?(/create_table "#{engine}_/)

          File.delete(File.join(@worktree.root, path))
          @adopted.delete(path)
          # **An edit this tool made, not work for a person.** The removal *is* the change — the rule
          # above decided it from two facts the application states — so it belongs in the record's
          # applied list beside the preflight's repairs, where a reader sees what moved. It was a
          # *decision* first, which read as three more things somebody had to act on at a rung whose
          # residue was otherwise accounted for; a decision list is what still needs a person, and this
          # does not. The note travels with the edit, so the record still says why.
          @applied << Preflight::Repair.new(path: path, line: nil, text: nil, after: nil,
            subject: "#{engine} migration #{File.basename(path)}",
            note: "`app:update` copied this migration for #{engine}, and the application's " \
                  "`db/schema.rb` declares no `#{engine}_*` table — so it is a migration for a " \
                  "component this application does not use, and running it fails on the table it " \
                  "assumes. Install the component first (`bin/rails #{engine}:install`) if the " \
                  "application wants it")
        end
      end

      # **The runner and the task are one decision, because Rails 5.0 moved both commands from
      # rake to the CLI.** `app:update` and `rails:update` are two names for one job, and the
      # four combinations of runner and task include two that fail with a command-not-found —
      # a 4.x task through `bin/rails` says "Command 'rails:update' not recognized", and a 5.x
      # task through rake says "Don't know how to build task 'app:update'". So they are chosen
      # together, from the application's own version, and the fallback is the same shape as
      # before: an application with neither binstub nor Rakefile has nothing to run.
      def update_runner
        if rails_five_or_newer?
          return [["bin/rails"], "app:update"] if File.executable?(File.join(@worktree.root, "bin/rails"))

          return nil
        end
        return [["bundle", "exec", "rake"], "rails:update"] if File.file?(File.join(@worktree.root, "Rakefile"))

        nil
      end

      # The Rails version the application is *on* — the one whose commands would run, read from
      # the lockfile the step opened before anything was written. `major >= 5` is the whole
      # rule: every command that moved did so at 5.0, and an application on a pre-release
      # (`4.0.0.rc1`) is on 4.
      def rails_five_or_newer?
        @lockfile&.rails&.version.to_s.split(".").first.to_i >= 5
      end

      # **The class methods in this file are public, and the `private` markers around them
      # govern instance helpers only** — a bare `private` cannot reach a singleton method,
      # which is what `Lint/IneffectiveAccessModifier` reports. Their callers are outside the
      # class rather than only inside it: the suite drives `Step.dirty_paths`,
      # `Step.adopt_added_only` and `Step.run_payload` directly (`test/step_test.rb`), and
      # `update` and `contribute` call `self.class.…` with an explicit receiver, which a
      # private method refuses. The markers below are what says so.
      public

      # Class methods rather than instance ones: they are the policy, and a policy with
      # a git repository and nothing else is a policy a test can hold still without
      # installing a bundle or booting an application.
      def self.adopt_added_only(root, before)
        adopted = []
        conflicts = []
        dirty_paths(root).each do |path, status|
          next if before.key?(path)
          next if path == "Gemfile" # ours: the pin, deliberately rewritten

          if status == "??"
            adopted << path
          else
            restore(root, path)
            conflicts << path
          end
        end
        [adopted, conflicts]
      end

      # Every path git considers dirty, and how. `--porcelain` because the format is
      # stable and meant for this, and the two-character status is kept because `??`
      # (added) and ` M` (modified) are the distinction the policy turns on.
      #
      # `-uall` is load-bearing rather than a preference. By default git collapses a
      # wholly untracked directory into one entry — `?? config/` — and the policy above
      # reasons about *paths*: a file `app:update` added inside an untracked directory
      # would arrive as the directory, and a file it modified inside one could not be
      # seen as a conflict at all. The default would silently adopt whatever it wrote
      # inside a directory the application had not committed yet.
      def self.dirty_paths(root)
        output, _status = Open3.capture2e("git", "-C", root, "status", "--porcelain", "-uall")
        output.each_line.filter_map do |line|
          path = line[3..].to_s.strip
          next if path.empty?

          [path, line[0, 2].strip.empty? ? "  " : line[0, 2].strip]
        end.to_h
      end

      # The application's version wins. `checkout --` restores from the index, which is
      # HEAD here, and that is also what keeps `config.load_defaults` where the
      # application put it — no special case needed, because `config/application.rb` is
      # a file the application already owns.
      def self.restore(root, path)
        Open3.capture2e("git", "-C", root, "checkout", "--", path)
      end

      # Its only caller is `adopt_added_only`, above. Nothing outside the class names it, so
      # the tightening is real rather than decorative.
      private_class_method :restore

      private

      def boot(stages)
        return unless File.executable?(File.join(@worktree.root, "bin/rails"))

        stages << command(Record::BOOT, ["bin/rails", "runner", "puts Rails.version"],
          chdir: @worktree.root, env: application_env)
      end

      # The patch, for a person to apply. Untracked files are included, because
      # `app:update`'s added files are part of what this step did.
      def capture_patch
        Open3.capture2e("git", "-C", @worktree.root, "add", "--intent-to-add", "--all")
        output, _status = Open3.capture2e("git", "-C", @worktree.root, "diff")
        output
      end

      def build(step, stages, verdict, why)
        settle_decisions_against_the_lock
        Record.new(
          repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
          from_version: step["from_version"], to_version: step["to_version"], name: step["name"],
          requires_ruby: step["requires_ruby"], interpreter: @machine.interpreter,
          image: @machine.image, machine: @machine.stamp,
          era: @machine.respond_to?(:era) ? @machine.era : nil,
          stages: stages, applied: @applied, refused: @refused, decisions: @decisions,
          patch: capture_patch, baseline: @baseline, suite: @suite,
          verdict: verdict, why: why
        )
      end

      # **A residue line the lock this step ended with already answers is not work.** The routing is
      # asked before the pin, against the lockfile the step *starts* with, so a gem the Rails move
      # itself carries forward is a verdict this tool cannot apply — it is not declared, so the pin's
      # own update is what moves it — and it reaches the record as a decision at `Gemfile.lock`.
      # Measured at the 5.0 rung: `rails-dom-testing 1.0.9` was the record's one *located* decision
      # beside a lock that ended at 2.1.1, which the pin had just resolved. So the filter runs at the
      # end, and only on decisions whose subject names a gem: the question is the lock's own answer,
      # not the route's.
      def settle_decisions_against_the_lock
        final = begin
          Lockfile.read(@worktree.root).specs
        rescue Lockfile::Missing, Lockfile::Unreadable
          nil
        end
        return if final.nil?

        @decisions.reject! do |decision|
          next false unless decision.path.to_s == "Gemfile.lock"

          name, version = decision.subject.to_s.split(" ", 2)
          settled = !name.to_s.empty? && !version.to_s.empty? && final.key?(name) && final[name] != version
          @out.puts("  residue: #{decision.subject} is settled by the lock (#{name} #{final[name]})") if
            settled && @out
          settled
        end
      end

      # Every command a step runs is bounded (`Shell::DEFAULT_COMMAND_TIMEOUT`, or the operator's
      # `UPGRADER_COMMAND_TIMEOUT`): the *suite* has its own bound through `Tests`, and nothing else had one —
      # so a container that could not reach rubygems held a step in `bundle update` until somebody noticed.
      # `excerpt_bytes` is how a caller says its output is *evidence* rather than a payload: a
      # resolver prints the blocks that name why it refused, and `Shell::RESOLVER_BYTES` keeps them all.
      def command(stage, argv, chdir:, env: {}, machine: nil, stdin: File::NULL,
                  excerpt_bytes: Shell::TAIL_BYTES)
        runner_machine = machine || @machine
        argv, env = runner_machine.command(argv, chdir: chdir, env: env) if runner_machine
        @runner.run(argv, stage: stage, chdir: chdir, env: env, stdin: stdin,
          timeout: command_timeout, excerpt_bytes: excerpt_bytes)
      end

      # How many overwrite questions one update task may ask. Generous rather than counted: an application
      # with a few hundred files it owns asks about each one, and a pipe that ran dry would turn the rest
      # into EOF — which is the same hang this exists to stop, one prompt later.
      OVERWRITE_ANSWERS = 500

      # **The overwrite answer, given rather than asked.** `app:update` stops on every file the application
      # owns and asks; a walker that leaves the answer to a prompt does not finish. The walk that found this
      # was killed at its command bound with Rails' `Overwrite config/boot.rb?` on screen and the same question
      # printed again below it, because the walker hands every command `File::NULL`.
      #
      # The answer is the rule the walker already states — "added files are adopted; a file the application
      # already owns keeps the application's version" — so it is `n` for every question, and the conflicts are
      # recorded from the tree's own diff (`adopt_added_only`) rather than from the prompt. A pipe rather than
      # a flag because the two command families spell the flag differently and a 4.x application has only the
      # prompt.
      def overwrite_answers
        reader, writer = IO.pipe
        writer.write("n\n" * OVERWRITE_ANSWERS)
        writer.close
        reader
      end

      def command_timeout
        raw = @env[Shell::ENV_TIMEOUT].to_s
        raw.empty? ? Shell::DEFAULT_COMMAND_TIMEOUT : raw.to_i
      end

      # The ledger learns one line per move, and the record goes where an operator
      # asked for it. Both happen here so that a step which cannot finish still
      # settles what it established.
      def finish(record)
        # A refusal is settled too, and it must be: re-deriving it reaches the same
        # refusal. What is *not* recorded is a move whose starting release could not be
        # read — "unknown -> 7.1.0" is not a key about anything, and a ledger entry
        # under it would hide the next attempt behind a key nobody can look up.
        if @ledger && record.from_version != "unknown"
          @ledger.record(repo: record.repository, commit: record.commit,
            from_version: record.from_version, to_version: record.to_version,
            verdict: record.verdict, baseline: record.baseline&.exit_code,
            image: record.image, machine: record.machine, era: record.era, note: record.why)
        end
        contribute(record) if @contribute
        @out.puts(record.to_s) if @out
        print_failure_evidence(record) if @out
        record.write(@record_dir) if @record_dir
        record
      end

      # **A failed step prints the evidence, not only the command it ran.** The summary names the stage
      # that failed and quotes its command; the *reason* is in that stage's own output, and an operator
      # who has to re-run the step with `--record` to read it has been told a walk failed and not why.
      # Measured: the 5.1 rung's `bin/rails app:update` exit 1 was visible only as `— exit 1 in 2.2s`,
      # and the reason needed a second, recorded run.
      #
      # The stage is chosen by the verdict's own sentence, which quotes the command of the stage that
      # decided it, rather than by "the first non-zero exit": a step runs stages that are *expected* to
      # fail (`bundle install` refusing a changed line, the pin's widening rounds), and printing those
      # would bury the one that mattered.
      def print_failure_evidence(record)
        why = record.why.to_s
        named = record.stages.select do |stage|
          stage.ran && stage.exit_code.to_i != 0 && !stage.command.to_s.empty? &&
            why.include?(stage.command.to_s)
        end
        # **A verdict about the suite names no command**, and the suite's own output is the evidence:
        # "the suite was green before this step and failed after it" has no stage's argv in it, so the
        # selection above is empty and the reason a rung stopped was never printed — measured at the
        # 5.1 rung, whose suite exit 1 arrived as that sentence alone. The fallback is the suite's own
        # stage rather than "the last non-zero exit", because a failed pin or boot leaves the suite
        # failing too and the last stage would be the symptom.
        if named.empty?
          named = [record.stages.reverse.find do |stage|
            stage.ran && stage.exit_code.to_i != 0 && stage.stage.to_s == Record::SUITE
          end].compact
        end
        named.first(2).each do |stage|
          @out.puts("  #{stage.stage} failed (exit #{stage.exit_code}); its output:")
          stage.output_tail.to_s.lines.last(20).each { |line| @out.puts("    #{line.chomp}") }
        end
      end

      # The run, and — if it failed — the report.: a step that fails is evidence with the
      # corpus's own report shape, so it becomes a report by the ordinary path, precheck
      # first, and one that passes is the other half of the record: proof that a crossing was
      # executed inside something real.
      def contribute(record)
        # What counts as a repository is the service's rule and only the service's:
        # `routers/upgrades.py`'s `identity()` canonicalises a URL and deliberately
        # leaves a bare path alone, because an operator may legitimately name a
        # directory on a machine that has it. A second opinion here — "that is not a
        # repository URL, so it is not a queue entry" — would be this tool disagreeing
        # with the only side that owns the answer.
        client = @corpus || Corpus.new(base: @api)
        answer = client.record_run(self.class.run_payload(record))
        run = answer.is_a?(Hash) ? answer["run"] : nil
        @out.puts("  recorded: run #{run && run["id"]} (#{record.verdict})") if @out

        filing = Filing.file(corpus: client, record: record)
        @out.puts("  filed: #{filing.action} — #{filing.reason}") if @out && filing.action != "skipped"
      rescue Corpus::Unreachable, Corpus::Refused => e
        # The record is the product and it exists whether or not the corpus took it, so
        # this does not change the verdict or raise. It is logged with the service's own
        # sentence rather than swallowed: a refusal that will happen every cycle looks
        # exactly like a quiet run from the outside, which is the miner's lesson about a
        # bare `rescue` around a remote call.
        @out.puts("  not recorded: #{e.message}") if @out
      end

      # Public for the reason the policy group above is — `test/step_test.rb` holds this
      # shape still — and `private` is restored below because `run_id`, the last method in
      # this class, is an instance helper.
      public

      # The body `POST /upgrades/runs` takes, built from the record alone. A class method
      # and pure, because it is the whole of what this tool tells the service about a
      # run and a test can hold it still without a corpus.
      def self.run_payload(record)
        {
          "repo_url" => record.repository,
          "commit" => record.commit,
          "from_version" => record.from_version,
          "to_version" => record.to_version,
          "image" => record.image,
          "verdict" => record.verdict,
          # The *suite's* outcome, not the step's: it is what makes "failed after the
          # upgrade" mean something, and it is deliberately a different field.
          "baseline_verdict" => baseline_verdict(record),
          "note" => record.why,
          "patch" => record.patch,
          # A step is one process run; the record carries when it was written and the
          # commands carry their own durations, so a start time invented here would be
          # a second, disagreeing answer to a question already answered.
          "started_at" => nil,
          "finished_at" => record.recorded_at,
          "commands" => record.stages.map { |stage| command_payload(stage) },
          "refusals" => refusal_payloads(record)
        }
      end

      def self.baseline_verdict(record)
        return nil if record.baseline.nil?

        record.baseline.ok? ? "passed" : "failed"
      end

      def self.command_payload(stage)
        {
          "argv" => stage.command,
          "stage" => stage.stage,
          "exit_code" => stage.exit_code,
          "duration_ms" => (stage.seconds.to_f * 1000).round,
          "stdout_tail" => stage.output_tail,
          "stderr_tail" => nil
        }
      end

      # Two kinds of thing a step carried and did not do, kept apart by which side
      # refused: an applier entry is a change this ladder *does* rewrite and whose line
      # did not match, a plan entry is a change the ladder says needs a person. This is
      # the list the automation-coverage figure counts, which is why the subject travels
      # with each one — a count of refusals that cannot name them says how much is left to
      # do and not what.
      #
      # What is *not* sent is this tool's word for which side refused. It used to fill
      # `kind` and `source` with `"applier"` and `"plan"`, and the service reads those two
      # fields as the ladder's own vocabulary — `kind` is "the kind of change, as the
      # ladder names it" and `source` is the chapter of the guide (`Upgrade::Refusal`)
      # — so a refusal arrived describing the wrong thing in a field that meant something
      # else. The distinction is not lost: the service derives it from the subject against
      # the ladder's own rewrites (`upgrades.py`), which is the only side that owns it.
      def self.refusal_payloads(record)
        record.refused.map do |refusal|
          note = refusal.reason.to_s
          note = "#{note}; found: #{refusal.found}" if refusal.found
          {
            "subject" => (refusal.subject || refusal.text.to_s.split(" ").first || refusal.path).to_s,
            "kind" => refusal.kind,
            "replacement" => refusal.replacement,
            "note" => [refusal.note, note].compact.reject { |text| text.to_s.empty? }.uniq.join(" — "),
            "source" => refusal.source,
            "path" => refusal.path,
            "line" => refusal.line
          }
        end + record.decisions.map do |decision|
          {
            "subject" => decision.subject.to_s,
            "kind" => decision.kind,
            "replacement" => decision.replacement,
            "note" => decision.reason,
            "source" => decision.source,
            "path" => decision.path,
            "line" => decision.line
          }
        end
      end

      # Only `run_payload` calls these three, so they are private class methods rather than
      # public ones — the payload's *shape* is the contract, the builders are not.
      private_class_method :baseline_verdict, :command_payload, :refusal_payloads

      private

      def run_id
        @run_id ||= "#{Time.now.utc.strftime("%Y%m%d%H%M%S")}-#{Process.pid}"
      end
    end
  end
end
