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

      # How many times the pin may be re-run with the gems bundler named. Each round is a
      # resolve, and bundler names what it could not leave alone, so a real application needs
      # one or two; the cap is what keeps a pathological cascade from spending a walk.
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
        preflight = preflight_stage(stages)
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
        boot(stages)
        @suite = suite(stages)

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
      def preflight_stage(stages)
        corpus = @corpus || Corpus.new(base: @api)
        result = Preflight.new(root: @worktree.root, corpus: corpus).run
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
        Preflight::Result.new(repairs: [], decisions: [], notes: [e.message])
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
        @out.puts("  install: bundle install#{machine.respond_to?(:era) && machine.era ? " (ruby #{machine.era})" : ""}") if @out
        stage = command(Record::BUNDLE, %w[bundle install], chdir: @worktree.root,
          env: @worktree.bundle_env, machine: machine)
        stages << stage
        stage
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
      # What the routing says is treated exactly as the digest's entries are: a declaration
      # this tool can rewrite is rewritten and recorded, and everything else is a decision.
      # `replace` and `remove` are deliberately *not* acted on here — the preflight owns the
      # digest's moves, and applying one twice would rewrite a line that already moved.
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
        route.fetch("gems", []).each do |gem|
          case gem["verdict"]
          when "move"
            applied << apply_gem_change(gem, step)
          when "replace", "remove"
            # The preflight applies the digest's *mechanical* entries, and it must not apply
            # the others: an entry that can only move once Rails itself has moved is exactly
            # the one that blocks the pin when the move is finally made — measured on the
            # first real walk, where `simple_form 3.0.0.rc` (the git pin) requires
            # `actionpack < 4.1` and `bundle update rails` answered "could not find compatible
            # versions for actionpack". This pass runs after the baseline, at the rung where
            # the move is being made, so it is where that entry belongs.
            next withdraw_decision(gem) if already_applied?(gem)

            applied << apply_gem_change(gem, step)
          when "blocked", "unknown"
            @decisions << routing_decision(gem)
          end
        end
        applied = applied.compact

        stages << Record::Command.new(
          stage: Record::GEMS,
          command: "gems: #{route.dig("counts", "move")} move(s), " \
                   "#{route.dig("counts", "unknown")} unknown, #{applied.size} applied",
          ran: true, exit_code: 0, seconds: 0.0,
          output_tail: (route.fetch("gems", []).reject { |gem| gem["verdict"] == "keep" }.map { |gem|
                          heading = "#{gem["verdict"].upcase} #{gem["name"]} #{gem["version"]}"
                          heading += " -> #{gem["to"]}" if gem["to"]
                          heading += " -> #{gem["replacement"]} #{gem["requirement"]}" if gem["replacement"]
                          "#{heading}: #{gem["reason"] || gem["note"]}"
                        } + [route.fetch("next_step", "").to_s]).first(20).join("\n")
        )
        @out.puts("  gems: #{route.dig("counts", "move")} move(s), " \
                  "#{route.dig("counts", "unknown")} unknown — #{applied.size} applied") if @out
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
        return nil if after == line

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

      # One research pass over the gems the routing could not answer about, and the routing
      # asked again. Both halves are reported in the stages the caller writes: a pass that
      # fetched ten documents and closed nothing is a fact about the index, and a walk that
      # hid it would look like a walk that had nothing to fetch.
      def research(corpus, route, ruby:, rails:, stages:)
        unknown = route.fetch("gems", []).select { |gem| gem["verdict"] == "unknown" }
        pass = @research || Research.new(corpus: corpus, cache: File.join(@home, "index"), out: @out)
        result = pass.run(unknown.map { |gem| [gem["name"], gem["version"]] })
        stages << Record::Command.new(
          stage: Record::RESEARCH, command: "research: #{result}",
          ran: true, exit_code: 0, seconds: 0.0, output_tail: result.details.first(20).join("\n")
        )
        corpus.route(ruby: ruby, rails: rails, lockfile: lockfile_text)
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
        @tests.machine_test_env.merge(@worktree.bundle_env).merge(@suite_env)
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
            ran: false, exit_code: nil, seconds: 0.0, output_tail: "")
          # The plan's half is still this step's half: a repository with no Ruby source
          # this tool reads has not thereby moved, and the changes no machine may make
          # are exactly the ones a person still has to.
          return [[], [], decisions_for(step, nil)]
        end

        corpus = @corpus || Corpus.new(base: @api)
        scan = corpus.scan(from: step["from_version"], to: step["to_version"], files: files)
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
        rules = Rewrites.apply(scan["manual"] || [])
        inert = Rewrites.inert(step["changes"] || [])
        # A rule that *knows* the change and would not touch this line is the most specific thing
        # anything downstream can be told, so it is kept rather than counted: the repair agent's
        # brief carries it (`Repair#prompt_for`).
        @unapplied_rules = rules.left
        result = @applier.new(@worktree.root).apply((scan["edits"] || []) + rules.edits)
        decisions = decisions_for(step, scan).reject do |decision|
          rules.applied.include?(decision.subject.to_s)
        end
        stages << Record::Command.new(
          stage: Record::APPLY,
          command: "apply #{scan["edits"].to_a.size} edit(s) to #{files.size} scanned file(s)",
          ran: true, exit_code: 0, seconds: 0.0,
          output_tail: apply_summary(result, decisions, rules, inert)
        )
        [result.applied, result.refused, decisions]
      end

      # What the apply stage's tail says: the counts, then what this tool's own rules did, then the
      # rules that name no change in this rung. The last two are evidence rather than decoration —
      # a rule that applied nothing and a rule whose change has left the ladder look identical from
      # the outside, which is the shape `AGENTS.md` keeps paying for.
      def apply_summary(result, decisions, rules, inert)
        parts = ["applied #{result.applied.size}, refused #{result.refused.size}, " \
                 "#{decisions.size} change(s) need a decision"]
        parts << "#{rules.edits.size} by this tool's own rules (#{rules.applied.uniq.join(", ")})" if
          rules.edits.any?
        parts << "#{inert.size} rule(s) name no change in this rung (#{inert.join(", ")})" if
          inert.any?
        unless rules.left.empty?
          parts << "#{rules.left.size} line(s) a rule knows and would not touch " \
                   "(#{rules.left.uniq.join(", ")})"
        end
        parts.join("; ")
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
      def decisions_for(step, scan)
        found = (scan && scan["manual"] || []).group_by { |entry| entry["subject"].to_s }
        carried = (step["changes"] || []).reject { |change| change["automatic"] }

        located = carried.map { |change| decision(change, found[change["subject"].to_s]&.first) }
        # And a manual call site the plan does not name is a change nobody has written
        # into the ladder, which is the most useful thing a refusal can say. Dropping it
        # because the digest has no row for it would hide exactly that.
        unplanned = found.keys - carried.map { |change| change["subject"].to_s }
        located + unplanned.flat_map { |subject| found[subject].map { |entry| decision(nil, entry) } }
      end

      # One decision, from whichever side named the change — the plan when it did, the
      # scan's own entry otherwise. The reason joins both notes when they are two, in the
      # order a reader wants them: what the guide says the change is, then what this
      # application's line looks like.
      def decision(change, entry)
        Record::Decision.new(
          path: entry && entry["path"], line: entry && entry["line"],
          subject: ((change && change["subject"]) || entry["subject"]).to_s,
          reason: [change && change["note"], entry && entry["note"]]
                  .compact.reject { |note| note.to_s.empty? }.uniq.join(" — "),
          kind: (change && change["kind"]) || (entry && entry["kind"]),
          replacement: (change && change["replacement"]) || (entry && entry["replacement"]),
          source: (change && change["source"]) || (entry && entry["source"])
        )
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
        pin(stages)
        nil
      end

      # **The pin is a conversation with the resolver, and `--conservative` is why.** A rung
      # moves Rails and not the world: the lighthouse proved what the alternative costs — the
      # application pinned rake 10.0.4, the unconstrained `bundle update rails` resolved 12.3.3
      # (railties 4.1 only asks `rake >= 0.8.7`), and Rails 4.1's own `rails:update` then died
      # on `Rake::Application#last_comment`, which rake 11 removed. So the first attempt names
      # the framework's own gems and keeps everything else where the application put it.
      #
      # **A locked gem the move *requires* is then named by bundler itself.** Its message is
      # the authority on what the resolve could not leave alone — "could not find compatible
      # versions for gem i18n: rails (= 4.1.0) ... activesupport (= 4.1.0) ... depends on i18n
      # (>= 0.6.9, ~> 0.6)" — a fact no compatibility matrix here could have, because it is the
      # resolver's own answer for this application. Each round unlocks exactly the gems named,
      # so `i18n` and `coffee-rails` move while `rake` stays at 10.0.4. The rounds are capped
      # because a cascade is finite but a walk is not: every round adds at least one gem, and
      # the cap is what stops a pathological one from spending the step.
      def pin(stages)
        gems = pin_gems
        PIN_ROUNDS.times do
          stage = command(Record::PIN, ["bundle", "update", *gems, "--conservative"],
            chdir: @worktree.root, env: @worktree.bundle_env)
          stages << stage
          return stage if stage.ok?

          named = stuck_gems(stage.output_tail) - gems
          return stage if named.empty?

          gems += named
        end
        stages.last
      end

      # The gems bundler said it could not leave alone, as its own message names them. Read
      # rather than guessed: the resolver knows this application's requirement graph, and a
      # list of "gems that usually have to move with Rails" would be a second, worse answer.
      # Names the lockfile does not pin are dropped — nothing outside it can be unlocked.
      def stuck_gems(text)
        quoted = text.to_s.scan(/could not find compatible versions for gem "([^"]+)"/).flatten
        bare = text.to_s.scan(/could not find compatible versions for gem ([\w.-]+)/).flatten
        ((quoted + bare).uniq & @lockfile.specs.keys)
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
        stages << command(Record::RAILS_UPDATE, runner + [task], chdir: @worktree.root,
          env: application_env)
        @adopted, @conflicts = self.class.adopt_added_only(@worktree.root, before)
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

      def command(stage, argv, chdir:, env: {}, machine: nil)
        runner_machine = machine || @machine
        argv, env = runner_machine.command(argv, chdir: chdir, env: env) if runner_machine
        @runner.run(argv, stage: stage, chdir: chdir, env: env, stdin: File::NULL)
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
        record.write(@record_dir) if @record_dir
        record
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
