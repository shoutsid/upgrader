# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "shellwords"

module Agents
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

      # **A browser that has stopped making progress is a hang, not a slow suite.** The project's
      # resolved `suite_hang` class chooses the bound; the step takes the smaller of it and its own
      # timeout, so a project can tighten the bound and cannot turn a kill into a pass. `ask` and
      # `deny` leave the deployment's timeout alone.
      SUITE_HANG_SECONDS = {
        "stop_after_15m" => 15 * 60,
        "stop_after_30m" => 30 * 60,
        "stop_after_60m" => 60 * 60
      }.freeze

      # What a scan will carry. The service bounds a request body and an application's
      # source is not a payload, so the walk sends the files a plan is about — and says
      # in the record when it stopped, rather than sending a slice and calling it done.
      SCAN_SUFFIXES = %w[.rb .rake .erb .yml .ru].freeze
      SCAN_SKIP = %w[.git vendor node_modules tmp log public/assets storage coverage].freeze
      # **The scan route's own file bound, not a larger one of this client's.** `POST /api/rails/scan`
      # refuses more than `Upgrade::Scanner::MAX_FILES` (200) before it reads the body, and a step
      # that sent 232 files for a 19wu rung received a 422 at the scan stage — the run was never
      # recorded, so a passing move looked like a client crash. The byte bound is below the route's
      # 512 KiB for the same reason: a request this client builds must be one the route accepts.
      MAX_SCAN_FILES = 200
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

      # **The browser packages, and the three paths that go with them.** `chromium` is Debian's
      # package — the one a live-era image installs at build time and an archived era's step installs
      # from its frozen archive — and its launcher sources `/etc/chromium.d/*` before exec'ing the
      # browser, which is why the walk's answer can be a file in the machine rather than a line in the
      # application.
      BROWSER_PACKAGES = %w[chromium chromium-driver].freeze
      CHROMIUM_FLAGS = "/etc/chromium.d/agents"
      CHROMIUM_FLAGS_VALUE = %(CHROMIUM_FLAGS="$CHROMIUM_FLAGS --no-sandbox --disable-dev-shm-usage")
      SYSTEM_DRIVER = "/usr/bin/chromedriver"

      # **The browser an era image pins, and the two names a step points at it.** A live Debian's
      # `chromium` is whatever the repository served that morning, and the protocol an application's
      # test stack speaks does not move with it — measured on `ohana-api`, 19 `:js` failures on
      # bookworm's Chromium 156 and none on 120, same tree and same bundle. The image keeps both
      # browsers and the project declares which it is measured on (`toolchain.chrome`); these are
      # the paths the image's own build writes (see `images/Dockerfile`).
      BROWSER_BINARY = "/usr/bin/chromium"
      # The archive's own directory name, because chromedriver's finder globs `/opt/*/chrome` and a
      # browser unpacked to that name was `execvp`'d as a directory — see `images/Dockerfile`.
      PINNED_BROWSER = "/opt/agents-browser/chrome-linux64/chrome"
      PINNED_LAUNCHER = "/usr/local/bin/agents-browser"
      PINNED_DRIVER = "/opt/agents-browser/chromedriver"

      # **The headless browser an old poltergeist suite selects by itself.** The image installs it
      # (see `images/Dockerfile`); the application's own `spec_helper` looks for this executable
      # and chooses `:poltergeist` when it is on PATH. 19wu is the measured case: without it the
      # suite falls back to Firefox, and 27 `:js` examples fail with `Could not find Firefox
      # binary` before the move is measured.
      PHANTOMJS_BINARY = "/usr/local/bin/phantomjs"


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
        research: nil, env: ENV, repair: nil, force: false, suite_env: nil, services: nil,
        progress: nil, pause: nil, stack: nil, project: nil, control: nil
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
        # Whether this step put a kept tree back to where its project says the walk is. It is not
        # `@force`: that is an operator's "walk this rung again", while this is a tree that belongs
        # to an earlier walk and settles nothing about the moves this one is about to make.
        @rewound = false
        # Where a retry waits. Injected so the suite does not spend the backoff it asserts.
        @pause = pause || ->(seconds) { sleep(seconds) }
        # The stack pack: what a release changes and how a command is spelled for it.
        # The project declares which pack by name; until the entry points are wired to the
        # declaration, the Rails pack is what a step runs.
        # The project this step walks, when the caller declared one. It supplies the suite, the
        # environment *names* the suite reads and the stack; the entry points that have a
        # declaration pass it (the design notes call this the adapter).
        @project = project
        # **The account/project policy the service resolved for this walk.** A declaration written
        # before the field existed is empty, which leaves the deployment's own behaviour; the only
        # values this build acts on are the suite-hang bound and the browser driver, and both are
        # bounded by the class vocabulary the service publishes.
        @decision_policy = project&.decision_policy || {}
        hang = SUITE_HANG_SECONDS[@decision_policy["suite_hang"].to_s]
        @suite_timeout = [@suite_timeout.to_i, hang].min if hang
        # **The operator's stop switch, checked at every command boundary.** `nil` is a hand-run
        # step, which no deployment switch controls — a stop on the site admin is about the walk,
        # not about a person asking what a move costs — and `serve` always passes one.
        @control = control
        @stack = stack || Stacks.for(project&.stack || "rails")
        # **The application's own environment, when the deployment knows it.** A repository
        # that carries no secrets is the ordinary case, not the exception: this walk's first
        # real application reads `ENV["RAILS_SECRET_TOKEN"]` and that value lives in a
        # git-ignored `config/application.yml` (figaro), so a fresh clone cannot boot its own
        # suite. Nothing here invents a value — the file is the operator's, its lines are
        # `KEY=VALUE`, and they are merged into every command that runs *the application*
        # (the suite, the database preparation, the update, the boot) and never into the
        # bundle or the machine commands, which are this tool's own.
        @suite_env = read_env_file(suite_env)
        # **Where the loop says what it is doing while it does it.** A step can be forty minutes
        # of a bundle resolve and a suite, and the record of it only exists at the end — so
        # without this the only live signal is this container's stdout. See `Progress` for why it
        # is a file rather than an endpoint.
        @progress = progress || Progress.new(home: @home, out: @out) || Progress.new(home: home, out: out)
      end

      def run
        # **A stop lands before the first command too.** The clone is a network read, and a step
        # started against a stopped deployment has spent it for nothing.
        @control&.check!
        stages = []
        @applied = []
        @refused = []
        # **`app:update` may not run at all**, and the database re-preparation after it asks what it
        # adopted. A step whose application has no update runner (the method returns before adopting)
        # crashed here with `undefined method 'grep' for nil` — measured on the second declaration,
        # which is exactly the shape the lighthouse could not show: an application modern enough that
        # the update task is not the one this stack runs.
        @adopted = []
        @decisions = []
        @repairs = []
        @checks = []
        @prepare_checks = []
        @commits = []
        # **The rules the project declared, and the ones that fired.** `fired_rules` is what the
        # run body's existing `decisions` field carries, so the service can retire a rule a failed
        # run falsified; `expected_rules` are the `expect` rules still waiting to see whether this
        # run's failure is the one they name. `skipped_keys` filters the plan and the scan.
        @fired_rules = []
        @expected_rules = []
        @skipped_keys = []
        @plan_changes = []
        @app_update_skipped = []
        @base_commit = nil
        @record_commit = nil
        # The digest entries the preflight held for this rung, filled in when it runs and empty before
        # it. The pin's naming rule reads the Gemfile (`declared_gems`) rather than this list, so which
        # stage moved a line does not change the answer.
        @deferred = []
        @out.puts("step: #{@repository} -> #{@to}") if @out
        # The site admin's view of this step from the moment it starts. The move is not known until the
        # lockfile is read, so what is announced here is the repository and the target it is walking
        # to; every stage after this one announces itself with the move filled in.
        @progress.cycle(note: "planning #{@repository} -> #{@to}", repo: @repository)

        # What finished runs left behind, reclaimed before this one adds to it: the home is the
        # bind mount the step's own container is given, and its size is paid at `docker run`.
        Source.prune_bundles(home: @home, out: @out)

        prepared = prepare(stages)
        record = prepared if prepared.is_a?(Record)
        return finish(record) if record

        @worktree, @lockfile, pinned = prepared
        @from = pinned.version

        # **Nothing to move is not a run.** A target that names the release the tree is already on
        # has no rung to walk — the loop asked the ladder, was refused with "`8.1.0` and `8.1.0` are
        # the same Rails release", and *recorded that refusal* every ten minutes: eight rows saying a
        # finished walk is finished, and a corpus whose queue list grew while nothing was learnt
        # (see `docs/design-notes.md`). `nil` is this step's answer for
        # "nothing ran", which the loop reports as idle; the target's own `done` is what says it is
        # complete, and a passed rung that failed to *deliver* is the delivery queue's work, not a
        # reason to walk it again.
        if @to.to_s == @from.to_s
          @out.puts("  already at #{@to}: there is no rung to walk") if @out
          return nil
        end

        # **A move inside one minor is maintenance, not a rung.** A patch checkpoint pins a release
        # the ladder has no chapter for, so there is no plan to fetch and no source to scan: the
        # suite is the evidence, and the pipeline is deliberately the part of a rung that measures
        # rather than the part that changes. `@rung_to` is the move here because no plan will set
        # it and the progress panel must not name the loop's destination as the rung.
        #
        # A checkpoint behind the lockfile is not maintenance; it is a stale feed. Pinning the
        # older release would make the tree and the project row disagree, and `advance!` would
        # refuse the rewind after a "passed" run. Refuse it and let the service replan instead.
        if same_minor?(@from, @to)
          unless checkpoint_ahead?
            return finish(Record.refused(
              repository: @repository, from_version: @from, to_version: @to,
              why: "The next checkpoint #{@to} is behind the lockfile's #{@from}. Re-read the " \
                   "project path before walking it; this step will not pin a downgrade.",
              commit: record_commit, worktree: @worktree&.root
            ))
          end
          @rung_to = @to
          return patch_run(stages)
        end

        # The plan comes from the service and nowhere else: this tool keeps no copy of
        # the ladder, so a move it cannot ask about is a move it cannot make.
        step = planned(stages)
        return finish(step) if step.is_a?(Record)

        # **The plan says which minor moved; the checkpoint says which patch is installed.** A
        # latest-patch checkpoint names `7.1.6` while the ladder's chapter is the move to `7.1.0`,
        # so the step's own target becomes the checkpoint and the plan's version travels as
        # `plan_to`. Every stage downstream — the pin, the commits, the record and the branch — then
        # reads one release, and it is the one a person approved.
        step = checkpoint_step(step)
        # **The plan names the rung it planned from; the tree names the release it is on.** A project
        # at 4.1.16 is planned by the service as a move out of the 4.1 rung, so the plan's first
        # `from_version` is `4.1.0` — but the branch below this checkpoint is
        # `agents/upgrade-4.1.16`, and a record that carried the rung made `Publish` look for a
        # base that the previous checkpoint never created and fall back to the default branch. The
        # lockfile's release is the application fact, so it is the one the move records.
        step = checkpoint_from(step)

        @out.puts("  step: #{step["name"]} (#{step["from_version"]} -> #{step["to_version"]}), " \
                  "requires Ruby #{step["requires_ruby"] || "unstated"}") if @out
        # **The rung's own target, not the loop's.** `@to` is where the *walk* is going (8.1.0), so a
        # panel fed from it said "4.1.0 -> 8.1.0" while the step was moving to 4.2.0 — the move a
        # reader is asking about is the one happening now.
        @rung_to = step["to_version"]

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
        apply_preflight(stages, step)

        # **What this project has already decided, applied before anything is measured.** A decision's
        # effect is how this application *is*, not part of the move: it runs on every walk, in the
        # declared order, and the baseline below measures the tree with it in force — which is what
        # makes a red suite after the move attributable to the move. It sits beside the preflight for
        # the same reason: both are preconditions of measuring, not changes the rung is judged for.
        # Each edit carries `origin: decision:<id>`, so a reader can tell it from the ladder's own.
        decisions_stage(stages, step)
        checkpoint("preflight and accepted decisions")

        # **The era is the oldest the rung's floor allows, and the ledger is not a starting point.** The
        # ledger is keyed per *repository*, so a walk that climbs keeps a hint that is always at or below
        # the next rung's floor and therefore never changes the answer — and a walk *re-entered from below*
        # inherits the era of the rungs above it, which is how the 6.0 rung came to run on 2.7 for a floor
        # of 2.5 and to be `unverified` on a red baseline. What the module's own docstring calls a starting
        # point is what the *application* states (a `ruby` line, a `RUBY VERSION`), and `Interpreters`
        # already reads those.
        choice = choose_machine(stages, step)
        return finish(choice) if choice.is_a?(Record)

        @machine, install = choice
        @out.puts("  interpreter: #{@machine.interpreter}" \
                  "#{@machine.image.to_s.empty? ? "" : ", image #{@machine.image}"}") if @out
        return finish(install_record(install, stages)) unless install.ok?

        # The browser, if this project's declaration names one, on the machine that installed the
        # bundle rather than on every candidate the probe tried.
        prepare_browser(stages, @machine)

        # The services the suite expects, started before anything is measured, and a
        # required stage: a suite that ran without its database failed for a reason nobody
        # reading the record could see.
        services = services_stage(stages)
        if services && !services.ok?
          verdict, why = Record.verdict(baseline: nil, suite: nil, stages: stages)
          return finish(build(step, stages, verdict, why))
        end

        javascript_stage(stages)
        database_stage(stages)
        assets_stage(stages)
        @prepare_checks = prepare_checks_stage(stages)
        style_baseline(stages)

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
            rerun: -> { install_after_repair(stages); @baseline = run_suite(stages, Record::BASELINE) })
          @baseline = repaired || @baseline
          checkpoint("repair the baseline") if repaired
        end

        applied, refused, decisions = apply(stages, step)
        checkpoint("apply mechanical rules")
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

        checkpoint("pin Rails and move gems")
        update(stages)
        # **A repair waits for the files it is about.** `app:update` has written the release's
        # generated files; now the post effects may change them, and the suite below measures the
        # result. Applying these before the baseline was how a repair could turn a green starting
        # tree red and make the move look unmeasurable.
        decisions_stage(stages, step, phase: "post", stage: Record::DECISIONS_POST)
        migrate_after_update(stages)
        checkpoint("run app:update")
        # **The first asset stage proves the baseline's environment, not the move's.** It
        # runs before the pin, on the application's old bundle. Measured on the 4.1 rung:
        # the old `jquery-rails 2.2.1` shipped jQuery UI, the pin resolved `3.1.5` (which
        # removed it), the application's `application.js` still required `jquery-ui`, and
        # the post-pin `assets:precompile` raised `Sprockets::FileNotFound` — while the
        # run passed, because nothing compiled assets after the pin. This stage is that
        # compile, and it is deliberately after `app:update` as well, so it sees the
        # assets initializer the release generated.
        verify_assets_stage(stages)
        style_stage(stages)
        checkpoint("format the application")
        @boot = boot(stages)
        # **A boot failure is attributable to the move in exactly the way a red suite is, and it
        # reaches the agent before the suite does.** Measured on several of the first walks: the
        # application cannot load its own classes, so the suite that follows fails for the boot's
        # reason, and repairing the suite would be measuring a tree that never booted. The loop's
        # premise — a green baseline before, a red subject after — is unchanged; only the subject
        # is the boot command rather than the suite.
        stale_lock(stages)
        repair(stages, step, subject: @boot,
          rerun: -> { install_after_repair(stages); @boot = boot(stages) })
        # **The repair's own boot can be the first one that reaches the stale lock.** Measured on
        # 19wu's 4.1.16 rung: the first boot died on polyamorous, the repair fixed that, and the
        # second boot answered `Could not find gem 'ransack (~> 1.4.1)'` — after the one
        # `stale_lock` call had already run. The rule has to run on the boot the repair produced as
        # well, or the move goes to the suite with a Gemfile line the lock never installed.
        stale_lock(stages)
        missing_gems(stages)
        @suite = suite(stages)

        # **A red suite is repaired from the application's own facts before anyone is asked to
        # look at it.** The failures a Rails move surfaces in templates are route call sites the
        # application already had wrong: a helper its router does not declare, or a declared helper
        # given a nil segment. `TemplateRepairs` derives both from the failure and the route table,
        # `Applier` writes one checked line at a time, and the suite is run again — the execution
        # gate is what makes the repair a fact rather than a claim. A step still red afterwards
        # goes to the agentic repair (if the deployment has one) exactly as it did before.
        mechanical_repairs(stages)

        # **The new defaults, stepped, and only after the move's own suite passed.** A red run here
        # is then about the toggle and never about the move, which is what makes "revert this one"
        # the right answer rather than a guess. Off unless a number says otherwise: every toggle is
        # a suite run, and a deployment that has not decided to spend that must not have it spent.
        step_defaults(stages, step)

        # **The agentic half, and the last thing before the verdict.** A step that ran a green
        # baseline and a red suite has a failure attributable to the move, which is what makes
        # repair a measurement rather than a hope; the attempt(s) and the suite they were
        # followed by are stages, so the record says how the rung was reached. A boot that is
        # still red explains the suite, and repairing behind it measures a tree Rails never
        # loaded — the boot's own attempt already had its chance. A patch rung has no boot
        # stage at all, and the suite is the only subject there is.
        if @boot.nil? || @boot.ok?
          repair(stages, step, subject: @suite,
            rerun: -> { install_after_repair(stages); @suite = run_suite(stages, Record::SUITE) })
        end

        # **The rest of the gate, after the suite and the repairs it needed.** A check that ran
        # before a repair would judge a tree the suite never saw. The suite is not run again here:
        # it is the first check, and its result is `@baseline`/`@suite`.
        @checks = Array(@prepare_checks) + checks_stage(stages)
        # Anything a default toggle or a repair left uncommitted belongs to this rung too; the
        # delivered head must be the tree the suite measured, not the commit before its last edit.
        checkpoint(nil)
        verdict, why = Record.verdict(baseline: @baseline, suite: @suite, stages: stages,
          checks: @checks)
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

      # The local files a fresh clone is missing, copied from the repository's own examples, and a
      # stage whether or not anything was copied: a reader of a record should be able to tell "this
      # tree had its own configuration" from "this tree was configured from the examples".
      def bootstrap_local_config(stages)
        seeds, failures = Bootstrap.seed(@worktree.root, out: @out)
        return if seeds.empty? && failures.empty?

        stages << Record::Command.new(stage: Record::BOOTSTRAP,
          command: "local configuration from the repository's examples",
          ran: failures.empty?, exit_code: failures.empty? ? 0 : nil, seconds: 0.0,
          output_tail: (seeds + failures).map(&:sentence).join("\n"))
      end

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
        @worktree = @source.worktree(@repository, ref: @ref, home: @work || @home, run: run_id,
          reuse: @reuse)
        # **Generated paths are ignored before anything can add them.** The first
        # `assets:precompile` runs before the baseline, and the first checkpoint comes
        # after it; without this line the checkpoint's `git add --all` carries the build
        # output into the branch. `Checkpoint.dirty?` and `commit` call the same method so
        # a path this step generated cannot make the tree look dirty either.
        Checkpoint.ignore_build_outputs(@worktree.root)
        if @reuse
          # **A clean tree is not proof that the last step finished.** Concern commits move HEAD,
          # so a process killed after one leaves a clean tree sitting on a half-move. The marker
          # is the commit the rung started from; a tree at any other commit is put back before a
          # lockfile is read.
          base = Checkpoint.base(@worktree.root)
          if base && Checkpoint.resolvable?(@worktree.root, base)
            current = Checkpoint.head(@worktree.root).first.to_s
            if current != base || Checkpoint.dirty?(@worktree.root)
              Checkpoint.reset(@worktree.root, to: base)
              @out.puts("  working copy: reset to #{base[0, 8]} — a step was interrupted here") if @out
            end
            @base_commit = base
            @record_commit = base
          else
            if Checkpoint.dirty?(@worktree.root)
              Checkpoint.reset(@worktree.root)
              @out.puts("  working copy: reset to #{Checkpoint.head(@worktree.root).first.to_s[0, 8]} " \
                        "— a step was interrupted here") if @out
            end
            @base_commit = Checkpoint.head(@worktree.root).first.to_s
            @record_commit = @worktree.commit.to_s
            @record_commit = @base_commit if @record_commit.empty?
            Checkpoint.remember_base(@worktree.root, @base_commit)
          end
        else
          @base_commit = Checkpoint.head(@worktree.root).first.to_s
          @record_commit = @worktree.commit.to_s
          @record_commit = @base_commit if @record_commit.empty?
        end
        # **The clone is configured before anything reads it.** `config/database.yml` decides
        # whether the services stage starts a database at all, and an application's own settings
        # file decides whether `bin/rails` can boot; both are git-ignored and shipped as examples,
        # and the rule that creates them is `Bootstrap`'s. It sits after the reset above so a tree
        # put back to its base is seeded again, and before the lockfile read for no particular
        # reason other than that everything after this point may run an application command.
        bootstrap_local_config(stages)
        @lockfile = Lockfile.read(@worktree.root)
        pinned = @lockfile.rails
        pinned = rewind_to_declared(pinned) if @reuse
        unless pinned
          return Record.refused(
            repository: @repository, commit: record_commit, worktree: @worktree.root,
            from_version: "unknown", to_version: rung_to,
            why: "no Rails release is pinned under #{@worktree.root}: neither the meta-gem " \
                 "nor any framework component is in Gemfile.lock, so there is nothing to step from"
          )
        end
        [@worktree, @lockfile, pinned]
      rescue Source::Failed => e
        # **A source that cannot be read is not a fact about the move.** A clone that could not
        # resolve the host, a path that is not a git tree — the environment failed to make the
        # measurement, and `unverified` is the verdict that says so: it is retried and spends no
        # attempt. The first queue-driven run recorded a DNS failure as `refused`, which settled the
        # move for good; a refused step is a fact about the ladder, and this one was about the
        # network.
        Record.unverified(repository: @repository, from_version: "unknown", to_version: rung_to,
          why: e.message)
      rescue Lockfile::Missing, Lockfile::Unreadable => e
        Record.refused(repository: @repository, from_version: "unknown", to_version: rung_to, why: e.message)
      end

      # **A walk's position is the project's, not the tree's.** A kept tree is one repository's
      # and outlives the project that walked it: connecting the same repository again starts a new
      # project at the release the application is on, while the tree still sits at the top of the
      # earlier walk. Planning from the tree asked the ladder for `8.1.4 -> 4.0.13`, which it
      # rightly refused — and a refusal is a fact about the move, so the queue row settled and the
      # new project could never move again. The declaration wins, because it is what the person
      # connected; the tree is put back to the commit its walk began at.
      #
      # The moves the old tree settled above that commit are not this walk's history either, so
      # `@rewound` tells `settled_entry` to re-derive them. Without it every rung would answer
      # "already settled", the project's `from_version` would never advance, and the loop would
      # report a finished walk over an application nobody upgraded — finished and stuck look
      # identical from outside, which is the failure this project keeps finding.
      def rewind_to_declared(pinned)
        declared = @project&.from.to_s
        return pinned if declared.empty? || pinned.nil?
        return pinned unless version_ahead?(pinned.version, declared)

        start = Checkpoint.origin(@worktree.root).to_s
        return pinned if start.empty? || start == @base_commit

        Checkpoint.reset(@worktree.root, to: start)
        Checkpoint.remember_base(@worktree.root, start)
        @base_commit = start
        @record_commit = start
        @rewound = true
        @out.puts("  working copy: put back to #{start[0, 8]} — the project starts at #{declared}, " \
                  "and this tree had been walked to #{pinned.version}") if @out
        # **The parse has to follow the reset, or the pin plans from a tree that is not there.**
        # `prepare` read this lock before the rewind, and a lock is what says which gems move
        # with the framework: measured on the first real reconnect, the tree sat at 4.1.0 and the
        # project at 4.0.0.rc1, `pin_gems` asked the 4.1.0 parse for the gems pinned at rc1, got
        # none, and the resolve kept `activemodel` at rc1 in its snapshot while Rails moved to
        # 4.0.13 — so the patch rung failed with `could not find compatible versions`.
        @lockfile = Lockfile.read(@worktree.root)
        @lockfile.rails
      rescue Lockfile::Missing, Lockfile::Unreadable => e
        @out.puts("  working copy: put back, but its Gemfile.lock could not be read: #{e.message}") if @out
        pinned
      end

      def version_ahead?(version, other)
        Gem::Version.new(version.to_s) > Gem::Version.new(other.to_s)
      rescue ArgumentError
        false
      end

      # The ledger entry for this move, and whether it is settled *for the machine that
      # would run it now*. The expected machine is computed cheaply — the era the selection
      # would try first, or this process — and never by starting a container: the check
      # exists to avoid spending a cycle, and a probe here would spend most of one.
      def settled_entry(step)
        return [nil, false] unless @ledger

        entry = @ledger.find(repo: @repository, commit: record_commit,
          from_version: step["from_version"], to_version: step["to_version"])
        return [nil, false] unless entry
        if @force
          @out.puts("  ledger: #{entry.verdict} for this move is set aside (--force)") if @out
          return [entry, false]
        end
        return [entry, false] if @rewound

        settled = @ledger.settled?(
          repo: @repository, commit: record_commit,
          from_version: step["from_version"], to_version: step["to_version"],
          machine: expected_machine(step, entry)
        )
        [entry, settled]
      end

      # The machine a step would run on, as the stamp the ledger compares. Deliberately the
      # *first candidate* rather than the one that would be probed into: the stamp's job here
      # is to answer "is what is already recorded still the machine this step would get", and
      # first candidate is now the oldest era the rung's floor allows, the same rule
      # `choose_machine` applies — so an entry recorded on an era this rung would no longer get
      # is re-opened, which is what the stamp exists to say.
      def expected_machine(step, entry)
        return @machine.stamp if @machine
        return native_stamp unless docker_mode?

        candidates = candidates_for(step)
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
            repository: @repository, commit: record_commit, worktree: @worktree.root,
            from_version: @from, to_version: rung_to,
            why: "the service returned no step for #{@from} -> #{@to}: #{payload["next_step"]}"
          )
        end
        # **The rung's changes travel with the record.** A failed step is filed against the change
        # it names (`Filing`), and the component/subject/replacement are the plan's facts rather
        # than something to re-derive from a traceback. The plan's observed half is already joined
        # to these changes by `change_key`; the brief reads it from the step it is handed.
        @plan_changes = Array(step["changes"])
        step
      rescue Corpus::Refused => e
        # The service's own sentence, kept whole: it says which direction this ladder
        # reads, or which release it has no chapter for, and that is the part that
        # changes what the caller does next.
        Record.refused(repository: @repository, commit: record_commit, worktree: @worktree.root,
          from_version: @from, to_version: rung_to, why: e.message)
      rescue Corpus::Unreachable => e
        Record.refused(repository: @repository, commit: record_commit, worktree: @worktree.root,
          from_version: @from, to_version: rung_to,
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
        @control&.check!
        if subject.nil? || !subject.ran || subject.ok?
          @out&.puts("  repair: not attempted — the #{before_the_move ? "baseline" : "subject"} " \
                     "did not run or was green")
          return nil
        end
        # A post-move repair is only meaningful against a green baseline: with a red one, the
        # failure is the application's and there is nothing to attribute to the move. The
        # baseline's own repair is the one case where "red" is the subject.
        if !before_the_move && (@baseline.nil? || !@baseline.ok?)
          @out&.puts("  repair: not attempted — the baseline was not green, so the move is not attributable")
          return nil
        end

        repairer = @repair || Repair
        budget = repair_budget(repairer.budget(@env))
        if budget.nil?
          @out&.puts("  repair: not attempted — no budget (UPGRADER_REPAIR_ATTEMPTS) or the account permits no repair")
          return nil
        end

        # **A repair that changes the Gemfile has not been measured until the bundle is installed.**
        # The loop's `rerun` is the suite, and the suite runs the installed bundle: on
        # volunteer-portal the model correctly moved mocha to 2.1 and updated the test helper, then
        # the rerun still loaded mocha 1.13 from the old bundle and the same NameError came back.
        # The digest of the two files is the trigger, so a repair that only edits code pays nothing.
        @bundle_digest = bundle_digest

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
            # **The joined brief is evidence, not decoration.** It is what the corpus already knows
            # about this rung, change by change — a report that is this failure, a rule that is
            # already in force, a decision another project made. The repair agent is the one reader
            # who can use that before trying the same fix again.
            brief: @brief,
            output_tail: subject.output_tail
          },
          budget: budget, env: @env, out: @out, rerun: rerun, before_the_move: before_the_move,
          config_dir: File.join(@home, "repair"), home: @home,
          on_attempt: ->(attempt) { stages << repair_stage(attempt) }
        ).run
        @out.puts("  repair: #{result}") if @out && !result.attempts.empty?
        return nil if result.attempts.empty?

        # **A repair is knowledge, captured while it is still knowable.** The record is written from
        # the final state, where the suite is green: what the failure said, and which files the repair
        # changed, are gone by then. It becomes a corpus report (`Filing.repair_report_for`) rather
        # than a line in this run's log.
        @repairs << repair_outcome(subject, result, before_the_move: before_the_move) if result.repaired


        # The re-run happened inside the loop (`rerun` assigns the ivar it was built around),
        # so what this returns is the *latest* reading of the stage, green or not.
        before_the_move ? @baseline : @suite
      end

      # **The account's permission is a veto, and its model chain is an override.** A project whose
      # account has not permitted a model repair gets none, however the deployment is configured —
      # that is the "mechanical first" rule an account states for its own walks. The deployment's
      # own attempts remain the budget, so a permission without a configured agent still spends
      # nothing; and an account that names a chain replaces the deployment's, which is what makes
      # the model a setting rather than a constant.
      def repair_budget(budget)
        permission = @project&.repair
        return budget if permission.nil?
        return nil if permission.off?
        return budget if budget.nil?

        chain = permission.model_chain
        chain.empty? ? budget : budget.merge(models: chain)
      end

      # What the repair did, from the attempts and the tree it left: the files each attempt changed,
      # and their diff against the base — the repair's own change, which is the part of the step's
      # patch a reader would have to guess at otherwise.
      def repair_outcome(subject, result, before_the_move:)
        files = result.attempts.flat_map { |attempt| Array(attempt.changed) }.uniq
        diff = if files.empty?
          ""
        else
          Open3.capture2e("git", "-C", @worktree.root, "diff", "--", *files).first
        end
        Repair::Outcome.new(failure: subject.output_tail, suite: @suite_plan&.command,
          attempts: result.attempts.length, files: files, diff: diff,
          before_the_move: before_the_move)
      end

      def repair_stage(attempt)
        tail = attempt.output_tail.to_s
        stream = attempt.respond_to?(:stream_sentence) ? attempt.stream_sentence : ""
        tail = "#{tail}\n#{stream}" unless stream.to_s.empty?
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
      # **Making the Gemfile installable is a precondition of measuring, not a change the rung is
      # judged for, and both pipelines need it.** The caller decides what happens to the repairs
      # next — a rung commits them beside its accepted decisions, a patch checkpoint commits them on
      # their own — but the edits and the stage are the same in both places. They were one copy in
      # the rung pipeline alone, and that is how a patch checkpoint came to install the
      # application's Gemfile as it stood: an application whose sources name the `git://` protocol
      # GitHub retired in 2022 had every era rejected for the protocol's reason, and the record
      # blamed the interpreter matrix for it.
      def apply_preflight(stages, step)
        preflight = preflight_stage(stages, step)
        # **A preflight repair has an origin of its own.** It was concatenated as a
        # `Preflight::Repair`, which has no `origin`, so the body counted every one of
        # them as “from the service's scan” — 30 dependency-line edits under a sentence
        # that read as source changes. The `Applier::Applied` shape is what the rest of
        # the record already speaks, and `preflight` is the fact a reviewer needs.
        @applied.concat(preflight.repairs.map { |repair|
          Applier::Applied.new(path: repair.path, line: repair.line, text: repair.text,
            after: repair.after, subject: repair.subject, origin: "preflight",
            note: repair.note)
        })
        @decisions.concat(preflight.decisions)
        preflight
      end

      def preflight_stage(stages, step)
        corpus = @corpus || Corpus.new(base: @api)
        # **A patch checkpoint has no rung floor of its own**, so a `ruby_below` entry was
        # evaluated against nothing and skipped — measured on the 3.2.9 -> 3.2.22.5 move, where
        # multipart-post 2.2.0 was pulled in and the suite died on `Module#deprecate_constant`.
        # The application's own declared interpreter is the best fact this stage has when the
        # step carries no floor; it is a hint, exactly as it is for the interpreter choice, and
        # an unreadable declaration stays nil rather than becoming a guess.
        declared = @lockfile.declared_ruby.to_s[/\d+(?:\.\d+)*/]
        @preflight = Preflight.new(root: @worktree.root, corpus: corpus,
          ruby: step["requires_ruby"] || @lockfile.locked_ruby || declared,
          rails: rung_of(step), decision_policy: @decision_policy)
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

      # **The rung the record is about, which is not the walk's destination.** `@to` is where
      # the queue asked the loop to end up; a step that moves 6.1.7.10 to 7.0.0 must record
      # 7.0.0, or the run claims a five-rung skip and the service is right to refuse it.
      # Before the plan is fetched there is no rung, and the destination is the only answer.
      def rung_to = @rung_to.to_s.empty? ? @to : @rung_to

      # **A checkpoint whose two releases share a minor is a patch, and a patch is maintenance.**
      # It is decided from the lockfile's release and the checkpoint rather than from a declared
      # kind, because those two are the facts the step actually has: the service may put a
      # checkpoint on the feed, but only the tree can say where the application really is.
      def patch_checkpoint? = same_minor?(@from, @to) && checkpoint_ahead?

      def checkpoint_ahead?
        order = Gem::Version.new(@to.to_s) <=> Gem::Version.new(@from.to_s)
        order&.positive? == true
      rescue ArgumentError
        false
      end

      def checkpoint_kind = patch_checkpoint? ? "patch" : "minor"

      # The step hash the stages expect, for a checkpoint the ladder has no chapter for. It is
      # deliberately not a fabricated ladder rung: `changes` is empty because a patch release
      # documents none, and `requires_ruby` is unset so the interpreter is chosen from the
      # application's own lockfile rather than from a floor nobody stated.
      def patch_stage
        @patch_stage ||= {
          "from_version" => @from, "to_version" => @to,
          "name" => "Rails #{@to} patch", "requires_ruby" => nil, "changes" => []
        }
      end

      # **What is installed is the checkpoint; what changed is the chapter.** A minor checkpoint
      # names the series' latest patch, while the ladder's plan is the move to the `.0`. The plan's
      # version stays in `plan_to` for anything that asks, and every stage that writes a version
      # into the tree, the record or the branch reads the checkpoint.
      def checkpoint_step(step)
        plan_version = step["to_version"].to_s
        return step if @to.to_s.empty? || @to.to_s == plan_version
        return step unless same_minor?(@to, plan_version)

        step.merge("plan_to" => plan_version, "to_version" => @to,
          "name" => "#{step["name"]} (patch #{@to})")
      end

      # The move's *from* is the release the lockfile pins, not the ladder rung the plan happens
      # to be filed under. The two differ whenever the application has taken a patch release: the
      # plan for 4.1.16 -> 4.2.11.3 is the 4.1 chapter, whose from is 4.1.0. Keeping the rung here
      # is what made every patch walk's pull request fall back to the default branch.
      def checkpoint_from(step)
        return step if @from.to_s.empty? || step["from_version"].to_s == @from

        step.merge("from_version" => @from)
      end

      # **The maintenance pipeline, and the stages it deliberately leaves out.** There is no plan,
      # no scan, no accepted-decision edit, no `app:update`, no framework-default stepping and no
      # formatter: a patch release changes no documented API, so anything that rewrites the
      # application would be this tool making a change nobody documented. What is left is the part
      # of a rung that measures — the environment, the exact pin, the boot, the suite and the rest
      # of the application's declared gate — and `Record.verdict` decides it like any other run.
      # The preflight is the one edit that does run, and it is not an exception to that rule: a
      # Gemfile that cannot be installed cannot be measured, and its repairs are mechanical,
      # attributed and carried in the record beside the run they made possible.
      def patch_run(stages)
        step = patch_stage
        @out.puts("  patch update: #{@from} -> #{@to} — no documented changes; the suite is the evidence") if @out

        entry, settled = settled_entry(step)
        if settled
          @out.puts("  already settled: #{entry.verdict} — #{entry.note}") if @out
          return nil
        end

        # **The environment, before the interpreter probe.** `choose_machine` picks an era by
        # installing the application's bundle, so a Gemfile that cannot be installed as it stands
        # rejects every era for that reason and the record blames the matrix for a fact about the
        # application's own sources. The repairs are committed here so the baseline below measures
        # the tree the probe measured.
        apply_preflight(stages, step)
        checkpoint("preflight")

        choice = choose_machine(stages, step)
        return finish(choice) if choice.is_a?(Record)

        @machine, install = choice
        @out.puts("  interpreter: #{@machine.interpreter}" \
                  "#{@machine.image.to_s.empty? ? "" : ", image #{@machine.image}"}") if @out
        return finish(install_record(install, stages)) unless install.ok?

        prepare_browser(stages, @machine)

        services = services_stage(stages)
        if services && !services.ok?
          verdict, why = Record.verdict(baseline: nil, suite: nil, stages: stages)
          return finish(build(step, stages, verdict, why))
        end

        javascript_stage(stages)
        database_stage(stages)
        assets_stage(stages)
        @prepare_checks = prepare_checks_stage(stages)
        style_baseline(stages)

        # The baseline is the same rule as a rung's: "this patch broke the suite" and "the suite
        # was already red" are one sentence without it, and the second is not a fact about Rails.
        @baseline = baseline(stages)

        pin = rewrite(stages, step)
        return finish(pin) if pin.is_a?(Record)
        checkpoint("pin Rails #{@to}")

        @boot = boot(stages)
        stale_lock(stages)
        missing_gems(stages)
        @suite = suite(stages)
        mechanical_repairs(stages)
        @checks = Array(@prepare_checks) + checks_stage(stages)
        checkpoint(nil)

        verdict, why = Record.verdict(baseline: @baseline, suite: @suite, stages: stages,
          checks: @checks)
        finish(build(step, stages, verdict, why))
      end

      def same_minor?(left, right)
        one = minor_of(left)
        !one.nil? && one == minor_of(right)
      end

      def minor_of(version)
        parts = version.to_s.strip.split(".").first(2)
        return nil unless parts.size == 2 && parts.all? { |part| part.match?(/\A[0-9]+\z/) }

        parts.join(".")
      end

      # **The commit a record and the ledger name, which is not always the tree's patch base.** A
      # kept tree that was killed after a concern commit is put back to its marker; the marker is
      # both. A hand step or a test source may carry a label as its identity while the tree it
      # points at has a real HEAD; the patch is against the real base, the record is against the
      # label the caller and the ledger already use.
      def record_commit
        commit = @record_commit.to_s
        return commit unless commit.empty?
        return @worktree.commit.to_s if @worktree.respond_to?(:commit)

        @base_commit.to_s
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
      #   nothing about the move (the probe rule in `docs/design-notes.md`).
      def choose_machine(stages, step)
        return [@machine, install_bundle(stages, @machine)] if @machine

        native = Machine::Native.new
        floor = step["requires_ruby"]
        unless docker_mode? || rvm_mode?
          if Interpreters.meets?(native.ruby_version, floor) == false
            return Record.unverified(
              repository: @repository, commit: record_commit, worktree: @worktree.root,
              from_version: @from, to_version: rung_to,
              why: "this step requires Ruby #{floor} and this interpreter is #{native.interpreter}: " \
                   "run it with `#{RUNTIME_ENV}=docker` so the step executes in an era container " \
                   "(`scripts/upgrader-images.sh build`), or on an interpreter that meets the floor"
            )
          end
          return [native, install_bundle(stages, native)]
        end

        candidates = candidates_for(step)
        if candidates.empty?
          why = if declared_eras
            "this step requires Ruby #{floor} and the declaration's eras " \
              "(#{declared_eras.join(", ")}) do not meet it (the matrix holds " \
              "#{Interpreters.matrix.map(&:ruby).join(", ")}); name an era that does, or " \
              "set `eras` to auto"
          else
            "this step requires Ruby #{floor} and no interpreter in the matrix meets it " \
              "(the matrix holds #{Interpreters.matrix.map(&:ruby).join(", ")}); add an era " \
              "or move the step to a release this matrix can run"
          end
          return Record.unverified(
            repository: @repository, commit: record_commit, worktree: @worktree.root,
            from_version: @from, to_version: rung_to,
            why: why,
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
          repository: @repository, commit: record_commit, worktree: @worktree.root,
          from_version: @from, to_version: rung_to,
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

      def candidates_for(step)
        Interpreters.candidates(
          requires_ruby: step["requires_ruby"],
          declared: @lockfile.declared_ruby,
          locked: @lockfile.locked_ruby,
          dot: @lockfile.dot_ruby_version,
          only: declared_eras
        )
      end

      # The eras this project's declaration names, or nil when it says `auto`. The declaration is
      # a constraint from the operator; the floor and the install probe decide within it.
      def declared_eras
        eras = @project&.eras
        eras.is_a?(Array) ? eras : nil
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
        if rvm_mode?
          return Machine::Host.new(entry: entry, home: @home, out: @out, services: services,
            services_command: @stack.services_command.first,
            rvm_root: @env[Machine::Host::RVM_ENV], gemset: @env[Machine::Host::GEMSET_ENV])
        end

        Machine::Container.new(entry: entry, home: @home, out: @out, run_id: run_id)
      end

      # The application's own bundle on the unmodified checkout, recorded like every other
      # command. `bundle install` and not `bundle update`: this is the environment the
      # baseline needs, and resolving a *new* Rails is the pin stage's business. It is also
      # the interpreter probe (`choose_machine`), which is why it takes the machine rather
      # than defaulting to the one the step settled on.
      # **What the installed bundle is, as the two files a resolve reads.** A repair's edit to
      # either means the machine is running something else than the tree says; the digest is the
      # fact that makes the install conditional rather than a tax on every attempt.
      def bundle_digest
        %w[Gemfile Gemfile.lock].map do |name|
          path = File.join(@worktree.root, name)
          File.file?(path) ? Digest::SHA256.file(path).hexdigest : "-"
        end.join(":")
      end

      # The install a repair's Gemfile or lock edit owes the suite. The install is a recorded stage
      # of its own, before the suite that measures it. A failed install does not end the loop: the
      # suite still runs, fails with the resolver's own sentence, and the next attempt is briefed
      # with that rather than with a silence.
      def install_after_repair(stages)
        return if @machine.nil? || bundle_digest == @bundle_digest

        @out&.puts("  repair: the bundle changed; installing it before the suite") if @out
        install = install_bundle(stages, @machine)
        @bundle_digest = bundle_digest
        return if install.ok?

        @out&.puts("  repair: the repaired bundle did not install: " \
                   "#{Record.first_line(install.output_tail)}") if @out
      end

      def install_bundle(stages, machine = @machine)
        install_packages(stages, machine)
        drop_unrunnable_bundler(machine, stages)
        @out.puts("  install: bundle install#{machine.respond_to?(:era) && machine.era ? " (ruby #{machine.era})" : ""}") if @out
        stage = command(Record::BUNDLE, %w[bundle install], chdir: @worktree.root,
          env: bundle_env(machine), machine: machine, excerpt_bytes: Shell::RESOLVER_BYTES)
        stages << stage
        if (version = missing_bundler(stage))
          stages << command(Record::BUNDLE,
            ["gem", "install", "--user-install", "bundler", "-v", version, "--no-document"],
            chdir: @worktree.root, env: bundle_env(machine), machine: machine,
            excerpt_bytes: Shell::RESOLVER_BYTES)
          stage = command(Record::BUNDLE, %w[bundle install], chdir: @worktree.root,
            env: bundle_env(machine), machine: machine)
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
            env: bundle_env(machine), machine: machine,
            excerpt_bytes: Shell::RESOLVER_BYTES)
          stages << stage
          break if stage.ok?
        end

        return stage if stage.ok?
        return stage if moved_gems.empty?

        conservative_update(stages, moved_gems, stage: Record::BUNDLE, machine: machine)
      end

      # **The packages the application's own build declares, installed in the machine that will
      # build its gems.** A repository's CI is the place it says which native headers its gems
      # need, and the era image cannot carry every repository's list: measured on the diaspora
      # walk, the workflow installed `libidn11-dev` and the 6.1→7.0 rung could not build
      # `idn-ruby` until the step installed it too.
      #
      # A machine that is not a container is *told*, not silently skipped: a native or rvm walk
      # would need `sudo` to install a package, and this tool does not take that decision on
      # somebody's laptop. The declaration still travels into the record, so a reader can see
      # what the application asked for and that this machine did not supply it.
      def install_packages(stages, machine)
        packages = Array(@project&.toolchain&.apt).map(&:to_s).reject(&:empty?).uniq
        return if packages.empty?

        line = "apt-get update && apt-get install -y --no-install-recommends " \
               "#{packages.shelljoin}"
        unless machine.respond_to?(:root_command)
          @out&.puts("  packages: #{packages.join(", ")} — declared by the application's build, " \
                     "and this machine is not a container, so they were not installed")
          stages << Record::Command.new(stage: Record::PACKAGES, command: line, ran: false,
            exit_code: nil, seconds: 0.0,
            output_tail: "not installed: this machine is not a container (`apt` needs root, and " \
                         "a native walk does not take it)")
          return
        end

        @out&.puts("  packages: #{packages.join(", ")}") if @out
        stage = command(Record::PACKAGES, ["sh", "-lc", line], chdir: @worktree.root,
          machine: machine, root: true, display: ["apt-get", "install", *packages])
        stages << stage
        if !stage.ok? && @out
          @out.puts("  packages: #{Record.first_line(stage.output_tail)} — the bundle is attempted " \
                    "anyway, and this stage says why it may fail")
        end
        stage
      end

      # **A browser suite is answered by the machine, not by the application's tree.** The walk
      # measures the application's own suite, and an application with `:js` examples runs a real
      # Chromium. Two things stop it in an era container, and neither is the application's to fix:
      #
      # * **The browser's sandbox needs a capability this walk will not grant.** Chromium's setuid
      #   helper builds a network and a PID namespace, which needs `CAP_SYS_ADMIN`; handing that to
      #   a container that executes an untrusted repository's bundle would trade the step's isolation
      #   for a browser's. Debian's launcher sources `/etc/chromium.d/*` before it execs, so the
      #   machine turns the sandbox off there — the disposable container, not the browser, is the
      #   boundary that matters. Measured in the 2.7 era: without the flag every example dies with
      #   `session not created: DevToolsActivePort file doesn't exist`.
      # * **The driver gem asks an endpoint that retired the image's browser.** `webdrivers` looks up
      #   the driver for the installed build on `chromedriver.storage.googleapis.com`, which stopped
      #   publishing for current Chromium; the driver Debian installs is built *with* the browser.
      #   The machine seeds `webdrivers`' own cache directory from it, so the gem's update check finds
      #   a correct local binary and never asks the network. Measured in the 3.3 era: Chromium 156,
      #   long past the endpoint's last release.
      #
      # Both are configuration of the machine the application is measured on. The alternative that
      # was written first — a support file in the application's `spec/` and a `webdrivers` floor in
      # its Gemfile — is a change to the repository under measurement, which is the one thing a
      # baseline must not need.
      #
      # **Which browser is the project's to say, because the pair has to speak the protocol its
      # test stack was written for.** `toolchain.chrome` names `pinned` (the build the era image
      # verified) or `distro` (the Debian release's own package), and its *presence* is the claim
      # that the suite drives a browser at all — a project with no `:js` examples leaves the key out
      # and pays for nothing here, which is most projects. A live release's `chromium` moves under an
      # application that was measured against an older one — measured on `ohana-api`, 19 `:js`
      # examples failed on 156 and none on 120 — so the machine offers both and the declaration
      # chooses.
      def prepare_browser(stages, machine)
        # **The lockfile overrides the stored declaration when it names poltergeist.** A project
        # connected before this rule existed carries `chrome` in its toolchain, while its own
        # `spec_helper` is written to choose `:poltergeist` the moment `phantomjs` exists. The
        # lock is the fact the suite will read; the stored declaration is a hint from an earlier
        # detection.
        choice = phantomjs_locked? ? "phantomjs" : @project&.toolchain&.browser.to_s
        return if choice.empty?

        if choice == "phantomjs"
          return unless machine.respond_to?(:command)

          @out&.puts("  browser: phantomjs — the application's own spec_helper selects poltergeist " \
                     "when this executable is on PATH") if @out
          stage = command(Record::BROWSER, ["sh", "-lc", "#{PHANTOMJS_BINARY} --version"],
            chdir: @worktree.root, machine: machine, display: ["phantomjs", "--version"])
          stages << stage
          @browser_prepared = true if stage.ok?
          return
        end

        return unless machine.respond_to?(:root_command) && machine.respond_to?(:browser_cache)

        @out&.puts("  browser: #{choice} — installed where the image has none, sandbox off, " \
                   "driver seeded from the image") if @out
        # **An archived era's image carries no browser**, because a live repository's package would
        # have been the wrong one to bake; its own frozen archive still has the pair, so the step
        # installs it. On a live era both executables are already there and this is one `test`.
        stages << command(Record::BROWSER, ["sh", "-lc", browser_install_command],
          chdir: @worktree.root, machine: machine, root: true,
          display: ["apt-get", "install", *BROWSER_PACKAGES])
        stages << command(Record::BROWSER, ["sh", "-lc", browser_flags_command],
          chdir: @worktree.root, machine: machine, root: true,
          display: ["chromium", "--no-sandbox", "--disable-dev-shm-usage"])
        # **The project's choice, applied to the two names the suite and the driver gem read.** A
        # declaration that says `distro` keeps the release's own package (already on `/usr/bin`),
        # and one that says `pinned` — or nothing — gets the image's build where it has one. The
        # guard is `[ -x ]`, so an archived era whose image carries no pinned pair is unchanged.
        unless choice == "distro"
          stages << command(Record::BROWSER, ["sh", "-lc", browser_pin_command],
            chdir: @worktree.root, machine: machine, root: true,
            display: ["chromium", "--version"])
        end
        stages << command(Record::BROWSER, ["sh", "-lc", browser_seed_command(machine)],
          chdir: @worktree.root, machine: machine, display: ["chromedriver", "--version"])
        @browser_prepared = true
      end

      # **The browser the image does not have is installed from the era's own archive.** The guard
      # asks both executables because a half-installed pair is the failure this has to survive: a
      # browser without its driver is a `session not created` the step would otherwise report as the
      # application's.
      # **A lockfile with poltergeist is a suite that selects PhantomJS without being told.** The
      # application's `spec_helper` checks for the executable itself; the lock proves which driver
      # gem it will require. A project that names `phantomjs` in the lock directly is the same fact
      # in the other spelling.
      def phantomjs_locked?
        specs = @lockfile&.specs
        return false if specs.nil?

        specs.key?("poltergeist") || specs.key?("phantomjs")
      end

      def browser_install_command
        <<~SH
          if [ ! -x #{BROWSER_BINARY} ] || [ ! -x #{SYSTEM_DRIVER} ]; then
            apt-get update && apt-get install -y --no-install-recommends #{BROWSER_PACKAGES.join(" ")}
          fi
        SH
      end

      # The two links, and both versions read back so the record says which pair measured the rung.
      # `ln -sf` replaces Debian's `/usr/bin/chromium` symlink rather than editing the package: the
      # container is disposable and the package is still there for a `distro` project.
      def browser_pin_command
        <<~SH
          if [ -x #{PINNED_BROWSER} ]; then
            ln -sf #{PINNED_LAUNCHER} #{BROWSER_BINARY}
            ln -sf #{PINNED_DRIVER} #{SYSTEM_DRIVER}
          fi
          chromium --version
          chromedriver --version
        SH
      end

      # The launcher's drop-in, written with the value quoted so the launcher's own line appends
      # to whatever another file set. `mkdir` because a machine with the driver but not the
      # browser package has no directory yet, and a missing one is a silent no-op otherwise.
      def browser_flags_command
        "mkdir -p #{File.dirname(CHROMIUM_FLAGS)} && printf '%s\\n' " \
          "#{Shellwords.escape(CHROMIUM_FLAGS_VALUE)} > #{CHROMIUM_FLAGS}"
      end

      # **The driver Debian built with the browser, linked into the cache `webdrivers` reads.** A
      # symlink rather than a copy because the two are one release, and the version file is what
      # makes the gem's update check a local answer: with a valid cache and a driver whose build
      # is the browser's, `Webdrivers::Chromedriver.update` returns this path and asks nothing.
      # Both facts are read inside the machine, which is the only place that knows either, and
      # the directory is the machine's own (`browser_cache`), so two eras sharing the volume do
      # not overwrite each other's driver.
      def browser_seed_command(machine)
        cache = machine.browser_cache
        <<~SH
          if [ -x #{SYSTEM_DRIVER} ]; then
            mkdir -p #{cache}
            ln -sf #{SYSTEM_DRIVER} #{cache}/chromedriver
            chromedriver --version | awk '{print $2}' > #{cache}/chromedriver.version
          fi
          chromium --version
          chromedriver --version
        SH
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
          env: bundle_env(machine), machine: machine)
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
        subjects = @applied.select { |edit| version_move?(edit) }.map { |edit| edit.subject.to_s }.uniq
        subjects & @lockfile.specs.keys & declared_gems
      end

      # **A repair that only changes how a gem is required is not a gem that moves.** The
      # preflight also writes `require: false` for a deploy-only gem and rewrites a `github:`
      # source to `git:`; naming those in `bundle update` asks the resolver to move them, which
      # is how the first real application's patch rung tried to take capistrano 3 beside
      # `rvm-capistrano ~> 2.15` and figaro 1.3 (Ruby >= 2.5) beside a Ruby 2.1 tree. The
      # pin's named set is the gems whose *version requirement* this step changed; a source or
      # require-option repair keeps the lock's own version.
      def version_move?(edit)
        # A `Preflight::Repair` carries no origin because every one of them *is* the preflight's —
        # and the deferred ones are rewrites of a line whose requirement moves at the rung, so they
        # are named like any other requirement change.
        return true unless edit.respond_to?(:origin) && edit.origin.to_s == "preflight"
        return false if edit.after.to_s.strip.empty?

        version_requirement(edit.text) != version_requirement(edit.after)
      end

      # The first quoted requirement on a `gem` line, or nil when the line states none. Read
      # rather than parsed for the same reason `declaration_requirement` is: the line shape is
      # the application's, and the only question is whether a version moved.
      def version_requirement(line)
        line.to_s[/\A\s*gem\s+["'][^"']+["']\s*,\s*["']([^"']+)["']/, 1]
      end

      # **A name the Gemfile no longer declares is not a name the pin may use.** The pin names every gem
      # this step rewrote a line for, so the resolve does not spend its rounds on a line that already
      # moved — but an entry can leave a name behind: a `replaced` entry rewrites the line to the
      # replacement's name, a `removed` entry deletes it, and the lock this step started from still holds
      # the old name, so intersecting with the lock is not enough. Measured on the lighthouse's
      # 4.0 -> 4.1 rung, where the digest replaces `cancan` with `cancancan` *and* removes
      # `therubyracer` and the pin named both: `bundle update rails … cancan … --conservative` exited 7
      # with `Could not find gem 'cancan'`. The *new* name fails the same way and was measured too —
      # bundler resolves a name only when the Gemfile's own dependencies still reach it, and the
      # replacement is not in the lock yet — so a rename is left out of the pin entirely and the
      # replacement arrives the way any new dependency does. `declared_gems` (below, and shared with the
      # bridge question) is the one rule that covers both shapes, read off the file rather than off the
      # entries, because a `removed` entry and a `replaced` one are one fact here.

      # A conservative update of `gems`, widened by what bundler names as stuck, and bounded.
      # The resolver knows this application's requirement graph, so the next round is read out
      # of its message rather than guessed — which is why the pin and the bundle's fallback
      # share it rather than each keeping their own idea of what usually moves together.
      def conservative_update(stages, gems, stage:, machine: nil)
        gems = gems.dup
        PIN_ROUNDS.times do
          attempt = command(stage, ["bundle", "update", *gems, "--conservative"],
            chdir: @worktree.root, env: bundle_env(machine || @machine), machine: machine,
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
          repository: @repository, commit: record_commit, worktree: @worktree.root,
          from_version: @from, to_version: rung_to, stages: stages,
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

        # **The stage that reads `database.yml` sees the same environment as the commands it
        # precedes.** A URL-only file needs `DATABASE_URL` to name an adapter at all; without
        # it the script concluded there was no database and started none, and the boot after it
        # died on the file's own `nil`.
        stages << command(Record::SERVICES, @stack.services_command, chdir: @worktree.root,
          env: application_env)
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
        # **The declaration can forbid what the deployment's budget would allow.** `off` is the
        # project saying this application's framework defaults are a person's decision; the
        # environment is still the budget for a project that says `step`.
        policy = @project&.app_update
        return nil if policy && !policy.step_defaults?

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

        # **Recall, before the pin and the suite.** The rung's gems are known here and nothing that
        # can change has happened yet: this is the point where the corpus is asked what it already
        # knows about the framework move, each gem the routing moves, and each change the plan names
        # (`Brief`). It is recorded either way — a walk that asked and was answered with nothing is a
        # different fact from a walk that did not ask.
        @brief = recall(step, route)

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

      # The corpus's memory for this rung, bounded and non-fatal: `Brief` records a question it could
      # not ask as a section rather than raising, because recall is not permission.
      def recall(step, route)
        return nil if @corpus.nil? && @api.to_s.empty?

        brief = Brief.new(corpus: @corpus || Corpus.new(base: @api))
        result = brief.call(from: step["from_version"], to: step["to_version"],
          gems: route.fetch("gems", []),
          subjects: (step["changes"] || []).map { |change|
            { "subject" => change["subject"], "change_kind" => change["kind"],
              "component" => change["component"] }
          },
          # **The walk's own earlier answers are recall too.** A decision the project carries is
          # what this application already chose; the brief says so before the rung applies it, so a
          # reviewer sees the answer rather than rediscovering the question. `brief_decisions` are
          # the same change answered on another project: they are shown and never applied.
          decisions: (@project&.decisions || []) + (@project&.brief_decisions || []),
          # **The plan's joined half is the framework section's first source.** It knows which
          # report is which change, which reports joined nothing and which rules are in force; a
          # second `/api/reports/upgrade` read would know only the library window.
          plan: step,
          # A decision's own project is the cross-project answer's identity; one the declaration
          # does not repeat belongs to the project this walk is reading.
          project: @project&.slug)
        observed = Array(step["observed"]).length
        unmatched = Array(step["observed_unmatched"]).length
        rules = Array(step["rules"]).length
        @out.puts("  recall: #{result.sections.length} question(s), " \
                  "#{result.sections.sum { |section| section.items.length }} report(s) " \
                  "(plan: #{observed} observed, #{unmatched} unmatched, #{rules} rule(s))" \
                  "#{result.truncated ? ", truncated" : ""}") if @out
        result
      rescue Corpus::Refused, Corpus::Unreachable => e
        @out.puts("  recall: unavailable (#{e.message})") if @out
        nil
      end

      def routing_decision(gem, reason: nil)
        Record::Decision.new(
          path: "Gemfile.lock", line: nil,
          subject: "#{gem["name"]} #{gem["version"]}".strip,
          reason: (reason || gem["reason"] || gem["note"]).to_s,
          kind: gem["verdict"], replacement: gem["to"] || gem["replacement"],
          source: "GET /api/releases/route"
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
        @tests.machine_test_env(@stack).merge(bundle_env(@machine))
          .merge(database_env).merge(project_env).merge(service_env)
          .merge(@suite_env).merge(browser_env)
      end

      # **A declared service is an address, and the step container runs it on the application's
      # own port.** Redis is started unconditionally by `agents-services`, but an application
      # that reads `ENV["REDIS_URL"]` sees nothing unless this names it. Measured on limestone's
      # 6.1 baseline: its Flipper initializer read `ENV["REDIS_BASE_URL"]`, interpolated nil into
      # `"#{nil}flipper"`, and `Redis.new` raised `invalid uri scheme ''` before the first
      # example. `REDIS_BASE_URL` keeps its trailing slash because that initializer appends a key
      # namespace to it; `REDIS_URL` is the name the cache store and Sidekiq read. Both are the
      # machine's statement about where its own service is, not a rewrite of the application.
      def service_env
        names = Array(@project&.services).map(&:to_s)
        return {} unless names.include?("redis") || @lockfile&.specs&.key?("redis")

        {
          "REDIS_URL" => "redis://127.0.0.1:6379",
          "REDIS_BASE_URL" => "redis://127.0.0.1:6379/"
        }
      end

      # **A `database.yml` that names only `DATABASE_URL` still needs the database named.**
      # Measured on `limestone` at the 6.1 patch rung: every environment in its file is
      # `url: <%= ENV["DATABASE_URL"].gsub(...) %>`, the services stage read no adapter and
      # started nothing, and the boot died on `undefined method gsub for nil`. The machine's
      # URL points at the server its own services stage starts; a keyed file ignores it, and a
      # caller's own value (a suite env file, an account's env) is merged after this one.
      def database_env
        return {} if @worktree.nil?

        path = File.join(@worktree.root, "config", "database.yml")
        return {} unless File.file?(path)
        return {} unless File.read(path, encoding: "utf-8").match?(/ENV\[\s*["']DATABASE_URL["']\s*\]/)
        return {} unless @machine.respond_to?(:database_url)

        { "DATABASE_URL" => @machine.database_url }
      rescue SystemCallError
        {}
      end

      # **The cache the machine seeded, named the way the driver gem reads it.** Only a machine
      # that prepared a browser has one, and only after the packages stage ran; a host walk sets
      # nothing, so an application that downloads its own driver behaves as it does on a
      # developer's machine.
      def browser_env
        env = {}
        if @browser_prepared && @machine.respond_to?(:browser_cache)
          env["WD_INSTALL_DIR"] = @machine.browser_cache
        end
        env.merge(decision_browser_env)
      end

      # **The driver the project chose, not a second driver selection.** The application's own
      # spec_helper reads `SELENIUM_BROWSER`; phantomjs is the era binary and the default, while
      # chrome/firefox name the image's browser. `stop`/`ask`/`deny` leave the application's own
      # choice alone, which is what a project with no browser declaration sees.
      def decision_browser_env
        return {} unless browser_suite?

        case @decision_policy["browser_driver"].to_s
        when "phantomjs-1.9.8" then { "SELENIUM_BROWSER" => "phantomjs" }
        when "chrome" then { "SELENIUM_BROWSER" => "chrome" }
        when "firefox" then { "SELENIUM_BROWSER" => "firefox" }
        else {}
        end
      end

      # A policy default must not put `SELENIUM_BROWSER` into every Rails suite. The lock's own
      # browser gem is the fact that says this application drives one; a project declaration that
      # names a browser is the same fact in the declaration.
      def browser_suite?
        return true if @project&.toolchain&.browser.to_s != ""

        %w[poltergeist selenium-webdriver webdrivers cuprite ferrum]
          .any? { |name| @lockfile&.specs&.key?(name) }
      end

      # **The bundle's own groups, detected rather than assumed.** The tool's path settings are
      # what make this run's bundle this run's, and they win; the groups are what the application
      # declares and what its commands need, and `Stacks::Rails.bundle_groups` reads them from the
      # Gemfile through Bundler's DSL. `BUNDLE_WITH` is what installs an optional group, and a
      # group this removes from `BUNDLE_WITHOUT` is installed because the application's own gate
      # runs an executable from it — the formatter a project declared, the adapter its database.yml
      # names. With no detection the environment is exactly the walk's old one, which is the
      # fallback a Gemfile the DSL refuses deserves.
      def bundle_env(machine)
        env = @worktree.bundle_env(machine: machine)
        groups = bundle_groups
        return env if groups.groups.empty?

        names = groups.groups.map(&:to_s)
        optional = groups.optional.map(&:to_s).uniq
        excluded = Source::WITHOUT_GROUPS - names
        env = env.merge("BUNDLE_WITHOUT" => excluded.join(" "))
        env["BUNDLE_WITH"] = optional.join(" ") unless optional.empty?
        env
      end

      def bundle_groups
        @bundle_groups ||= @stack.bundle_groups(@worktree.root, commands: bundle_commands)
      end

      # The commands whose executables the bundle has to provide: the application's own suite, its
      # declared gate, and the formatter and checker the project calls its style. A command that
      # is not `bundle exec <gem>` contributes nothing (the pack decides), and a project with none
      # of them contributes nothing at all.
      def bundle_commands
        commands = [@project&.suite&.command]
        Array(@project&.checks).each { |check| commands << check.command }
        commands << @project&.style&.format
        commands << @project&.style&.check
        commands.compact
      end

      # `KEY=VALUE` lines, `#` comments and blank lines ignored, and a missing file is an
      # empty environment rather than a failure — the operator named a path, and a path that
      # is not there says "nothing to add" rather than "refuse to walk".
      # **The suite's environment, by name.** The declaration names what the application's suite
      # reads (`RAILS_SECRET_TOKEN`) and the deployment carries the value; a name this process does
      # not carry is *absent* rather than empty, because an empty string is what a forwarded-but-
      # unset variable looks like and it would silently disable the suite rather than say so.
      def project_env
        return {} if @project.nil?

        @project.env_names.each_with_object({}) do |name, values|
          value = @env[name].to_s
          values[name] = value unless value.empty?
        end
      end

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
      # **The application's own JavaScript dependencies, installed exactly as its lockfile
      # pins them.** The suite renders views, and a stylesheet that imports from a package
      # (`perfect-scrollbar` on the second lighthouse) is a `node_modules` path the
      # application's CI creates and a fresh tree does not. The stage is absent for an
      # application with neither lockfile — nothing to install is not a failure.
      def javascript_stage(stages)
        root = @worktree.root
        argv, refusal = @stack.prepare_javascript(root)
        return nil if argv.nil? && refusal.nil?
        unless argv
          stages << Record::Command.new(stage: Record::JAVASCRIPT, command: refusal,
            ran: false, exit_code: nil, seconds: 0.0, output_tail: "")
          return nil
        end

        @out.puts("  javascript: #{argv.join(" ")}") if @out
        stages << command(Record::JAVASCRIPT, argv, chdir: root, env: application_env)
        stages.last
      end

      # **The assets the suite renders, compiled before the baseline reads it.** A Rails
      # application's `public/assets` manifest is a build product of its own CI
      # (`assets:precompile`); a fresh tree has no such directory, and sprockets-rails
      # refuses an undeclared asset at render time. The stage is absent when the application
      # has no `app/assets` at all.
      def assets_stage(stages)
        root = @worktree.root
        argv, refusal = @stack.prepare_assets(root, five_or_newer: five_or_newer?)
        return nil if argv.nil? && refusal.nil?
        unless argv
          stages << Record::Command.new(stage: Record::ASSETS, command: refusal,
            ran: false, exit_code: nil, seconds: 0.0, output_tail: "")
          return nil
        end

        @out.puts("  assets: #{argv.join(" ")}") if @out
        stages << command(Record::ASSETS, argv, chdir: root, env: application_env)
        stages.last
      end

      # The same compile, after the pin and `app:update`, because that is the bundle the
      # suite and the deployment actually get. It is a separate stage in the record rather
      # than a re-run hidden inside the first one: "the assets compiled before the move"
      # and "the assets compiled after it" are different facts, and the second is the one
      # that would have caught the 4.1 rung's missing jQuery UI.
      def verify_assets_stage(stages)
        stage = assets_stage(stages)
        return nil if stage.nil?

        stage.output_tail = "after the pin: #{stage.output_tail}"
        stage
      end

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
        argv, refusal = @stack.prepare_database(root, five_or_newer: five_or_newer?)
        unless argv
          stages << Record::Command.new(stage: Record::DATABASE, command: refusal,
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

        argv = @stack.migrate(@worktree.root, five_or_newer: five_or_newer?)
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
        @suite_plan = @tests.detect(@worktree.root, declared: @project&.suite, stack: @stack)
        unless @suite_plan
          reason = @tests.respond_to?(:no_suite_reason) ? @tests.no_suite_reason(@worktree.root, @stack) : "no suite"
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
        @control&.check!
        announce(stage, @suite_plan.command)
        result = run_suite_once
        # **A browser that died at startup is not a finding about the move.** Measured on 19wu's
        # 4.0 baseline: the only failure was `Capybara::Poltergeist::DeadClient` at the first
        # `:js` example's `visit`, and the same example passed in the suite after the move. A
        # retry is still the suite deciding, and a real crash fails it a second time; the record
        # says the first run was repeated and why.
        retried = browser_retry_allowed? && dead_client_only?(result)
        if retried
          @out&.puts("  #{stage}: the only failure was a dead PhantomJS client; rerunning once")
          result = run_suite_once
        end
        # **The repair reads this, the record reads `output_tail`.** The two bounds are different
        # because the two readers are: a failure list longer than the record's excerpt is still a
        # list a repair can answer, and reading the record's tail instead lost every block before
        # the cut (see `Tests::SUITE_ANALYSIS_BYTES`).
        @suite_output = result.output
        tail = result.output_tail.to_s
        if retried
          tail = "#{tail}\n(the first run's only failure was " \
                 "Capybara::Poltergeist::DeadClient; the suite was rerun)"
        end
        stages << Record::Command.new(stage: stage, command: @suite_plan.command, ran: result.ran,
          exit_code: result.exit_code, seconds: result.seconds, output_tail: tail)
        @progress.finish(stage: stage, status: status_for(result),
          exit_code: result.exit_code, duration_ms: milliseconds(result))
        stages.last
      end

      def run_suite_once
        @tests.run(@worktree.root, @suite_plan, timeout: @suite_timeout, stack: @stack,
          env: application_env, machine: @machine)
      end

      # An empty policy is the deployment's old behaviour; `retry_once` is the platform default and
      # `deny` makes a dead client a red stage rather than a rerun.
      def browser_retry_allowed?
        value = @decision_policy["browser_retry"].to_s
        value.empty? || value == "retry_once"
      end

      # One failure, and it is the browser process rather than an assertion. Two failures are not
      # this rule's: a dead client beside a real failure would hide the real one behind a rerun.
      def dead_client_only?(result)
        return false if result.nil? || result.exit_code.to_i.zero?

        text = result.output.to_s
        text = result.output_tail.to_s if text.empty?
        failures = SuiteFailures.parse(text)
        failures.size == 1 && failures.first.error.to_s == "Capybara::Poltergeist::DeadClient"
      rescue StandardError
        false
      end

      # **The suite's mechanical failures, repaired from the application's own route table.**
      #
      # A red suite is evidence about the move when the failure is attributable to it; a template
      # whose route helper the application never declared, or whose declared helper was handed a nil
      # segment, is a call site the rung has made fail. Both are answered from facts and not from a
      # choice: `Routes` asks the application's router which helper serves a controller and action
      # and in what order its parts go, and the controller says which variable each part arrives in.
      # `TemplateRepairs` builds the line, `Applier` checks it against the file before writing, and
      # the suite is run again — a repair nothing executed is a claim, and the record says which
      # attempts it made (`Record::REPAIR`).
      #
      # **It repeats, because a template raises at its first bad line.** The biddingapp 6.0 rung
      # needed three rounds for four edits: fixing `edit_bid_path` in `bids/show` exposed `bids_path`
      # on the next line, and the same page's second line was only reachable after the first was
      # repaired. One round would have left the rung red with a repair it had already derived. The
      # bound is a measurement plus room, not a guess about how many failures an application has:
      # a suite run per round is the cost, and an application with more call sites than this is the
      # agentic path's work rather than a hundred silent suite runs.
      #
      # **A repair that made the suite green is filed as a report, like any other repair.** It is
      # the walk's most trustworthy kind — no model made it, and its evidence is the failure the
      # suite printed and the suite that passed after it — so it travels in `@repairs` and reaches
      # the corpus through `Filing.file_repairs`, with the derived edits as the fix. Without that,
      # every walk re-derived this family from scratch: the mechanism was generic and the knowledge
      # was not.
      MAX_MECHANICAL_ROUNDS = 5

      def mechanical_repairs(stages)
        return if @suite.nil? || !@suite.ran || @suite.exit_code.to_i.zero?
        return if @worktree.nil? || !@machine.respond_to?(:command)

        before = @suite
        applied = []
        rounds = 0
        while rounds < MAX_MECHANICAL_ROUNDS && !@suite.exit_code.to_i.zero?
          failures = SuiteFailures.parse(
            @suite_output.to_s.empty? ? @suite.output_tail : @suite_output
          )
          @out&.puts("  repair: #{failures.size} failure(s) parsed for mechanical repair")
          break if failures.empty?

          # **The schema's answer first, and it needs no router.** A missing column is a failure the
          # application's own `db/schema.rb` explains; the route table is what the *other* family
          # needs, and reading it here would spend a boot on a failure it cannot explain. Both
          # families write through the same applier and both are followed by the suite.
          #
          # **A redirect's empty body is the third family, and it needs nothing but the failure.**
          # It edits the assertion that read the body the release no longer sends, so it is asked
          # beside `Associations` and before the route table is read: a rung whose suite failed on
          # three redirect assertions and nothing else must not pay a boot for a router it never uses.
          #
          # **A serialized column the release refuses to load is the fourth**, and it is the same
          # shape: the failure names the class and the application's own `config/application.rb`
          # names the setting, so no router is read. It is asked here, before the boot, because a
          # failure it explains is one the route table cannot.
          #
          # **A response header the release returns whole is the fifth**, and it is another
          # assertion the failure names: 6.1's `content_type` includes the charset where the spec
          # asserted a MIME type, and `media_type` is the reader the assertion was written against.
          # No router is read for it either.
          #
          # **A setting the release moved namespaces is the sixth**, and the failure is the removed
          # setter itself: 7.0 no longer answers `ActionView::Base.raise_on_missing_translations=`,
          # so the line moves to `config.i18n.raise_on_missing_translations` in every environment
          # file that carries it. No boot and no router are read for it.
          #
          # **A method the release removed is the seventh**, and the class in the NoMethodError is
          # the evidence: `ActiveModel::Errors#keys` is `attribute_names`, and the line the failure
          # names is the call. A Hash's `keys` is not this family's, which is why the class is read.
          #
          # **A translation the application never defines is the eighth**, and 7.1 is what makes it
          # one: the missing-translation setting now applies to every `I18n.t`, so a spec that names
          # a link's text by a key the application never had treats a `translation missing:` string
          # as a label and then raises. The repair keeps the `href:` the spec already names, which
          # is the half that identifies the link. No boot and no router are read for it either.
          edits = Associations.for(root: @worktree.root, failures: failures)
          edits += SqlFragments.for(root: @worktree.root, failures: failures)
          edits += RedirectBodies.for(root: @worktree.root, failures: failures)
          edits += ResponseContentTypes.for(root: @worktree.root, failures: failures)
          edits += TranslationSettings.for(root: @worktree.root, failures: failures)
          edits += ErrorsKeys.for(root: @worktree.root, failures: failures)
          edits += YamlColumns.for(root: @worktree.root, failures: failures)
          edits += MissingTranslations.for(root: @worktree.root, failures: failures)
          routes = if edits.empty?
            Routes.read(machine: @machine, root: @worktree.root, env: application_env, stack: @stack)
          else
            []
          end
          edits += TemplateRepairs.for(root: @worktree.root, failures: failures, routes: routes)
          break if edits.empty?

          @control&.check!
          result = Applier.new(@worktree.root).apply(edits)
          @applied.concat(result.applied)
          @refused.concat(result.refused)
          stages << Record::Command.new(stage: Record::REPAIR,
            command: "mechanical repairs: #{result.applied.length} edit(s)",
            ran: true, exit_code: result.applied.empty? ? 1 : 0, seconds: 0.0,
            output_tail: result.applied.map { |edit| "#{edit.path}:#{edit.line} — #{edit.note}" }
              .concat(result.refused.map { |refusal| "refused: #{refusal.reason}" }).join("\n"))
          @out.puts("  repair: #{result.applied.length} mechanical edit(s)") if @out
          break if result.applied.empty?

          applied.concat(result.applied)
          rounds += 1
          checkpoint("repair the suite's mechanical failures")
          @suite = run_suite(stages, Record::SUITE)
        end
        return unless rounds.positive? && @suite.ran && @suite.exit_code.to_i.zero?

        outcome = Repair.mechanical_outcome(applied: applied, failure: before.output_tail,
          suite: @suite_plan&.command)
        @repairs << outcome unless outcome.nil?
      end

      # **The style pair is judged at the base commit, and that is the only place it can be.**
      #
      # `format` is an autocorrect, so "did this rung leave the tree formatted" is a question about
      # a *change*, and a change is measured against where the tree started. Measured on diaspora at
      # 7.0.10: its `.rubocop.yml` leaves `Style/ClassAndModuleChildren` at `nested`, its 6.1 tree
      # writes `module User::Querying` in every model namespace, and the declared formatter was
      # `rubocop -A`. RuboCop's own metadata for that cop says `SafeAutoCorrect: false` — moving
      # `compact` to `nested` needs to know whether the parent is a module or a class, and `module
      # User` over a class is `TypeError: User is not a module` at boot. So the walk reformatted 40
      # files, broke the application at boot, and failed a rung whose own edits were fine. The check
      # half of the pair is therefore run here, before anything writes: a red answer means the tree
      # arrived unformatted, and formatting it is a rewrite of the application rather than the move.
      #
      # It is a stage rather than a flag, so the record carries both commands and both exit codes,
      # and `checks_stage` reads `@style_at_base` to carry the check as `preexisting` on the rung.
      def style_baseline(stages)
        policy = @project&.style
        return nil if policy.nil? || policy.check.to_s.empty?

        @control&.check!
        announce(Record::CHECK, policy.check, note: "at the base commit")
        # **The same machinery the rung's own checks go through.** `Checks.run` is what
        # `checks_stage` calls, so the base answer and the head answer cannot disagree about what a
        # check is: an injected test double that answered a suite-shaped result here once made this
        # stage read the baseline's verdict as the application's style.
        result = Checks.run(root: @worktree.root,
          checks: [Project::Check.new(id: "style", name: "style", kind: "lint",
            command: policy.check, required: true, external: false, environment: nil,
            reason: "the project declares this style check; asked here of the base commit")],
          machine: @machine, env: application_env, timeout: @suite_timeout, stack: @stack).first
        @style_at_base = result
        stages << Record::Command.new(stage: Record::CHECK,
          command: "#{policy.check} (at the base commit)", ran: result.ran,
          exit_code: result.exit_code, seconds: result.seconds,
          output_tail: "the base commit, before any edit this rung makes: #{result.output_tail}")
        @out.puts("  style: #{policy.check} at the base commit — #{result.status}") if @out
        stages.last
      end

      # **A check the base commit already failed is not this rung's failure.** The suite's rule is
      # the same one — `Record.verdict` calls a move unmeasurable against a red baseline — and a
      # check is no different. Diaspora's own lint job runs `pronto` over the lines a pull request
      # changed and never the whole tree, so `bundle exec rubocop` answers 444 offences on a clean
      # `develop`; left as `failed`, every rung of that walk would stop on debt the rung did not
      # incur and the record would blame the move for it. `preexisting` says which: it is not green,
      # it does not block the verdict, and the base exit code and this run's are both in the record.
      def preexisting_style(result)
        base = @style_at_base
        return result if base.nil? || !base.ran || base.passed?

        policy = @project&.style
        return result if policy.nil? || result.command != policy.check || !result.failed?

        result.status = Checks::PREEXISTING
        result.reason = "the base commit already failed this check (exit #{base.exit_code}), so " \
                        "the rung is neither blamed nor credited for it"
        result
      end

      # **The application's formatter, run as part of the step and before the suite.** A style
      # commit made after the suite passed is a change the suite never saw; running it here makes
      # the delivered head the tree that was measured. `format` may write — that is what a
      # formatter is for — and a formatter that fails is a required stage, so the rung fails with
      # the formatter's own exit code rather than publishing unformatted output.
      def style_stage(stages)
        policy = @project&.style
        return if policy.nil? || policy.format.to_s.empty?

        # **A tree that arrived unformatted is not this rung's to format.** `style_baseline` asked
        # the check half of the pair of the base commit; a red answer means the formatter would be
        # rewriting the application, not the move — 881 files inspected and 444 offences on
        # diaspora's `develop`, and the whole-tree run is exactly how the unsafe correction reached
        # a file the rung never touched. The skip is in the record through the check's
        # `preexisting` status rather than as a formatter stage that did not run, because a stage
        # that did not run is `unverified` and this rung's formatting is not unmeasured — it was
        # measured at base and was already red.
        if @style_at_base&.ran && !@style_at_base.passed?
          @out.puts("  style: skipped — the base commit already fails #{policy.check}") if @out
          return nil
        end

        @control&.check!

        announce(Record::STYLE, policy.format)
        result = @tests.run(@worktree.root,
          Tests::Suite.new(kind: :check, command: policy.format,
            reason: "the project declares this formatter"),
          timeout: @suite_timeout, env: application_env, machine: @machine, stack: @stack)
        stages << Record::Command.new(stage: Record::STYLE, command: policy.format,
          ran: result.ran, exit_code: result.exit_code, seconds: result.seconds,
          output_tail: result.output_tail)
        @out.puts("  style: #{Tests.summary(result)}") if @out
      end

      # **The application's own preparation, as a declared list.** A project whose CI runs
      # `db:test:prepare`, `test:prepare` or `yarn install` before its tests says so here; the step
      # runs them after the built-in database/javascript stages and before the baseline, so the
      # suite is measured in an environment the project prepared rather than one this walker
      # guessed. A required prepare failure is carried into the verdict as a failed check.
      def prepare_checks_stage(stages)
        return [] if @project.nil?

        definitions = @project.checks.select { |check| check.kind == "prepare" }
        return [] if definitions.empty?

        results = Checks.run(root: @worktree.root, checks: definitions, machine: @machine,
          env: application_env, timeout: @suite_timeout, stack: @stack, out: @out)
        results.each do |result|
          stage = Checks.stage(result)
          stages << stage if stage
        end
        results
      end

      # **The rest of the application's gate.** The suite is the first check and is already in the
      # record as `baseline`/`suite`; `checks` is what the suite alone was hiding. The style check
      # is folded in here when the project declares one, so the formatter and its verifier cannot
      # disagree about which command they mean.
      def checks_stage(stages)
        return [] if @project.nil?

        # **A prepare step runs before the baseline, not after the suite.** `kind: "prepare"` is the
        # application's own `db:test:prepare` / `yarn install`; running it after the suite would be
        # preparing a tree the suite has already judged. It is collected in `prepare_checks_stage`
        # and carried into the same check list, so the verdict sees it and the PR renders it.
        definitions = @project.checks.reject { |check| check.kind == "prepare" }
        style = @project.style
        if style && !style.check.to_s.empty? &&
            definitions.none? { |check| check.id == "style" || check.command == style.check }
          definitions << Project::Check.new(id: "style", name: "style", kind: "lint",
            command: style.check, required: true, external: false, environment: nil, reason: nil)
        end
        return [] if definitions.empty?

        results = Checks.run(root: @worktree.root, checks: definitions, machine: @machine,
          env: application_env, timeout: @suite_timeout, stack: @stack, out: @out)
        results = results.map { |result| preexisting_style(result) }
        results.each do |result|
          stage = Checks.stage(result)
          stages << stage if stage
        end
        summarised = results.map { |result| "#{result.id}: #{result.status}" }.join(", ")
        @out.puts("  checks: #{summarised}") if @out
        results
      end

      # **A concern-sized commit, and the reason the tree's HEAD is the record's head.** A walk
      # that publishes one "as this tool made it" commit asks a reviewer to read five concerns at
      # once. The commits are made where the tree changes, so the branch is a sequence a person can
      # review one at a time; the patch is still the whole diff against the base (`capture_patch`),
      # and the ledger's key stays the base commit because the move is the same move.
      def checkpoint(concern)
        return if @worktree.nil? || !File.exist?(File.join(@worktree.root.to_s, ".git"))
        return unless Checkpoint.dirty?(@worktree.root)

        commit = Checkpoint.commit(@worktree.root, from: @from, to: @rung_to, out: @out,
          concern: concern)
        @commits << { "concern" => concern, "commit" => commit.to_s,
                      "message" => Checkpoint.message(from: @from, to: @rung_to, concern: concern) }
        @out.puts("  checkpoint: #{concern || "the step"} — #{commit.to_s[0, 8]}") if @out
      end

      # The project's accepted decisions, as effects on the tree — before the baseline, so the
      # application is measured as it is with its decisions in force. Nothing is applied that no
      # operator accepted, and a condition this build does not understand refuses rather than applies;
      # both rules live in `Effects`, beside the write they protect.
      #
      # **`phase` is the difference between a decision and a repair.** A pre effect is how the
      # application is and belongs before the baseline; a post effect is a repair of the move and is
      # applied after `app:update`. The caller names which pass it is, and an empty pass records no
      # stage — "0 effects" twice would read as a pass that did something.
      def decisions_stage(stages, step, phase: "pre", stage: Record::DECISIONS)
        decisions = @project&.decisions
        return if decisions.nil? || decisions.empty?

        result = Effects.new(root: @worktree.root, rung: step["to_version"],
          source_roots: source_roots).apply(decisions, phase: phase)
        return if result.empty?

        @applied.concat(result.applied)
        @refused.concat(result.refused)
        # **A rule that fires is recorded, and a rule that only waits is not.** `skip` fires only
        # when this rung carries the change it names — a rule for another project's change did
        # nothing here; `expect` waits for the failure and is added by `build` only if this run's
        # output is the failure it names. Both carry their decision id, which is the id the run
        # body already sends.
        result.rules.each do |rule|
          key = rule["change_key"].to_s
          case rule["kind"].to_s
          when "expect"
            @expected_rules << rule
          when "skip"
            @skipped_keys << key unless key.empty?
            @fired_rules << rule if @plan_changes.any? { |change| change["change_key"].to_s == key }
          else
            @fired_rules << rule
          end
        end
        stages << Record::Command.new(stage: stage,
          command: "decisions: #{result}",
          ran: true, exit_code: result.refused.empty? ? 0 : 1, seconds: 0.0,
          output_tail: result.applied.map { |edit|
            "#{edit.path}:#{edit.line} (#{edit.origin})"
          }.concat(result.rules.map { |rule|
            "rule #{rule["kind"]} #{rule["change_key"]} (decision:#{rule["decision_id"]})"
          }).concat(result.refused.map { |refusal| "refused: #{refusal.reason}" }).join("\n"))
        @out.puts("  #{result}") if @out
      end

      # Ask the service which call sites this step needs, then apply the mechanical half. The
      # manual half is a decision for a person and travels in the record as one —'s fifth
      # rule: a refusal is an output.
      def apply(stages, step)
        # **A skipped change is not scanned, not surveyed and not a decision.** The service's scan
        # is a window read and has no change-key filter, so the skip is applied to what the window
        # returns: the plan's change leaves the rule/survey lists, and a located edit whose subject
        # belongs only to a skipped change is dropped. A subject two changes share is kept, because
        # the other change is still work.
        changes = changes_for(step)
        files = source_files
        if files.empty?
          stages << Record::Command.new(stage: Record::APPLY, command: "no Ruby source found to scan",
            ran: false, exit_code: nil, seconds: 0.0,
            # **A bridge and a survey are skipped here too, and that is said rather than silent**: both
            # read the files the scan would have sent, so a repository with none gets neither. It is the
            # degenerate case — a Rails application has Ruby — but a stage that quietly did less than its
            # name says is the shape the design notes keep paying for.
            output_tail: "no bridge declared, no survey run and no rule's own file read: all three " \
                         "read what the scan would have sent")
          # The plan's half is still this step's half: a repository with no Ruby source
          # this tool reads has not thereby moved, and the changes no machine may make
          # are exactly the ones a person still has to.
          return [[], [], decisions_for(step, nil, changes: changes)]
        end

        corpus = @corpus || Corpus.new(base: @api)
        scan = corpus.scan(from: scan_from(step, corpus), to: step["to_version"], files: files)
        scan = scan.merge("edits" => skip_edits(scan["edits"], step),
          "manual" => skip_edits(scan["manual"], step))
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
        # **The scan's byte budget stops before `config/`, and a rule that flips a framework default
        # needs the application's own `load_defaults` line.** Reading it here rather than widening the
        # scan keeps the scan's bound and gives the rule the one fact that says whether the change is
        # already in force; a rule that guessed from the rung would be wrong for an application that
        # declares 6.1 and never ran the 5.0 rung's work.
        application = File.join(@worktree.root, "config", "application.rb")
        if File.file?(application)
          named["config/application.rb"] = File.read(application, encoding: "utf-8").lines.map(&:chomp)
        end
        tree = file_lines(files).merge(named)
        rules = Rewrites.apply(manual, files: tree, sources: named, changes: changes,
          rung: step["to_version"])
        inert = Rewrites.inert(changes)
        # **What the surveys found, before the decisions are built** — the evidence travels *in* the
        # decision rather than beside it, because a residue read one line at a time is what a person
        # actually works from.
        evidence = Rewrites.survey(changes, tree: tree, located: manual)
        # A rule that *knows* the change and would not touch this line is the most specific thing
        # anything downstream can be told, so it is kept rather than counted: the repair agent's
        # brief carries it (`Repair#prompt_for`).
        @unapplied_rules = rules.left
        result = @applier.new(@worktree.root).apply((scan["edits"] || []) + rules.edits)
        created = write_scaffolds(rules.scaffolds)
        created += write_scaffolds(Zeitwerk.spellings(root: @worktree.root, rung: rung_of(step)))
        # **The changes whose fix is a gem**, applied to the call sites the scan located: the call
        # sites need no edit, so what handles them is a declaration in the application's Gemfile.
        declared, bridged = declare_bridges(
          Rewrites.bridges(manual, changes: changes, tree: bridge_evidence)
        )
        handled = rules.applied + bridged + bridges_the_gemfile_answers
        decisions = decisions_for(step, scan, evidence: evidence, changes: changes).reject do |decision|
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

      # The plan's changes with the ones a `skip` rule named removed. The key is the join, so a
      # change the plan does not name is not filtered by subject — a rule for another project's
      # change cannot silently hide this application's unrelated work.
      def changes_for(step)
        changes = Array(step["changes"])
        return changes if @skipped_keys.empty?

        changes.reject { |change| @skipped_keys.include?(change["change_key"].to_s) }
      end

      # A scan edit whose change a skip rule named. The scan entry's own `change_key` wins when the
      # service sends one; otherwise the subject is mapped through the plan's changes, and only a
      # subject that no kept change carries is dropped.
      def skip_edits(edits, step)
        entries = Array(edits)
        return entries if @skipped_keys.empty?

        all = Array(step["changes"])
        skipped_subjects = all.select { |change| @skipped_keys.include?(change["change_key"].to_s) }
          .map { |change| change["subject"].to_s }
        kept_subjects = all.reject { |change| @skipped_keys.include?(change["change_key"].to_s) }
          .map { |change| change["subject"].to_s }
        skipped_subjects -= kept_subjects
        entries.reject do |entry|
          key = entry["change_key"].to_s
          key.empty? ? skipped_subjects.include?(entry["subject"].to_s) : @skipped_keys.include?(key)
        end
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
      # the outside, which is the shape the design notes keep paying for.
      def apply_summary(result, decisions, rules, inert, created = [], declared = [])
        # **The stage's count has the same three buckets the record's summary does**, for the same
        # reason: a change the survey read and found no call site for is not a question, and a
        # stage tail that counted it as one is the sentence a reviewer learns to skip.
        unused = decisions.count(&:checked?)
        parts = ["applied #{result.applied.size}, refused #{result.refused.size}, " \
                 "#{decisions.size - unused} change(s) need a decision"]
        parts << "#{unused} change(s) this application does not use" if unused.positive?
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
        sources, @truncated_sources = Rewrites.source_files(root: @worktree.root,
          source_roots: source_roots)
        sources
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
      def decisions_for(step, scan, evidence: {}, changes: nil)
        found = (scan && scan["manual"] || []).group_by { |entry| entry["subject"].to_s }
        carried = Array(changes || step["changes"]).reject { |change| change["automatic"] }

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
      # **A change this application does not use is not a gap.** The gap sentence answers "what
      # would close this", and where the survey read the tree and found none, the answer is
      # "nothing here" — the change is carried because the rung documents it, not because a line
      # is owed. Measured on the walk's last rungs: `alias_attribute` and
      # `config.active_job.queue_adapter in tests` were carried with "not automated yet: …" beside
      # a survey whose whole answer was "none found", which reads as work somebody skipped. The
      # record counts these apart (`Record::Decision#checked?`) and the summary says so, because a
      # list that says "needs a decision" over changes that need no edit is how a reviewer learns
      # to skim the list.
      UNUSED_CHANGE = "nothing to edit here: this rung carries the change and no line of this " \
                      "application uses it"

      def decision(change, entry, evidence: {}, rung: nil, from: nil)
        subject = ((change && change["subject"]) || entry["subject"]).to_s
        # **The gap travels with the change, and that is the point of it.** A change no rule covers
        # is not a verdict about the application: it is a queue entry, and `Rewrites.gap_for` says
        # what would close it — so the next lighthouse (or the next agent) starts from what is
        # missing rather than from the same blank list. A permanent refusal is the settled-work trap
        # with the sign flipped (`Step#no_interpreter_stamp` is the same posture one layer down).
        found = evidence[subject]
        unused = entry.nil? && found && found.findings.empty?
        gap = Rewrites.gap_for(subject)
        reason = [change && change["note"], entry && entry["note"]]
                 .compact.reject { |note| note.to_s.empty? }.uniq.join(" — ")
        reason = [reason, earlier_rung(entry, rung, from), survey_note(found),
                  unused ? UNUSED_CHANGE : (gap && "not automated yet: #{gap}")]
                 .compact.reject(&:empty?).join(" — ")
        Record::Decision.new(
          path: entry && entry["path"], line: entry && entry["line"],
          subject: subject, reason: reason, checked: unused,
          kind: (change && change["kind"]) || (entry && entry["kind"]),
          replacement: (change && change["replacement"]) || (entry && entry["replacement"]),
          source: (change && change["source"]) || (entry && entry["source"]),
          # The component and key are the plan's join, carried so a decision can be read against
          # the change it is about rather than only by its subject. An unplanned call site has
          # neither, which is the honest answer: the ladder does not document it.
          component: change && change["component"],
          change_key: (change && change["change_key"]) || (entry && entry["change_key"])
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
      # empty answer that means four things (`/api/rails/scan`'s own caveat).
      def source_files
        root = @worktree.root
        paths = scan_paths(root).reject do |path|
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

      # **Where the application's source is, from the project rather than from a convention.** An
      # absent `source_roots` keeps the repository-wide read a declaration written before the field
      # means; a declared list scopes the scan to those directories and still sends the root-level
      # files (`config.ru`, `Rakefile`) a Rails application may need. A modular monolith that keeps
      # its models under `components/*/app/models` declares `components` and the scan sees them.
      def scan_paths(root)
        roots = source_roots
        return Dir.glob("**/*", base: root) if roots.empty?

        root_files = Dir.glob("*", base: root).select { |path| File.file?(File.join(root, path)) }
        rooted = roots.flat_map { |dir| Dir.glob(File.join(dir, "**", "*"), base: root) }
        (root_files + rooted).uniq
      end

      # **The directories this step reads, and the suite is one of them.** `source_roots` is the
      # project's declaration, and a declaration written before detection named the suite (a project
      # connected at 4.0 has `app lib config`) is not a statement that the tests may not be read — it
      # is a declaration made before the walker had a rule that reads them. The 5.0 rung is where that
      # stopped being a detail: `assigns` and `assert_template` left Action Pack for
      # `rails-controller-testing`, every call site is in `spec/`, and with the suite unscanned the
      # bridge that declares the gem never fired and eleven controller specs failed. New connections
      # detect `spec`/`test` themselves (`ProjectDetection::SOURCE_ROOT_CANDIDATES`); this is the same
      # fact for the projects already connected, read from the tree rather than from the row.
      #
      # An empty declaration stays empty: repository-wide is what a project with no roots means, and
      # the caller turns `[]` into the whole tree.
      def source_roots
        declared = Array(@project&.source_roots).map(&:to_s).reject(&:empty?)
        return [] if declared.empty?

        suites = %w[spec test].select { |dir| File.directory?(File.join(@worktree.root, dir)) }
        (declared + suites).uniq
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
          return Record.refused(repository: @repository, commit: record_commit,
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
        resolved = pin(stages)
        return nil if resolved.ok?

        # **A pin that could not resolve is the end of the rung.** Continuing was the bug that
        # made one missing release look like four: after a failed pin the bundle still names the
        # release the move left, so `app:update` cannot start, the boot cannot load the
        # application, and the suite fails on the missing gem rather than on the move. On
        # diaspora that produced a pin question plus an app:update, a boot and a suite question,
        # all four the same fact. The record stops where the resolver did, and the block that
        # goes with it is the pin's.
        verdict, why = Record.verdict(baseline: @baseline, suite: nil, stages: stages)
        build(step, stages, verdict, why)
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
        # **`ruby` is not a gem this lock pins, and a gem that requires a newer Ruby is not
        # unlocked by naming it.** The last real run named `figaro` because it was the requirer
        # on a `ruby (>= 2.5.0)` conflict, which updated figaro to 1.3 and made the Ruby 2.1
        # resolve impossible. Filtering the conflicted names through the lock before the
        # requirer scan drops `ruby` (and `bundler`) while keeping every gem the pin can move.
        named = (quoted + bare) & @lockfile.specs.keys
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
      # **A component the target release no longer ships is not a component to update.** Rails
      # 4.0 extracted ActiveResource, so a 3.2 lock's `activeresource (3.2.22.5)` is pinned at the
      # starting version and `pin_gems` named it alongside `rails (= 4.0.13)`. Bundler then asked
      # for a release that satisfies both, and no activeresource release does: 4.0.0 asks
      # `activesupport (= 4.0.0)` and the last 4.x is 4.1.0, which asks 4.1. The message was
      # `Could not find gem 'activeresource'` — a component that had left the framework, not a
      # missing gem. The map names the release that retired each component, and a lock below that
      # release keeps its line for the rung that still has the component.
      RETIRED_FRAMEWORK_COMPONENTS = { "activeresource" => "4.0" }.freeze

      def pin_gems
        components = @lockfile.pinned_at(@from).reject { |name| retired_framework_component?(name) }
        ["rails", *components].uniq
      end

      def retired_framework_component?(name)
        retired = RETIRED_FRAMEWORK_COMPONENTS[name.to_s]
        return false if retired.nil?

        target = Gem::Version.new(rung_to.to_s[/\d+(?:\.\d+)*/].to_s)
        target >= Gem::Version.new(retired)
      rescue ArgumentError
        # An unreadable target is not evidence that the component left; the pin keeps the line
        # it found, which is the safe answer for a release this build cannot place.
        false
      end

      # Pure, and its own method, because it is the one thing that rewrites a line of
      # somebody's Gemfile and a test can hold it still.
      def rewrite_pin(text, version)
        # **The 7.0 rung's first release does not boot on the 3.2 era.** Activesupport
        # 7.0.0's DescendantsTracker asks Railtie for descendants and, on 3.2, falls through
        # to Railtie.instance, which instantiates the abstract engine; the 7.0 line's later
        # patches fixed it. A patch release is the same rung — the ladder's line is 7.0 —
        # so a 3.2 walk pins the line rather than the first release. An older era keeps the
        # exact release, where the first release is the one that was measured.
        pin = version.to_s
        pin = "~> #{pin}" if pin == "7.0.0" && @machine.respond_to?(:era) &&
                             @machine.era.to_s.start_with?("3.2")
        lines = text.lines
        found = lines.index { |line| line =~ /^\s*gem\s+["']rails["']/ }
        return nil unless found

        line = lines[found]
        if line =~ /^(\s*gem\s+["']rails["']\s*,\s*)(["'])([^"']*)(\2)/
          lines[found] = "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{pin}#{Regexp.last_match(4)}\n"
        elsif line =~ /^(\s*gem\s+["']rails["'])(\s*)$/
          lines[found] = "#{Regexp.last_match(1)}, \"#{pin}\"\n"
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
            command: @stack.update_command(five_or_newer: five_or_newer?),
            ran: false, exit_code: nil, seconds: 0.0,
            output_tail: @stack.no_update_reason)
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
        stage = nil
        begin
          stage = command(Record::RAILS_UPDATE, runner + [task], chdir: @worktree.root,
            env: @stack.development_env(application_env),
            stdin: answers)
          stages << stage
        ensure
          answers.close
        end
        @adopted, @conflicts = self.class.adopt_added_only(@worktree.root, before)
        # **A conflict the prompt answered `n` to is still a conflict.** `adopt_added_only`
        # sees only the files the generator actually changed; the ones it asked about and
        # the walker declined are left untouched, so they never reach that comparison. The
        # 4.1 rung's body therefore said “0 conflict(s)” while the task's own output listed
        # eight — and a reviewer had no way to know which files kept the 4.0 version.
        @conflicts = (@conflicts + self.class.update_conflicts(stage&.output_tail)).uniq
        apply_app_update_policy(@adopted)
        drop_engine_migrations(@adopted) if @project.nil? || @project.app_update.skip_unused_engines
        reconcile_app_update
      end

      # **A generated default is not a migration.** `app:update` writes what a *new*
      # application should have; this application existed before the rung and has its own
      # secret and its own cookies. The two files where that difference is load-bearing are
      # reconciled here, before the `run app:update` checkpoint, so the commit and the PR
      # carry the application's answer rather than the release's default.
      def reconcile_app_update
        applied, refused, reconciled = self.class.reconcile_app_update(
          root: @worktree.root, adopted: @adopted, rung: rung_to
        )
        @applied.concat(applied)
        @refused.concat(refused)
        @app_update_reconciled = Array(@app_update_reconciled) + reconciled
      end

      # **What the project says it does not want `app:update` to write.** A skip is a project fact
      # — an application that keeps its own `config/storage.yml`, a generated file its CI owns — and
      # it is applied after the added-only adoption, so a skipped path is removed and the reason is
      # carried in the record rather than left for a reader to infer from its absence.
      def apply_app_update_policy(adopted)
        policy = @project&.app_update
        return if policy.nil? || policy.skip.empty?

        adopted.dup.each do |path|
          next unless policy.skip?(path)

          File.delete(File.join(@worktree.root, path)) if File.file?(File.join(@worktree.root, path))
          @adopted.delete(path)
          @app_update_skipped << { "path" => path,
            "reason" => "the project's app_update policy skips it (#{policy.skip.join(", ")})" }
        end
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
          @app_update_skipped << { "path" => path,
            "reason" => "it is a migration for #{engine}, and this application's db/schema.rb " \
                        "declares no #{engine}_* table" }
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
                  "assumes. Install the component first (`#{@stack.install_command(engine)}`) if the " \
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
      def update_runner = @stack.app_update(@worktree.root, five_or_newer: five_or_newer?)

      # The Rails version the application is *on* — the one whose commands would run, read from
      # the lockfile the step opened before anything was written. `major >= 5` is the whole
      # rule: every command that moved did so at 5.0, and an application on a pre-release
      # (`4.0.0.rc1`) is on 4.
      def five_or_newer? = @stack.five_or_newer?(@lockfile)

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
      # **The prompt's conflicts are a fact, even when the answer is `n`.** The task prints
      # `conflict  config/application.rb` and then asks to overwrite; the step answers `n`
      # for every one, so the file is unchanged and `adopt_added_only` cannot see it. This
      # parser is what puts those paths in the record. ANSI is stripped because the task
      # colors the label and the raw line would otherwise not match.
      def self.update_conflicts(output)
        text = output.to_s.gsub(/\e\[[0-9;]*m/, "")
        text.scan(/^\s*conflict\s+(\S+)/).flatten.uniq
      end

      # **The two generated files whose new-application default is wrong for an old one.**
      #
      # `app:update` writes what a *new* application should have. A 4.0 application that
      # arrives at 4.1 is not new: its sessions are Marshal-serialized cookies, and its
      # `secret_key_base` is an `ENV[...]` in `config/initializers/secret_token.rb`. The
      # release's defaults would invalidate every cookie (`:json`) and leave two key
      # sources (`SECRET_KEY_BASE` in `secrets.yml`, `RAILS_SECRET_TOKEN` in the
      # initializer).
      #
      # The rules are deliberately evidence-scoped:
      # * the cookie file is only rewritten when **app:update adopted it** and it carries
      #   the generated `:json`; an application that already owned the file chose its value;
      # * the 4.1 transition is `:hybrid` — read Marshal, write JSON — and the next rung
      #   completes it to `:json`, because a 4.1 deployment has had one release for the old
      #   cookies to age out;
      # * the secret is only moved when the old initializer names an `ENV[...]`; a literal
      #   or a shape this cannot parse becomes a refusal, not a guess.
      #
      # Returns the same three lists the rest of the step records: applied edits, refusals
      # a person must answer, and the app:update section's reconciliation notes.
      def self.reconcile_app_update(root:, adopted:, rung:)
        applied = []
        refused = []
        reconciled = []
        version = begin
          Gem::Version.new(rung.to_s)
        rescue ArgumentError
          nil
        end

        cookies = File.join(root, "config", "initializers", "cookies_serializer.rb")
        cookies_rel = "config/initializers/cookies_serializer.rb"
        if File.file?(cookies)
          text = File.binread(cookies)
          lines = text.lines
          index = lines.index { |line| line.match?(/cookies_serializer\s*=\s*:(json|hybrid)\b/) }
          current = index && lines[index][/cookies_serializer\s*=\s*:(json|hybrid)\b/, 1]
          if current
            target = if adopted.include?(cookies_rel) && current == "json" &&
                version && version >= Gem::Version.new("4.1") && version < Gem::Version.new("4.2")
              "hybrid"
            elsif version && version >= Gem::Version.new("4.2") && current == "hybrid"
              "json"
            end
            if target
              before = lines[index]
              after = before.sub(/:(?:json|hybrid)\b/, ":#{target}")
              lines[index] = after
              File.binwrite(cookies, lines.join)
              applied << Applier::Applied.new(path: cookies_rel, line: index + 1,
                text: before.chomp, after: after.chomp, subject: "cookies_serializer",
                origin: "app_update",
                note: target == "hybrid" ?
                  "Rails 4.1 generates `:json` for a new application. This application's 4.0 " \
                  "cookies are Marshal-serialized, so `:hybrid` reads both while writing JSON; " \
                  "the next rung completes the move to `:json` once those cookies have aged out." :
                  "The 4.1 transition wrote JSON cookies; this rung completes it with `:json`.")
              reconciled << {
                "path" => cookies_rel,
                "note" => target == "hybrid" ?
                  "set to `:hybrid` for the 4.1 transition; the next rung completes it" :
                  "completed the 4.1 transition to `:json`"
              }
            end
          end
        end

        secrets = File.join(root, "config", "secrets.yml")
        secrets_rel = "config/secrets.yml"
        legacy = File.join(root, "config", "initializers", "secret_token.rb")
        legacy_rel = "config/initializers/secret_token.rb"
        if adopted.include?(secrets_rel) && File.file?(secrets) && File.file?(legacy)
          legacy_lines = File.binread(legacy).lines
          index = legacy_lines.index { |line| line.match?(/secret_key_base\s*=\s*ENV\[["'][A-Za-z0-9_]+["']\]/) }
          line = index && legacy_lines[index]
          name = line && line[/secret_key_base\s*=\s*ENV\[["']([A-Za-z0-9_]+)["']\]/, 1]
          if name.nil?
            refused << Applier::Refused.new(path: legacy_rel, line: index ? index + 1 : nil,
              text: line&.chomp, found: line&.chomp,
              reason: "the 4.0 initializer does not name an ENV variable for `secret_key_base`, " \
                      "so this tool cannot move the same key into `config/secrets.yml`",
              subject: "secret_key_base", kind: "config", replacement: nil,
              source: "Rails 4.1", note: "A literal key stays where it is; a person must decide " \
                      "which source the deployment should use.")
          else
            secrets_lines = File.binread(secrets).lines
            secret_index = secrets_lines.index { |text| text.match?(/ENV\[["']SECRET_KEY_BASE["']\]/) }
            if secret_index.nil?
              refused << Applier::Refused.new(path: secrets_rel, line: nil, text: nil, found: nil,
                reason: "the generated `config/secrets.yml` does not name `SECRET_KEY_BASE`, so " \
                        "this tool cannot point it at the key the application already uses",
                subject: "secret_key_base", kind: "config", replacement: nil,
                source: "Rails 4.1", note: "The old initializer remains; a person must reconcile " \
                        "the two key sources.")
            else
              before = secrets_lines[secret_index]
              after = before.gsub(/ENV\[(["'])SECRET_KEY_BASE\1\]/) do
                quote = Regexp.last_match(1)
                "ENV[#{quote}#{name}#{quote}]"
              end
              if after == before
                refused << Applier::Refused.new(path: secrets_rel, line: secret_index + 1,
                  text: before.chomp, found: before.chomp,
                  reason: "`config/secrets.yml` names `SECRET_KEY_BASE`, the same name the " \
                          "application's initializer does not use",
                  subject: "secret_key_base", kind: "config", replacement: nil,
                  source: "Rails 4.1", note: "The old initializer remains; there is nothing to move.")
              else
                secrets_lines[secret_index] = after
                File.binwrite(secrets, secrets_lines.join)
                applied << Applier::Applied.new(path: secrets_rel, line: secret_index + 1,
                  text: before.chomp, after: after.chomp, subject: "secret_key_base",
                  origin: "app_update",
                  note: "the production key is the same `ENV[#{name}]` the 4.0 initializer used, " \
                        "so the deployment keeps one key across the rung")
                File.delete(legacy)
                applied << Applier::Applied.new(path: legacy_rel, line: index + 1,
                  text: line.chomp, after: nil, subject: "secret_key_base",
                  origin: "app_update",
                  note: "removed; its key now lives in `config/secrets.yml`")
                reconciled << {
                  "path" => secrets_rel,
                  "note" => "production reads `ENV[#{name}]`, the same key the 4.0 initializer used"
                }
                reconciled << {
                  "path" => legacy_rel,
                  "note" => "removed; the key now lives in `config/secrets.yml`"
                }
              end
            end
          end
        end

        [applied, refused, reconciled]
      end

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

      # The stage rather than nil, because the failure it carries is what `missing_gems` reads.
      def boot(stages)
        argv = @stack.boot(@worktree.root)
        return nil if argv.nil?

        stages << command(Record::BOOT, argv, chdir: @worktree.root, env: application_env)
        stages.last
      end

      # **A boot that cannot load a gem the application used to have.** A gem the application's
      # own code requires arrives transitively until the move takes the gem that provided it across
      # a major version: measured at diaspora's 7.1 rung, `devise-two-factor 4.1.0` depends on
      # `attr_encrypted` and `~> 6.3.1` does not, so `bin/rails runner` answered `LoadError: cannot
      # load such file -- attr_encrypted` from `app/models/user.rb` while the Gemfile had never
      # declared it. `MissingGems` reads the two facts out of the tree and writes the declaration;
      # this loop installs what it added and asks the boot again, because a Gemfile line is a
      # claim and the boot is the measurement.
      #
      # **The version is the base commit's**, not whatever the resolver would pick now — the
      # application was never measured against the newer release, and a repair is allowed to
      # restore a fact rather than introduce one.
      MAX_MISSING_GEM_ROUNDS = 3

      # **A Gemfile line this step moved, whose lock the pin did not follow.** A declaration can
      # rewrite `gem 'ransack'` to `~> 1.4.1` after the pin's `bundle update` list was built, so the
      # lock still holds 1.0.0 and the boot answers `Could not find gem 'ransack (~> 1.4.1)'`.
      # Measured on 19wu's 4.1.16 rung: the first boot failed on ransack 1.0.0's adapter, the
      # declaration moved the line, and the second boot could not find the release the lock never
      # installed. Bundler's own sentence names the gem, and the conservative update is the pin's
      # own mechanism; the boot is the gate.
      MAX_STALE_LOCK_ROUNDS = 3
      STALE_LOCK = /Could not find gem '([A-Za-z0-9_.-]+)/

      def stale_lock(stages)
        return if @boot.nil? || @boot.ok?

        rounds = 0
        while rounds < MAX_STALE_LOCK_ROUNDS && @boot && !@boot.ok?
          name = @boot.output_tail.to_s[STALE_LOCK, 1]
          break if name.nil?

          @control&.check!
          @out&.puts("  repair: the Gemfile asks for #{name} and the lock does not have it; " \
                     "bundle update #{name}")
          attempt = conservative_update(stages, [name], stage: Record::PIN)
          break unless attempt.ok?

          rounds += 1
          checkpoint("move #{name} to the line the Gemfile asks for")
          @boot = boot(stages)
        end
      end

      def missing_gems(stages)
        return if @boot.nil? || @boot.ok?

        before = @boot
        applied = []
        rounds = 0
        while rounds < MAX_MISSING_GEM_ROUNDS && @boot && !@boot.ok?
          edit = MissingGems.for(output: @boot.output_tail, root: @worktree.root, lock: @lockfile)
          break if edit.nil?

          @control&.check!
          result = Applier.new(@worktree.root).apply([edit])
          @applied.concat(result.applied)
          @refused.concat(result.refused)
          break if result.applied.empty?

          applied.concat(result.applied)
          rounds += 1
          stages << Record::Command.new(stage: Record::REPAIR,
            command: "boot repair: declare a gem the boot could not load",
            ran: true, exit_code: 0, seconds: 0.0,
            output_tail: result.applied.map { |each| "#{each.path}:#{each.line} — #{each.note}" }
              .join("\n"))
          @out.puts("  repair: #{edit["path"]}:#{edit["line"]} — #{edit["note"]}") if @out

          install = command(Record::BUNDLE, ["bundle", "install"], chdir: @worktree.root,
            env: application_env)
          stages << install
          break unless install.ok?

          checkpoint("declare the gem the boot could not load")
          @boot = boot(stages)
        end
        return unless rounds.positive? && @boot&.ok?

        outcome = Repair.mechanical_outcome(applied: applied, failure: before.output_tail,
          suite: before.readable, gate: "the boot")
        @repairs << outcome unless outcome.nil?
      end

      # The patch, for a person to apply. Untracked files are included, because
      # `app:update`'s added files are part of what this step did.
      #
      # **Against the base commit, not the index.** The step commits its concerns as it goes
      # (`checkpoint`), so a `git diff` with no revision would show only what the last concern
      # left uncommitted. The reviewable unit is still one rung, and that is the diff from the
      # commit the tree arrived at.
      def capture_patch
        Open3.capture2e("git", "-C", @worktree.root, "add", "--intent-to-add", "--all")
        base = @base_commit.to_s
        base = @worktree.commit.to_s if base.empty? && @worktree.respond_to?(:commit)
        argv = ["git", "-C", @worktree.root, "diff"]
        # **A base that is not a revision in this copy is not a base this diff can use.** A test
        # hands a step a worktree whose `commit` is a label rather than an object; a real kept tree
        # names a commit. Asking git whether the object exists is cheaper than a rescue around the
        # diff, and it keeps the whole-step patch for the trees that have one.
        if !base.empty? && Open3.capture2e("git", "-C", @worktree.root, "rev-parse", "--verify",
          "--quiet", "#{base}^{commit}").last.success?
          argv << base
        end
        output, _status = Open3.capture2e(*argv)
        output
      end

      def build(step, stages, verdict, why)
        settle_decisions_against_the_lock
        record = Record.new(
          repository: @repository, commit: record_commit, worktree: @worktree.root,
          from_version: step["from_version"], to_version: step["to_version"], name: step["name"],
          requires_ruby: step["requires_ruby"], interpreter: @machine.interpreter,
          image: @machine.image, machine: @machine.stamp,
          era: @machine.respond_to?(:era) ? @machine.era : nil,
          stages: stages, applied: @applied, refused: @refused, decisions: @decisions,
          patch: capture_patch, baseline: @baseline, suite: @suite,
          verdict: verdict, why: why, brief: @brief, repairs: @repairs,
          checks: @checks, commits: @commits,
          # Filled below, after an `expect` rule that this run met is added to the fired list: a
          # decision that shaped the rung is in force whether its evidence is an edit or a rule.
          accepted_decisions: [],
          app_update: app_update_record(step),
          toolchain: @project&.toolchain&.to_h,
          project: @project&.to_h,
          changes: @plan_changes, expected: @expected_rules, fired_rules: @fired_rules
        )
        # **An expected failure is recorded before the run is sent, because the service retires a
        # rule from the run body's decisions.** The match is against this run's own output, so a
        # rule that names a failure this rung did not produce stays in force and is not fired.
        expected = Filing.expected_rule(record: record)
        unless expected.nil? || @fired_rules.include?(expected)
          @fired_rules << expected
        end
        record.accepted_decisions.replace(accepted_decisions_in_force)
        record
      end

      # **A decision is in force on this rung only if one of its effects was applied here.** The
      # declaration carries every accepted decision the project has, including ones scoped to a
      # later release; the PR must not tell a reviewer that a decision shaped a rung it never
      # touched. The applied edits' `origin` is the record of that, and it is the same evidence the
      # service links a passed run to.
      def accepted_decisions_in_force
        ids = @applied.filter_map do |edit|
          origin = edit.respond_to?(:origin) ? edit.origin.to_s : ""
          # One grammar, in `Effects.evidence`: an effect-level origin is
          # `decision:<question_id>:<effect_id>`, and splitting on the last colon here would
          # read the effect's id as the question's.
          Effects.evidence(origin).first
        end
        # A skip or an expect changes the walk rather than the tree, so it has no applied edit to
        # carry its origin; its fired rule is the evidence that the answer shaped this rung.
        ids.concat(Array(@fired_rules).map { |rule| rule["decision_id"].to_s })
        ids = ids.reject(&:empty?).uniq
        Array(@project&.decisions).select { |decision| ids.include?(decision["id"].to_s) }
      end

      # What `app:update` did, as the PR and the durable record read it. The policy travels with
      # the outcome so a reviewer can see why a generated file was skipped, and `load_defaults`
      # is read from the tree rather than inferred from the rung — an application that declares
      # an older default has not adopted this one.
      def app_update_record(step)
        policy = @project&.app_update
        load_defaults = begin
          line = File.readlines(File.join(@worktree.root, "config", "application.rb"),
            encoding: "utf-8").find { |text| text.match?(/^\s*config\.load_defaults\s/) }
          line && line[/config\.load_defaults\s+["']?([\d.]+)/, 1]
        rescue Errno::ENOENT
          nil
        end
        {
          "adopt" => policy&.adopt || "added_only",
          "adopted" => Array(@adopted),
          "conflicts" => Array(@conflicts),
          "skipped" => Array(@app_update_skipped),
          "reconciled" => Array(@app_update_reconciled),
          "framework_defaults" => policy&.framework_defaults || "off",
          "load_defaults" => load_defaults,
          "rung" => step["to_version"]
        }
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

      # The program a script's shebang names, in the spelling the era images use: `ruby` for
      # `#!/usr/bin/env ruby`, `sh` for `#!/bin/sh`. Nil when the line names nothing this tool can
      # prefix, in which case the 126 is the honest answer.
      SCRIPT_SHELLS = %w[sh bash dash].freeze

      # **A binstub's mode bit is a fact about the checkout, not about the move.** `bin/rails` is the
      # entry point every Rails 5+ command goes through, and whether it is executable is a property of
      # how the tree reached this disk: `rails_modular_monolith` committed its whole `bin/` directory at
      # 0644 (a tree exported from an archive), and a volume mounted without file modes drops the bit
      # from files git records at 100755. Both answer `exec: "bin/rails": permission denied` (exit 126),
      # and a step reads that as the database and asset stages failing — so the baseline runs against a
      # database that was never created, the rung comes out `unverified`, and its sentence blames the
      # release for a fact about the checkout.
      #
      # The script is run through its own shebang's interpreter rather than having the tree's modes
      # changed: a `chmod` over thirty binstubs is thirty mode changes in the patch, which is a change
      # the application never asked for, and a filesystem that cannot hold the bit would lose it again on
      # the next clone. The record still reads `bin/rails …` in `display`; `command` says what ran.
      def runnable(argv, chdir)
        first = argv.first.to_s
        return argv if first.empty? || first.start_with?("/", "-") || chdir.to_s.empty?

        path = File.join(chdir.to_s, first)
        return argv unless File.file?(path) && !File.executable?(path)

        interpreter = shebang_interpreter(path)
        interpreter ? [interpreter, *argv] : argv
      end

      def shebang_interpreter(path)
        line = File.binread(path, 200).lines.first.to_s
        return nil unless line.start_with?("#!")

        words = line[2..].strip.split(/\s+/)
        words.shift if File.basename(words.first.to_s) == "env"
        words.reject! { |word| word.start_with?("-") }
        program = File.basename(words.first.to_s)
        return "ruby" if program == "ruby"
        return program if SCRIPT_SHELLS.include?(program)

        nil
      rescue SystemCallError
        nil
      end

      # Every command a step runs is bounded (`Shell::DEFAULT_COMMAND_TIMEOUT`, or the operator's
      # `UPGRADER_COMMAND_TIMEOUT`): the *suite* has its own bound through `Tests`, and nothing else had one —
      # so a container that could not reach rubygems held a step in `bundle update` until somebody noticed.
      # `excerpt_bytes` is how a caller says its output is *evidence* rather than a payload: a
      # resolver prints the blocks that name why it refused, and `Shell::RESOLVER_BYTES` keeps them all.
      # **What this step is doing, said while it does it.** Every stage goes through here — the
      # machine commands through `command`, the suite through `run_suite` — so the operator's
      # site admin shows the stage that is *running* rather than the one that finished. `@from` is
      # nil before the lockfile is read and `@worktree` before the working copy exists, so the
      # fields that are not known yet are left out rather than invented.
      def announce(stage, detail, note: "")
        # `@rung_to` only: before the plan is fetched the rung is *not known*, and `@to` is where the
        # walk is going — a panel that showed the target would be naming a move the step is not making.
        @progress.stage(repo: @repository, from: @from, to: @rung_to,
          commit: record_commit, kind: checkpoint_kind,
          era: (@machine.era if @machine.respond_to?(:era)),
          stage: stage, detail: detail, note: note)
      end

      def command(stage, argv, chdir:, env: {}, machine: nil, stdin: File::NULL,
                  excerpt_bytes: Shell::TAIL_BYTES, root: false, display: nil)
        # **The boundary the record measures.** A stop request is answered here: the command in
        # flight finishes, the next one never starts, and the exception unwinds to the loop, which
        # leaves the rung unsettled and idles. Everything the step would have written after this
        # point — the record, the patch, the verdict — is not written, because the move was not
        # measured.
        @control&.check!
        runner_machine = machine || @machine
        # **The application's own argv, kept before the machine wraps it.** The record carries both —
        # `command` is what ran and `display` is what it was asked to do — and a filed report reads
        # `display` (`Record::Command#readable`), because a reader wading through `--user 10003:999`
        # and a container id to reach "the pin exited 7" has been told the plumbing rather than the
        # fact. Nothing is dropped: the run's own page and the API's `argv` still read `command`.
        display ||= argv
        argv = runnable(argv, chdir)
        if runner_machine
          argv, env = if root && runner_machine.respond_to?(:root_command)
            runner_machine.root_command(argv, chdir: chdir, env: env)
          else
            runner_machine.command(argv, chdir: chdir, env: env)
          end
        end
        announce(stage, display.join(" "))
        result = @runner.run(argv, stage: stage, chdir: chdir, env: env, stdin: stdin,
          timeout: command_timeout, excerpt_bytes: excerpt_bytes, display: display)
        @progress.finish(stage: stage, status: status_for(result),
          exit_code: result.exit_code, duration_ms: milliseconds(result))
        result
      end

      # The timeline's word for a command's end. A command that never ran is `skipped`, not
      # `failed`: the two send a reader to different places, and a deadline or a missing binary is
      # not a verdict about the application.
      def status_for(result)
        return "skipped" unless result.ran

        # **Two result types reach this line, and they do not spell "passed" the same way.** A
        # machine command answers with `Record::Command#ok?`; the suite answers with `Tests::Result`'
        # `passed`, because a suite that never ran is a third answer rather than a failure. Reading
        # one shape off the other crashed every baseline — 116 errors from one line, which is what a
        # test suite is for.
        passed = result.respond_to?(:ok?) ? result.ok? : result.respond_to?(:passed) && result.passed
        passed ? "passed" : "failed"
      end

      def milliseconds(result)
        result.respond_to?(:seconds) && result.seconds ? (result.seconds.to_f * 1000).round : nil
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
        # Nothing is in flight once this returns, and the site admin says so rather than showing the
        # last stage for ever — a stalled-looking panel that is really a finished step is the same
        # lie in the other direction as a working loop that looks idle.
        @progress.clear
        # **The service records the run before the ledger does.** Its answer can lower the verdict
        # — a passed suite whose patch moved a test file is `unverified` until the project allows
        # that edit — and a ledger written from the local verdict would settle a rung the corpus
        # did not accept. `contribute` rescues its own unreachable/refused cases, so a service that
        # is briefly away still leaves the local record and the ledger it would have had.
        contribute(record) if @contribute
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
        # **A check or a formatter can decide the rung while the suite is green.** The verdict names
        # the check, not its command, so the stage selection above finds nothing; the decisive stage
        # is the one the report will quote, and its output is the evidence a reader needs.
        if named.empty?
          decisive = Filing.failing_stage(record: record)
          named = [decisive] if decisive && !decisive.ok? && !decisive.output_tail.to_s.empty?
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
        # `routers/api/upgrades.py`'s `identity()` canonicalises a URL and deliberately
        # leaves a bare path alone, because an operator may legitimately name a
        # directory on a machine that has it. A second opinion here — "that is not a
        # repository URL, so it is not a queue entry" — would be this tool disagreeing
        # with the only side that owns the answer.
        client = @corpus || Corpus.new(base: @api)
        answer = record_with_retry(client, record)
        run = answer.is_a?(Hash) ? answer["run"] : nil
        # The pull request can link the run's page only if it knows the service's id; it is the
        # service's answer, so it is written onto the record after the answer arrives rather than
        # invented before the request.
        record.run_id = run["id"] if run.is_a?(Hash) && run["id"]
        # **The service's verdict can be lower than the local one.** The local verdict says the
        # suite was green; the service also asks whether the run's own patch moved a test file and
        # the project allowed that edit. A walk that kept its own "passed" here committed the
        # moved tree, rewound to the origin on the next cycle, and re-walked delivered rungs —
        # measured on sample-legacy-rails-app, whose 4.2.11.3 run edited one obsolete performance
        # test. The local record now carries the verdict the corpus will use, so `settle` resets
        # to the rung's base and nothing is published.
        if run.is_a?(Hash) && !run["verdict"].to_s.empty? && run["verdict"].to_s != record.verdict.to_s
          recorded = run["verdict"].to_s
          @out.puts("  the service recorded this run as #{recorded}, not #{record.verdict}: " \
                    "#{run["note"]}") if @out
          record.reconcile!(verdict: recorded, note: run["note"])
        end
        @out.puts("  recorded: run #{run && run["id"]} (#{record.verdict})") if @out

        # **A stop becomes a question the corpus keeps.** Only a step that neither passed nor
        # was refused has work a person or an agent can answer; a refusal is settled, and a
        # passed run is evidence. Posting is best-effort for the same reason filing is: the
        # record is the product, and a service that is briefly away must not turn a measured
        # step into a crash. It needs a key, because an anonymous post is a 401 that reads like
        # a quiet walk from the outside.
        # A test's corpus is a stand-in with only the methods its subject needs; the real client
        # is the one that knows whether it carries a key. Ask only when it can answer.
        keyed = client.respond_to?(:authenticated?) ? client.authenticated? : true
        postable = client.respond_to?(:create_decision)
        post_blocks(client, record) if !record.passed? && !record.refused? && keyed && postable
        # **A repair that turned the gate green is knowledge, and it becomes a proposal.** The
        # rung passed, so nothing is blocked: the question this posts names no target and no run
        # (the service would otherwise block the target the run walked), and its account comes
        # from the project slug. A person's acceptance is what makes it a decision, and until
        # then it applies nothing — the report `Filing.file_repairs` files is still the corpus's
        # record of the failure itself.
        post_repair_proposals(client, record) if record.passed? && record.repairs.any? && keyed && postable

        filing = Filing.file(corpus: client, record: record)
        @out.puts("  filed: #{filing.action} — #{filing.reason}") if @out && filing.action != "skipped"

        # **And every repair the step performed, as a report with the repair as its fix.** A passed
        # rung whose suite was red and green again is the corpus's most useful shape — a failure an
        # application really had, and the change that resolved it — and it used to live only in this
        # record. Each one is filed through precheck, so a duplicate is the corpus's decision.
        Filing.file_repairs(corpus: client, record: record).each do |repair|
          @out.puts("  filed repair: #{repair.action} — #{repair.reason}") if @out && repair.action != "skipped"
        end
      rescue Corpus::Unreachable, Corpus::Refused => e
        # The record is the product and it exists whether or not the corpus took it, so
        # this does not change the verdict or raise. It is logged with the service's own
        # sentence rather than swallowed: a refusal that will happen every cycle looks
        # exactly like a quiet run from the outside, which is the miner's lesson about a
        # bare `rescue` around a remote call.
        @out.puts("  not recorded: #{e.message}#{refusal_detail(e)}") if @out
      end

      # The repair proposals for a passed rung, one per repair. The effects are whole files
      # (`Repair.effects_for`), and a repair whose files cannot be carried is logged and skipped
      # rather than sent in part: a proposal missing one of its edits applies a tree nobody
      # measured.
      def post_repair_proposals(client, record)
        project = @project&.slug.to_s
        project = record.project["slug"].to_s if project.empty? && record.project.is_a?(Hash)
        return if project.empty?
        return if @worktree.nil?

        Array(record.repairs).each do |repair|
          files = repair.respond_to?(:files) ? repair.files : repair["files"]
          effects, problem = Repair.effects_for(files: files, root: @worktree.root)
          if problem
            @out.puts("  repair not proposed: #{problem}") if @out
            next
          end

          failure = repair.respond_to?(:failure) ? repair.failure : repair["failure"]
          gate = repair.respond_to?(:gate) ? repair.gate : repair["gate"]
          attempts = repair.respond_to?(:attempts) ? repair.attempts : repair["attempts"]
          answer = client.create_decision(
            "project" => project,
            "rung_from" => record.from_version,
            "rung_to" => record.to_version,
            "block_kind" => "repair",
            "subject" => "repair at #{record.to_version}",
            "question" => "The walk repaired #{gate.to_s.empty? ? "the suite" : "the #{gate}"} " \
                          "on #{record.from_version} → #{record.to_version}. Should a later rung " \
                          "apply this repair?",
            "context" => { "stage" => Record::REPAIR, "files" => Array(files).map(&:to_s) },
            # The run is named at the top level as well as in the evidence: the consultant reads
            # the patch off the run it names, and a question whose `run_id` is null makes the
            # repair task carry no run at all.
            "run_id" => record.run_id,
            "evidence" => { "failure" => failure.to_s[0, 4_000], "attempts" => attempts,
                            "gate" => gate, "run_id" => record.run_id },
            "source" => "walker"
          )
          id = answer.is_a?(Hash) ? answer["id"] : nil
          if id.nil?
            @out.puts("  repair not proposed: the service returned no question") if @out
            next
          end

          # `proposed_by` is omitted deliberately: the service credits the key that proposed it,
          # which is the honourable answer for a mechanical repair no model made.
          proposed = client.propose_decision(id, {
            "choice" => "keep the repair the walk made to #{Array(files).first(3).join(", ")}",
            "effects" => effects,
            "provenance" => { "harness" => "upgrader", "run_id" => record.run_id,
                              "gate" => gate, "files" => Array(files).map(&:to_s) }
          })
          proposed_id = proposed.is_a?(Hash) ? proposed["proposed_answer"] : nil
          @out.puts("  proposed repair: question #{id} (answer #{proposed_id})") if @out
        end
      rescue Corpus::Unreachable, Corpus::Refused => e
        @out.puts("  repairs not proposed: #{e.message}#{refusal_detail(e)}") if @out
      end

      # **The blocks a stopped rung leaves behind, posted once.** `Block` owns what a block is
      # and how its identity is spelled; this method only carries them over the wire and says
      # what happened. The target id is deliberately absent: a hand-run `step` knows the
      # repository and the run, not the queue row, and the service accepts a question without
      # one. A loop that does know it should pass it here when the record grows the field.
      def post_blocks(client, record)
        project = @project&.slug.to_s
        project = record.project["slug"].to_s if project.empty? && record.project.is_a?(Hash)
        return if project.empty?

        Block.from_record(record, project: project, run_id: record.run_id).each do |payload|
          answer = client.create_decision(payload)
          id = answer.is_a?(Hash) ? answer["id"] : nil
          @out.puts("  blocked: #{payload["block_kind"]} #{payload["subject"]} (question #{id})") if @out
        end
      rescue Corpus::Unreachable, Corpus::Refused => e
        @out.puts("  blocks not recorded: #{e.message}#{refusal_detail(e)}") if @out
      end

      # **The corpus is a remote, and a rung that passed is settled.** A transient refusal — the
      # service restarting beside the walk — must not lose the run for good: measured on this
      # deployment, `5.1.0 -> 5.2.0` passed while `service:8001` was being recreated, the client logged
      # `not recorded: … ECONNREFUSED`, and the rung's run was gone for ever, because a passed move is
      # settled and never revisited. Same shape and numbers as the push and the pull request: attempt,
      # wait, attempt. A `Refused` (a 4xx) is *not* retried — the corpus read the request and said no,
      # and re-deriving it reaches the same answer.
      RECORD_ATTEMPTS = 3
      RECORD_BACKOFF_SECONDS = 5

      def record_with_retry(client, record, attempt: 1)
        client.record_run(self.class.run_payload(record))
      rescue Corpus::Unreachable => e
        raise if attempt >= RECORD_ATTEMPTS

        @out&.puts("  the run was not recorded yet (#{e.message}) — retrying")
        @pause.call(RECORD_BACKOFF_SECONDS * (2**(attempt - 1)))
        record_with_retry(client, record, attempt: attempt + 1)
      end

      # **The fields a validation refusal names.** The sentence a 422 carries is generic
      # ("Request validation failed."); the body's details say which field and why, and that
      # is the difference between a quiet run and a five-minute fix.
      def refusal_detail(error)
        payload = error.respond_to?(:payload) ? error.payload : nil
        return "" unless payload.is_a?(Hash)

        details = Array(payload.dig("error", "details")).first(3).filter_map do |detail|
          next unless detail.is_a?(Hash)

          [detail["field"], detail["message"]].compact.join(": ")
        end
        advice = payload["next_step"].to_s.strip
        details << advice unless advice.empty?
        details.empty? ? "" : " — #{details.join("; ")}"
      end

      # Public for the reason the policy group above is — `test/step_test.rb` holds this
      # shape still — and `private` is restored below because `run_id`, the last method in
      # this class, is an instance helper.
      public

      # The body `POST /api/upgrades/runs` takes, built from the record alone. A class method
      # and pure, because it is the whole of what this tool tells the service about a
      # run and a test can hold it still without a corpus.
      # The service's own bound on a run's patch is two million characters; a real
      # application's app:update patch is larger (the second lighthouse's was), and the
      # service refuses the *request* rather than clipping it, so the client clips the copy
      # it sends. The local record and the pull request keep the whole patch.
      RUN_PATCH_LIMIT = 2_000_000

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
          "patch" => record.patch.to_s[0, RUN_PATCH_LIMIT],
          # A step is one process run; the record carries when it was written and the
          # commands carry their own durations, so a start time invented here would be
          # a second, disagreeing answer to a question already answered.
          "started_at" => nil,
          "finished_at" => record.recorded_at,
          "commands" => record.stages.map { |stage| command_payload(stage) },
          "refusals" => refusal_payloads(record),
          # What the rung knew before it decided. Absent for a record that never got as far as
          # recall (a refusal), which the service stores as no brief rather than as an empty one.
          "brief" => record.brief&.to_h,
          # **The effect-level evidence, and the decision list stays beside it.** A passed run
          # verifies only the answers whose effects were in the tree the gate measured, so the
          # pair travels: the service stores it in `upgrade_run_effects` and links those answers.
          # An effect with no id (a declaration written before the column) has no entry — the
          # service requires both ids, and a guessed one would link an answer the run may not have
          # used. `decisions` is the same parse's distinct question ids, kept for a client that has
          # not learned this field.
          "applied_effects" => applied_effects(record),
          "decisions" => applied_decisions(record),
          # **The review brief's internal sections.** The public run response is frozen and does not
          # grow; the service stores these for the site admin, where a reviewer reads the gate, the
          # concern commits, the app:update outcome and the toolchain beside the command evidence.
          "checks" => Array(record.checks).map(&:to_h),
          "commits" => Array(record.commits),
          "app_update" => record.app_update,
          "toolchain" => record.toolchain,
          # **The interpreter, not only the image.** The profile declares Ruby; the brief compares
          # that declaration with the one that ran, and an image tag is not the same fact.
          "interpreter" => record.interpreter
        }
      end

      # One entry per effect that was present in the tree, from the applied edits' origins and the
      # fired rules' ids — the two places `Effects` records what it did. `applied` is always true
      # here because only an applied effect reaches these lists; `false` is for a caller that sends
      # an attempt it refused, which this client does not claim as evidence.
      def self.applied_effects(record)
        pairs = Array(record.applied).filter_map do |edit|
          origin = edit.respond_to?(:origin) ? edit.origin.to_s : ""
          decision_id, effect_id = Effects.evidence(origin)
          [decision_id, effect_id] if decision_id && !effect_id.to_s.empty?
        end
        pairs.concat(Array(record.fired_rules).filter_map do |rule|
          decision_id = rule["decision_id"].to_s
          effect_id = rule["effect_id"].to_s
          [decision_id, effect_id] if !decision_id.empty? && !effect_id.empty?
        end)
        pairs.uniq.map do |decision_id, effect_id|
          { "decision_id" => decision_id, "effect_id" => effect_id, "applied" => true }
        end
      end

      # The distinct questions that shaped this rung, read from the same origins as
      # `applied_effects` so the two lists cannot disagree about which answer an effect belongs to.
      # A fired rule carries its id directly, and is included even when it has no effect id — the
      # service still verifies by the question in that case.
      def self.applied_decisions(record)
        ids = Array(record.applied).filter_map do |edit|
          origin = edit.respond_to?(:origin) ? edit.origin.to_s : ""
          Effects.evidence(origin).first
        end
        (ids + Array(record.fired_rules).map { |rule| rule["decision_id"].to_s })
          .reject(&:empty?).uniq
      end

      def self.baseline_verdict(record)
        return nil if record.baseline.nil?

        record.baseline.ok? ? "passed" : "failed"
      end

      def self.command_payload(stage)
        {
          "argv" => stage.command,
          # The application's own command, before the runner wrapped it. The service keeps it
          # beside the wrapper so a member can read what ran without a docker invocation. Some
          # stages (the suite, the baseline) are already the application's own command and carry
          # no separate display; the command is the display there, not a fallback to a wrapper.
          "display" => stage.display.to_s.empty? ? stage.command : stage.display,
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
      # **The service refuses the whole run over one long field.** Its refusals are bounded
      # (`UpgradesBody`: subject 200, note 4,000, source 100, path 500), and a plan decision's
      # source is the located change's own evidence, which can be longer than the chapter name
      # the field is for — measured on the second lighthouse, where one 101-character source
      # discarded every stage of the run. The record keeps the whole sentence; the payload is
      # the summary the service stores, and it is clipped here rather than refused there.
      FIELD_LIMITS = { "subject" => 200, "kind" => 30, "replacement" => 200,
                       "note" => 4_000, "source" => 100, "path" => 500 }.freeze

      def self.refusal_payloads(record)
        record.refused.map do |refusal|
          note = refusal.reason.to_s
          note = "#{note}; found: #{refusal.found}" if refusal.found
          clipped({
            "subject" => (refusal.subject || refusal.text.to_s.split(" ").first || refusal.path).to_s,
            "kind" => refusal.kind,
            "replacement" => refusal.replacement,
            "note" => [refusal.note, note].compact.reject { |text| text.to_s.empty? }.uniq.join(" — "),
            "source" => refusal.source,
            "path" => refusal.path,
            "line" => refusal.line
          })
        end + record.decisions.map do |decision|
          clipped({
            "subject" => decision.subject.to_s,
            "kind" => decision.kind,
            "replacement" => decision.replacement,
            "note" => decision.reason,
            "source" => decision.source,
            "path" => decision.path,
            "line" => decision.line,
            # **The change the decision is about.** The scan hit and its refusal name the same key,
            # which is what lets a report or a promoted rule be joined to the line a person must
            # decide; a decision without one stays on its question's page.
            "change_key" => decision.change_key
          })
        end
      end

      def self.clipped(fields)
        fields.each_with_object({}) do |(key, value), out|
          out[key] = if value.is_a?(String) && FIELD_LIMITS.key?(key)
            value[0, FIELD_LIMITS[key]]
          else
            value
          end
        end
      end

      # Only `run_payload` calls these builders, so they are private class methods rather than
      # public ones — the payload's *shape* is the contract, the builders are not.
      private_class_method :baseline_verdict, :command_payload, :refusal_payloads, :clipped,
        :applied_effects, :applied_decisions

      private

      def run_id
        @run_id ||= "#{Time.now.utc.strftime("%Y%m%d%H%M%S")}-#{Process.pid}"
      end
    end
  end
end
