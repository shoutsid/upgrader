# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "agents/upgrader"

# The pipeline, driven without a network, a bundle or an application.
#
# A step that installs gems and boots Rails is not something a unit test can do, so the
# three decisions inside it are held still instead: the baseline runs before anything is
# written, the pin rewrite either changes one line or refuses, and `app:update` may keep
# only what it added. Those are the parts whose failure reaches somebody's repository or
# somebody's corpus, and they are the ones this file exists for.
class StepTest < Minitest::Test
  Command = Agents::Upgrader::Record::Command
  Lockfile = Agents::Upgrader::Lockfile

  LOCKFILE = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        rails (4.2.11)

    PLATFORMS
      ruby

    DEPENDENCIES
      rails (= 4.2.11)

    BUNDLED WITH
       2.5.22
  LOCK

  # The lockfile a real application arrives with when a dependency is what provides a gem: nothing
  # in `DEPENDENCIES` names it, and the spec is there.
  LOCKFILE_WITH_ATTR_ENCRYPTED = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        attr_encrypted (4.2.0)
          encryptor (~> 3.0.0)
        devise-two-factor (4.1.0)
          attr_encrypted (>= 1.3, < 5, != 2)
        rails (4.2.11)

    PLATFORMS
      ruby

    DEPENDENCIES
      rails (= 4.2.11)

    BUNDLED WITH
       2.5.22
  LOCK

  COMPONENTS_LOCKFILE = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        railties (5.2.8)

    PLATFORMS
      ruby

    DEPENDENCIES
      railties
  LOCK

  # A documented change as the ladder writes one: a name, the kind of change it is,
  # the chapter it came from, and whether a machine can apply it. The default step
  # carries none, which is the case most tests are about — the ones about refusals pass
  # theirs in.
  def change(subject: "before_filter", kind: "renamed", source: "5.0",
             automatic: false, replacement: "before_action", note: "renamed in Rails 5.0")
    { "subject" => subject, "kind" => kind, "source" => source, "automatic" => automatic,
      "replacement" => replacement, "note" => note }
  end

  def plan(to: "5.0.0", from: "4.2.11", changes: [])
    {
      "from_version" => from, "to_version" => "6.0.0",
      "steps" => [{ "from_version" => from, "to_version" => to, "name" => "Rails 5.0",
                    "requires_ruby" => "2.2.2", "changes" => changes, "note" => "" }],
      "next_step" => "one step"
    }
  end

  # Ruby source in the fixture, because a step with none never reaches the scan: the
  # service is asked about files, and an application this tool finds no Ruby in takes the
  # "no source to scan" path instead. Only the tests about what the scan *found* need it.
  def with_source(dir, path, text)
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
    full
  end

  # A git working tree with a Gemfile, a Gemfile.lock and a `bin/rails`, because those
  # are the three things the pipeline looks for before it will run anything.
  # A git working tree with the four things the pipeline looks for: a Gemfile and its lockfile,
  # a `bin/rails`, and a `Rakefile`. The Rakefile is not decoration — the fixture is a Rails
  # **4.2** application, and `rails app:update`/`rails db:create` are 5.0's spellings; on 4.2
  # both go through rake (`rake rails:update`), which is what a 4.2 application actually ships.
  def app(lockfile: LOCKFILE, gemfile: %(source "https://rubygems.org"\ngem "rails", "4.2.11"\n),
          rakefile: true)
    dir = Dir.mktmpdir
    File.write(File.join(dir, "Gemfile.lock"), lockfile)
    File.write(File.join(dir, "Gemfile"), gemfile)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    File.write(File.join(dir, "bin", "rails"), "#!/usr/bin/env ruby\n")
    File.chmod(0o755, File.join(dir, "bin", "rails"))
    File.write(File.join(dir, "Rakefile"), "require File.expand_path(\"../config/application\", __FILE__)\n") if rakefile
    system("git", "init", "--quiet", dir, out: File::NULL, err: File::NULL)
    commit(dir, "fixture")
    dir
  end

  def commit(dir, message)
    system("git", "-C", dir, "add", "--all", out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "-c", "user.email=t@example.com", "-c", "user.name=t",
      "commit", "--quiet", "-m", message, out: File::NULL, err: File::NULL)
  end

  def teardown
    (@dirs || []).concat(@dirs_to_clean || [])
         .each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def track(dir)
    (@dirs ||= []) << dir
    dir
  end

  class FakeSource
    def initialize(root, commit: "9f2c1ab8", home: nil)
      @root = root
      @commit = commit
      @home = home || root
      @asked = []
    end

    attr_reader :root, :commit, :asked

    def description = "fixture"

    # The bundle goes outside the working copy, as the real one does: a gemset inside a
    # tree the loop commits is a gemset that gets committed.
    # **A call site that forgot the machine is the bug `Source#bundle_env` exists to prevent**, so
    # this double refuses one rather than defaulting: the per-era path itself is asserted in
    # `source_test.rb`, where the real class is the subject.
    def bundle_env(machine:)
      raise "no machine: a bundle path shared across eras is the bug this prevents" if machine.nil?

      { "BUNDLE_PATH" => File.join(@home, "bundles", "fixture") }
    end

    def worktree(_reference, ref:, home:, run:, reuse: false)
      @asked << { ref: ref, home: home, run: run, reuse: reuse }
      self
    end
  end

  class FakeCorpus
    attr_reader :gem_requests

    attr_reader :routes

    def initialize(payload: nil, refuse: nil, edits: [], manual: [], migrations: [],
                   route: nil, routes: nil, route_error: nil, earliest: nil, ladder_error: nil)
      @payload = payload
      @refuse = refuse
      @edits = edits
      @manual = manual
      @migrations = migrations
      @route = route
      @routes = routes
      @route_error = route_error
      @earliest = earliest
      @ladder_error = ladder_error
      @gem_requests = []
      @asked_routes = []
      @asked_scans = []
      @asked_files = []
    end

    # The routing answer, as the service writes it: no moves unless the test says otherwise,
    # which is what keeps every existing step test about its own subject. `routes:` is a
    # *sequence*, for the one test about what a second ask looks like after research.
    # The recall reads. Empty on purpose — the brief has its own suite (`brief_test.rb`) — but a
    # double that omitted them would fail on a read the real step makes, which is the shape of a
    # double that lies about the interface.
    attr_reader :upgrade_calls

    def reports_upgrade(library:, **)
      (@upgrade_calls ||= []) << [library]
      { "changes" => [] }
    end

    def search(**) = { "items" => [], "total" => 0 }

    def route(ruby:, rails:, lockfile:)
      raise @route_error if @route_error

      @asked_routes << [ruby, rails]
      routed = @routes ? @routes.shift : @route
      routed || { "ruby" => ruby, "rails" => rails, "gems_read" => 0,
                  "counts" => { "keep" => 0, "move" => 0, "replace" => 0, "remove" => 0,
                                "blocked" => 0, "unknown" => 0 },
                  "gems" => [], "stored" => false, "next_step" => "every pin is recorded" }
    end

    def asked_routes = @asked_routes

    def upgrade(from:, to:)
      raise Agents::Upgrader::Corpus::Refused, @refuse if @refuse

      @payload
    end

    def gem_migrations(gems:)
      @gem_requests << gems
      # The service's own rule, mirrored so the double cannot lie: a `declared` entry is for a gem
      # the caller does not hold — the framework brings it in — so it travels with every answer.
      { "migrations" => @migrations.select { |migration|
        gems.include?(migration["gem"]) || migration["kind"] == "declared"
      },
        "counts" => { "selected" => 0, "total" => @migrations.size }, "stored" => false,
        "next_step" => "the digest's own sentence" }
    end

    def scan(from:, to:, files:)
      @asked_scans << [from, to]
      @asked_files << files.map(&:first)
      { "edits" => @edits, "manual" => @manual,
        "counts" => { "files" => files.size, "automatic" => @edits.size, "manual" => @manual.size },
        "next_step" => "this window's documented changes are all defaults with no call site" }
    end

    # **The ladder's own bottom, because the scan starts there.** A step asks for a wider window than the
    # rung it is crossing so that a rule can fix a change the application never made, and the double has to
    # answer the question the pipeline asks — a double that could not would let the widening be dropped
    # without a red test.
    def ladder
      raise @ladder_error if @ladder_error

      @ladder || { "earliest" => @earliest || "4.2.11", "top" => "8.1.0", "steps" => [] }
    end

    def asked_scans = @asked_scans

    def asked_files = @asked_files
  end

  class FakeTests
    attr_reader :machines

    def initialize(suite: :default, result: nil)
      @suite = suite
      @result = result
      @machines = []
    end

    def detect(_root, declared: nil, stack: nil)
      return nil if @suite.nil?

      Agents::Upgrader::Tests::Suite.new(kind: :rspec, command: "bundle exec rspec")
    end

    def no_suite_reason(_root, _stack = nil) = "no test directory, no spec directory and no Rakefile"

    def run(_root, _suite, timeout:, env:, machine: nil, stack: nil)
      # Recorded rather than ignored: "the suite ran through the machine the step chose" is
      # the wiring the selection tests exist for, and a double that dropped the argument
      # would let the pipeline stop passing it without a red test.
      @machines << machine
      @result || Agents::Upgrader::Tests::Result.new(
        command: "bundle exec rspec", ran: true, passed: true, exit_code: 0,
        seconds: 0.2, output_tail: "3 examples, 0 failures", timed_out: false
      )
    end

    def machine_test_env(_stack = nil) = { "RAILS_ENV" => "test" }
  end

  # The suites a step runs, in order: a green baseline and then whatever the step did to
  # the application. `FakeTests` answers every call with one result, which cannot express
  # "green before, red after" — the case the verdict exists for.
  class SequencedTests < FakeTests
    attr_reader :seen

    def initialize(results:)
      super()
      @results = results
      @seen = []
    end

    def run(root, _suite, timeout:, env:, machine: nil, stack: nil)
      @machines << machine
      @seen << File.read(File.join(root, "Gemfile"))
      @results.shift || @results.last
    end
  end

  # A repair loop, as much of it as a step touches: it is built with the evidence, records
  # one attempt as the caller's `on_attempt` sees it, runs the suite again through `rerun`,
  # and answers whether that suite came back green. The loop's own subject is `repair_test.rb`.
  class FakeRepair
    Attempt = Struct.new(:number, :command, :ran, :exit_code, :seconds, :output_tail, :changed,
      keyword_init: true)
    Result = Struct.new(:attempts, :repaired)

    # The budget is the *step's* to read, and this double reads the same knob the real one
    # does, so "off unless asked for" is asserted through the same path a deployment uses.
    def self.budget(env)
      attempts = env["UPGRADER_REPAIR_ATTEMPTS"].to_s.to_i
      return nil unless attempts.positive?

      { attempts: attempts, timeout: 10, model: "", agent: "repair", binary: "opencode" }
    end

    class << self
      attr_accessor :last_evidence
    end

    def initialize(evidence:, rerun: nil, on_attempt: nil, **kwargs)
      @kwargs = kwargs
      @rerun = rerun
      @on_attempt = on_attempt
      self.class.last_evidence = evidence
    end

    def run
      attempt = Attempt.new(number: 1, command: "opencode run --agent repair (prompt: 900 bytes)",
        ran: true, exit_code: 0, seconds: 1.5, output_tail: "I moved the attribute list.",
        changed: ["app/models/user.rb"])
      @on_attempt&.call(attempt)
      suite = @rerun&.call
      Result.new(attempts: [attempt], repaired: suite&.ok? || false)
    end
  end

  # Records what was written to the corpus, so a test can assert both that the loop's step
  # writes and that a hand-run one does not.
  class RecordingCorpus < FakeCorpus
    attr_reader :calls

    def initialize(payload: nil)
      super(payload: payload)
      @calls = []
    end

    def record_run(payload)
      @calls << [:record_run, payload]
      { "run" => { "id" => "11111111-1111-1111-1111-111111111111" } }
    end

    def precheck(payload)
      @calls << [:precheck, payload]
      { "verdict" => "new" }
    end

    def create_report(payload)
      @calls << [:create_report, payload]
      { "id" => "22222222-2222-2222-2222-222222222222" }
    end

    def calls_of(kind)
      @calls.select { |name, _| name == kind }.map(&:last)
    end
  end

  # **A corpus that is briefly unreachable, which is what a restarting service looks like.** The
  # refusal is the client's own `Unreachable`, and the successful attempt is the ordinary recorder's.
  class FlakyRecordingCorpus < RecordingCorpus
    def initialize(failures:, **kwargs)
      super(**kwargs)
      @failures = failures
    end

    def record_run(payload)
      if @failures.positive?
        @failures -= 1
        raise Agents::Upgrader::Corpus::Unreachable,
          "could not reach http://api.test: Errno::ECONNREFUSED"
      end

      super
    end
  end

  class FakeApplier
    attr_reader :applied

    def initialize(_root) = @applied = []

    def apply(_edits)
      Agents::Upgrader::Applier::Result.new(applied: @applied, refused: [], files_written: 0)
    end
  end

  # Records the Gemfile it was handed, because "the baseline ran before anything was
  # written" is a claim about what the suite *saw* rather than about the order of a list.
  #
  # It also records the env it was handed and the runner's calls *at that moment*, because
  # two of the install stage's promises are only visible from here: `Tests.run` spawns the
  # suite itself, so an injected runner never sees it, and the bundle it runs under is an
  # argument rather than a call.
  class CapturingTests < FakeTests
    attr_reader :seen, :envs, :calls_when_it_ran

    def initialize(runner: nil, **kwargs)
      super(**kwargs)
      @runner = runner
      @seen = []
      @envs = []
      @calls_when_it_ran = []
    end

    def run(root, _suite, timeout:, env:, machine: nil, stack: nil)
      @seen << File.read(File.join(root, "Gemfile"))
      @envs << env
      @calls_when_it_ran << (@runner && @runner.calls.dup)
      super(root, _suite, timeout: timeout, env: env, machine: machine, stack: stack)
    end
  end

  # Records every command it is asked to run *and* the environment it was given, so a test
  # can assert what ran, in what order, and under which bundle — which is the whole of what
  # the install stage promises the stages after it.
  class FakeRunner
    attr_reader :calls, :envs, :timeouts, :stdins

    def initialize(fail_on: nil, ran: true)
      @fail_on = fail_on
      @ran = ran
      @calls = []
      @envs = []
      @timeouts = []
      @stdins = []
    end

    # **The timeout is recorded rather than ignored**, for the same reason the env is: a double that dropped
    # it would let the pipeline stop bounding its commands without a red test, which is exactly the state a
    # real walk was found in. The same goes for what a command is given on stdin: the update task's answer
    # pipe is the difference between finishing and asking for ever, so it is *read* here rather than kept.
    def run(argv, stage:, chdir:, env: {}, stdin: nil, timeout: nil, excerpt_bytes: nil, display: nil)
      @calls << argv.join(" ")
      @envs << [argv.join(" "), env]
      @timeouts << [argv.join(" "), timeout]
      @stdins << [argv.join(" "), stdin.respond_to?(:read) ? stdin.read : stdin]
      failing = @fail_on && argv.join(" ").include?(@fail_on)
      Command.new(stage: stage, command: argv.join(" "), display: (display || argv).join(" "),
        ran: failing ? @ran : true,
        exit_code: failing ? (@ran ? 1 : nil) : 0, seconds: 0.1,
        output_tail: failing ? "boom" : "")
    end
  end

  # **A double whose update task behaves like the real one in the one way a test needs: it writes a
  # file.** `adopt_added_only` reads the worktree's dirty paths, so a runner that only returns a
  # `Command` can never make `@adopted` non-empty — and a test of the re-preparation that skipped
  # this would assert nothing at all.
  class MigratingRunner < FakeRunner
    def initialize(root, path:, content: "# generated by app:update\n")
      super()
      @root = root
      @path = path
      @content = content
    end

    def run(argv, stage:, chdir:, env: {}, stdin: nil, timeout: nil, excerpt_bytes: nil, display: nil)
      if argv.join(" ").match?(/app:update|rails:update/)
        full = File.join(@root, @path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, @content)
      end
      super
    end
  end

  # **A double whose bundle install fails the way a compiler does.** The installer names the gem it could
  # not build — `An error occurred while installing nio4r (2.3.1)` — and that sentence is the only thing
  # that says which line to move, because a *transitive* gem is one nothing this tool edited names.
  class BrokenExtensionRunner < FakeRunner
    def run(argv, stage:, chdir:, env: {}, stdin: nil, timeout: nil, excerpt_bytes: nil, display: nil)
      if argv.join(" ") == "bundle install"
        @calls << argv.join(" ")
        @envs << [argv.join(" "), env]
        @timeouts << [argv.join(" "), timeout]
        @stdins << [argv.join(" "), nil]
        return Command.new(stage: stage, command: argv.join(" "), display: (display || argv).join(" "),
          ran: true, exit_code: 5, seconds: 0.1,
          output_tail: "Installing nio4r 2.3.1 with native extensions\n" \
                       "An error occurred while installing nio4r (2.3.1), and Bundler cannot continue.\n")
      end

      super
    end
  end

  # **A pin that drops a transitive dependency, and a boot that then cannot load it.** Measured at
  # diaspora's 7.1 rung: `devise-two-factor 4.1.0` depends on `attr_encrypted`, `~> 6.3.1` does not,
  # and `app/models/user.rb` encrypts the OTP secret with it — so the correct pin produced a boot
  # that answered `LoadError: cannot load such file -- attr_encrypted` while the application's
  # Gemfile had never declared it. The double writes the lock the real `bundle update` writes — the
  # gem is gone from it — because that absence is what the repair reads.
  class DroppingGemRunner < FakeRunner
    attr_reader :boots

    def initialize(root, require_name: "attr_encrypted")
      super()
      @root = root
      @require_name = require_name
      @boots = 0
    end

    def run(argv, stage:, chdir:, env: {}, stdin: nil, timeout: nil, excerpt_bytes: nil, display: nil)
      command = argv.join(" ")
      File.write(File.join(@root, "Gemfile.lock"), StepTest::LOCKFILE) if command.include?("bundle update")
      return super unless command.include?("Rails.version")

      @calls << command
      @envs << [command, env]
      @timeouts << [command, timeout]
      @stdins << [command, stdin]
      @boots += 1
      failed = @boots == 1
      Command.new(stage: stage, command: command, display: (display || argv).join(" "),
        ran: true, exit_code: failed ? 1 : 0, seconds: 0.1,
        output_tail: failed ? "bin/rails aborted!\nLoadError: cannot load such file -- " \
                              "#{@require_name} (LoadError)\n" : "4.2.11\n")
    end
  end

  # **A reader of the panel is asking about the move happening now, and that is the rung's.**
  # `@to` is where the *walk* is going, so a progress write fed from it says "5.0.0 -> 6.0.0" while
  # the step is moving to 5.0.0. The runner reads the file on the way past, because the step clears it
  # when it finishes and the panel is only interesting *during* a step.
  class ReadingRunner < FakeRunner
    attr_reader :seen

    def initialize(dir)
      super()
      @dir = dir
      @seen = []
    end

    def run(argv, stage:, chdir:, env: {}, stdin: nil, timeout: nil, excerpt_bytes: nil, display: nil)
      path = File.join(@dir, "state", "progress.json")
      @seen << JSON.parse(File.read(path))["to_version"] if File.file?(path)
      super
    end
  end

  # **`--work` is a place for the working copy, not a second home.** The option was parsed and
  # dropped, so a step kept putting its tree under `$UPGRADER_HOME` while the caller believed it
  # had moved. The source is the only component that decides where a tree lives, so its `home`
  # argument is what this drives; the ledger and records stay under the real home.
  def test_work_moves_the_working_copy_without_moving_the_home
    dir = track(app)
    work = track(Dir.mktmpdir)

    step(dir, work: work).run

    assert_equal work, @source.asked.first[:home]
  end

  # **A custom rvm root or gemset has to reach the machine, not only the setup script.** The
  # script installs into the directory the environment names; a step that read only its own
  # defaults looked in `~/.rvm` at `agents-upgrader` and reported an uninstalled era.
  def test_the_rvm_machine_reads_the_configured_root_and_gemset
    dir = track(app)
    rvm_root = File.join(dir, "rvm")
    machine_step = Agents::Upgrader::Step.new(
      repository: "acme/storefront", to: "6.0.0", api: "http://api.test", home: dir,
      runtime: "rvm", source: FakeSource.new(dir),
      env: { "UPGRADER_RVM_ROOT" => rvm_root, "UPGRADER_RVM_GEMSET" => "custom" }
    )
    entry = Agents::Upgrader::Interpreters.named("3.3")

    machine = machine_step.send(:build_machine, entry)

    assert_equal File.join(rvm_root, "wrappers", "ruby-3.3.12@custom"), machine.wrapper
  end

  # **A clone that could not be made is not a verdict about the move.** The queue-driven run recorded
  # a DNS failure as `refused`, which settles a move for good; `unverified` is the machine failing to
  # measure, retried and spending no attempt.
  def test_a_source_that_cannot_be_read_is_unverified_rather_than_refused
    dir = track(Dir.mktmpdir)
    failing = Class.new(FakeSource) do
      def worktree(*, **)
        raise Agents::Upgrader::Source::Failed,
          "clone https://github.com/acme/storefront failed (exit 128): Could not resolve host"
      end
    end.new(dir, home: dir)

    record = step(dir, source: failing).run

    refute_nil record
    assert_equal Agents::Upgrader::Record::UNVERIFIED, record.verdict
    assert_includes record.why, "Could not resolve host"
  end

  def test_the_live_view_names_the_rung_being_walked_rather_than_the_loops_target
    dir = track(app)
    runner = ReadingRunner.new(dir)

    step(dir, corpus: FakeCorpus.new(payload: plan(to: "5.0.0", from: "4.2.11")),
      tests: CapturingTests.new, runner: runner).run

    refute_empty runner.seen, "the step wrote no progress at all"
    assert_equal ["5.0.0"], runner.seen.compact.uniq,
      "the live view named the loop's target rather than the rung: #{runner.seen.compact.uniq.inspect}"
  end

  def step(dir, corpus: nil, tests: nil, runner: nil, ledger: nil, record: nil, contribute: false,
           reuse: false, source: nil, out: nil, research: nil, env: {}, repair: nil,
           suite_env: nil, applier: nil, pause: nil, project: nil, to: "6.0.0", work: nil)
    @source = source || FakeSource.new(dir, home: dir)
    Agents::Upgrader::Step.new(
      repository: "acme/storefront", to: to, api: "http://api.test", home: dir, work: work,
      out: out, record: record, ledger: ledger, source: @source,
      corpus: corpus || FakeCorpus.new(payload: plan), tests: tests || FakeTests.new,
      applier: applier || FakeApplier, runner: runner || FakeRunner.new, contribute: contribute,
      reuse: reuse, research: research, env: env, repair: repair, suite_env: suite_env, pause: pause,
      project: project
    )
  end

  # The baseline is the reason the verdict means anything, so it has to run on the copy
  # as it arrived — before the pin is rewritten and before an edit is applied. The
  # assertion is on the Gemfile the suite was handed rather than on a runner's call
  # list, because `Tests.run` spawns the suite itself: an injected runner never sees it,
  # so the call list could only ever have shown the *absence* of a suite that did run.
  # The preflight is the step's first move, and the order is the reason: the machine choice
  # *is* a `bundle install`, so a Gemfile that cannot be installed as it stands has to be
  # repaired before an interpreter is picked — otherwise every era is rejected for the
  # protocol's reason and the record blames the matrix for a `git://` remote.
  def test_the_preflight_repairs_run_before_the_install_and_land_in_the_record
    dir = track(app(gemfile: <<~GEM))
      source "https://rubygems.org"
      gem "rails", "4.2.11"
      gem "cancan", git: "git://github.com/moriz/cancan.git"
    GEM
    corpus = FakeCorpus.new(payload: plan, migrations: [
      { "gem" => "cancan", "kind" => "replaced", "replacement" => "cancancan",
        "requirement" => "~> 1.9", "mechanical" => true,
        "note" => "the Rails-4 fork is gone", "source" => "the index" }
    ])

    record = step(dir, corpus: corpus).run

    stages = record.stages.map(&:stage)
    assert_operator stages.index("preflight"), :<, stages.index("bundle"),
      "the install ran before the Gemfile was made installable"
    assert_equal %w[cancan git://], record.applied.map(&:subject).sort,
      "both repairs should be in the record"
    assert_includes record.patch, %(gem "cancancan", "~> 1.9")
    # The reason travels with the repair: a Gemfile line that moved without its reason in
    # the record is a change nobody reading the record can account for.
    assert_includes record.to_h["applied"].find { |edit| edit["subject"] == "git://" }["note"],
      "2022"
  end

  # **A declaration scoped to the rung is made between the pin and its resolve, and nowhere
  # earlier.** Measured at the 4.2 rung: the preflight runs before the machine is chosen (the
  # choice is a `bundle install`), so the Gemfile it edits still names `rails 4.1.0`, and
  # declaring `responders ~> 2.0` there answers `railties (< 5, >= 4.2.0.alpha)` against
  # `railties (= 4.1.0)` for every era — the step then reports "no interpreter installed the
  # application's bundle". The declaration belongs where the Gemfile and the pin agree, which is
  # `rewrite`: after the line is rewritten and before the resolve. The condition is also read
  # against the *rung*, not the requested target — a walk to 6.0.0 executes the 5.0 rung here,
  # and `rails_below 6.0` is true of the rung and false of the target, which is what tells the
  # two apart.
  def test_a_declaration_scoped_to_the_rung_is_made_between_the_pin_and_its_resolve
    dir = track(app(gemfile: <<~GEM))
      source "https://rubygems.org"
      gem "rails", "4.2.11"
    GEM
    corpus = FakeCorpus.new(payload: plan(to: "5.0.0", from: "4.2.11"), migrations: [
      { "gem" => "responders", "kind" => "declared", "requirement" => "~> 2.0",
        "mechanical" => true, "when" => { "rails_below" => "6.0" },
        "note" => "the resolver picks a release that cannot sit beside the move",
        "source" => "the 4.2 rung's own resolve output" }
    ])
    tests = CapturingTests.new

    record = step(dir, corpus: corpus, tests: tests).run

    stages = record.stages.map(&:stage)
    assert_includes stages, "declarations", "the declaration is not in the record"
    assert_operator stages.index("declarations"), :<, stages.index("pin"),
      "the declaration was made after the resolve it exists to make possible"
    refute_includes tests.seen.first, "responders",
      "the baseline installed a declaration the release it starts from cannot carry"
    assert_includes File.read(File.join(dir, "Gemfile")), %(gem "responders", "~> 2.0")
    assert_includes record.patch, %(gem "responders", "~> 2.0")
    declaration = record.stages.find { |stage| stage.stage == "declarations" }
    assert_includes declaration.output_tail, "declared (responders)"
    assert_equal %w[responders], record.applied.map(&:subject).grep("responders")
  end

  # **A rewrite scoped to the rung is made there too, for the same reason a declaration is — and the
  # resolve has to be told about it.** Measured at the 6.0 rung: the application's own
  # `loofah ~> 2.0.3` was moved *before* the baseline, the bundle stage's conservative update then
  # took loofah 2.21.1 while nokogiri stayed at the 1.9.1 only the 5.2 stack needs, and the 5.2
  # baseline — the run that has to be green before the move is judged — died on
  # `uninitialized constant Nokogiri::HTML4`. Two things have to hold afterwards: the baseline was
  # handed the line the application wrote, and the pin's first round names the gem, because
  # `pin_named` reads the applied edits and a widening spends a round per conflict.
  def test_a_rewrite_scoped_to_the_rung_is_made_between_the_pin_and_its_resolve
    lockfile = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          loofah (2.0.3)
          nokogiri (1.9.1)
          rails (4.2.11)

      PLATFORMS
        ruby

      DEPENDENCIES
        loofah (~> 2.0.3)
        rails (= 4.2.11)

      BUNDLED WITH
         2.5.22
    LOCK
    dir = track(app(lockfile: lockfile, gemfile: <<~GEM))
      source "https://rubygems.org"
      gem "rails", "4.2.11"
      gem "loofah", "~> 2.0.3"
    GEM
    corpus = FakeCorpus.new(payload: plan(to: "5.0.0", from: "4.2.11"), migrations: [
      { "gem" => "loofah", "kind" => "replaced", "replacement" => "loofah",
        "requirement" => "~> 2.22", "mechanical" => true,
        "when" => { "rails_at_least" => "5.0" },
        "note" => "the line the release being moved to asks for",
        "source" => "the rung's own resolve output" }
    ])
    tests = CapturingTests.new

    record = step(dir, corpus: corpus, tests: tests).run

    stages = record.stages.map(&:stage)
    assert_operator stages.index("declarations"), :<, stages.index("pin"),
      "the rewrite was made after the resolve it exists to make possible"
    refute_includes tests.seen.first, "2.22",
      "the baseline installed a line only the release being moved to makes sense of"
    assert_includes File.read(File.join(dir, "Gemfile")), %(gem "loofah", "~> 2.22")
    assert_includes record.patch, %(gem "loofah", "~> 2.22")
    pin = record.stages.find { |stage| stage.stage == "pin" }
    assert_includes pin.command, "loofah",
      "the resolve was not told about the line this step moved: #{pin.command}"
  end

  # **A digest entry that renames the gem, and not only its requirement, leaves the pin naming neither
  # name.** Measured at the 7.2 rung: the routing rewrote `gem 'factory_girl_rails', '~> 4.0'` into the
  # replacement's line and the companion renamed 93 call sites, and the pin then exited 7 with
  # `Could not find gem 'factory_girl_rails'` — because the line the entry rewrote was the only thing
  # that made the old name a dependency. Naming the *new* name fails the same way, and that was measured
  # too: bundler resolves a `bundle update` name only when the Gemfile's own dependencies still reach it,
  # and the new gem is not in the lock yet. So the rename is left out of the pin entirely — the
  # replacement arrives the way any new dependency does.
  def test_a_digest_entry_that_renames_a_gem_leaves_the_pin_naming_neither_name
    lockfile = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          factory_girl (4.9.0)
          factory_girl_rails (4.9.0)
          rails (7.1.0)

      PLATFORMS
        ruby

      DEPENDENCIES
        factory_girl_rails (~> 4.0)
        rails (= 7.1.0)

      BUNDLED WITH
         2.5.22
    LOCK
    dir = track(app(lockfile: lockfile, gemfile: <<~GEM))
      source "https://rubygems.org"
      gem "rails", "7.1.0"
      gem "factory_girl_rails", "~> 4.0"
    GEM
    corpus = FakeCorpus.new(payload: plan(to: "7.2.0", from: "7.1.0"), migrations: [
      { "gem" => "factory_girl_rails", "kind" => "replaced", "replacement" => "factory_bot_rails",
        "requirement" => "~> 4.9", "mechanical" => true,
        "when" => { "rails_at_least" => "7.2" },
        "note" => "the gem was renamed at 4.9.0; the same release under a new name",
        "source" => "the rung's own app:update output" }
    ])

    record = step(dir, corpus: corpus, tests: CapturingTests.new).run

    assert_includes File.read(File.join(dir, "Gemfile")), %(gem "factory_bot_rails", "~> 4.9")
    pin = record.stages.find { |stage| stage.stage == "pin" }
    refute_includes pin.command, "factory_girl_rails",
      "the pin named a gem the Gemfile no longer declares: #{pin.command}"
    refute_includes pin.command, "factory_bot_rails",
      "the pin named a gem the lock does not hold, which bundler refuses: #{pin.command}"
  end

  # **And for the two cases a rung-scoped entry never covers: an entry with no clause, and an entry
  # that removes the line.** Measured on the lighthouse's 4.0 -> 4.1 rung: the digest's `cancan` ->
  # `cancancan` carries no `when`, so the preflight applies it there and then rather than holding it
  # for the pin, and `therubyracer` is a *removal* — and the pin named both, because the lock the step
  # started from still holds them. `bundle update rails … cancan … --conservative` exited 7 with
  # `Could not find gem 'cancan'`, and a rung this tool cannot cross is a rung nobody can walk.
  #
  # The rule is read off the Gemfile rather than from the entries, because a `removed` entry and a
  # `replaced` one are one fact here: the name is no longer declared, so the resolver cannot be asked
  # to move it.
  def test_the_pin_names_no_gem_the_gemfile_no_longer_declares
    lockfile = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          cancan (1.6.9)
          rails (4.2.11)
          therubyracer (0.12.3)

      PLATFORMS
        ruby

      DEPENDENCIES
        cancan!
        rails (= 4.2.11)
        therubyracer

      BUNDLED WITH
         2.5.22
    LOCK
    dir = track(app(lockfile: lockfile, gemfile: <<~GEM))
      source "https://rubygems.org"
      gem "rails", "4.2.11"
      gem "cancan", github: "moriz/cancan"
      gem "therubyracer"
    GEM
    corpus = FakeCorpus.new(payload: plan(to: "5.0.0", from: "4.2.11"), migrations: [
      { "gem" => "cancan", "kind" => "replaced", "replacement" => "cancancan",
        "requirement" => "~> 1.9", "mechanical" => true,
        "note" => "cancan's last release was 2013-05-07 and the fork it pinned is gone",
        "source" => "rubygems.org's release history for cancan and cancancan" },
      { "gem" => "therubyracer", "kind" => "removed", "replacement" => nil,
        "requirement" => nil, "mechanical" => true,
        "note" => "a bespoke V8 build that does not compile with a modern toolchain",
        "source" => "the rung's own app:update output" }
    ])

    record = step(dir, corpus: corpus, tests: CapturingTests.new).run

    gemfile = File.read(File.join(dir, "Gemfile"))
    assert_includes gemfile, %(gem "cancancan", "~> 1.9")
    refute_includes gemfile, "therubyracer", "a removal left the line behind"
    pin = record.stages.find { |stage| stage.stage == "pin" }
    refute_match(/\bcancan\b/, pin.command,
      "the pin named a gem the Gemfile no longer declares: #{pin.command}")
    refute_match(/\btherubyracer\b/, pin.command,
      "the pin named a gem this step removed: #{pin.command}")
  end

  # **A digest move that changes a *requirement* has to re-resolve the lock, and the retry is
  # the pin's own mechanism.** `bundle install` is right for everything a preflight move does
  # to a *source* — it adds what the Gemfile gained and leaves the rest where the move found it
  # — but a move into a different line of the same gem's own releases leaves the snapshot's
  # pins as the thing bundler refuses. Measured on the lighthouse, `rspec-rails ~> 2.14.0`
  # against a snapshot holding `rspec-core (= 2.13.1)`: `bundle install` *and*
  # `bundle update rspec-rails --conservative` both answer "could not find compatible versions
  # for gem rspec-mocks", because `--conservative` keeps the *meta*-gem where the lock has it
  # and the meta-gem drags its siblings back. Naming the whole line resolves it, which is what
  # the widened retry is for.
  def test_a_move_that_changes_a_requirement_retries_the_bundle_conservatively
    lockfile = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          rails (4.2.11)
          rspec-core (2.13.1)
          rspec-rails (2.13.2)

      PLATFORMS
        ruby

      DEPENDENCIES
        rails (= 4.2.11)
        rspec-rails (~> 2.0)

      BUNDLED WITH
         2.5.22
    LOCK
    dir = track(app(lockfile: lockfile, gemfile: <<~GEM))
      source "https://rubygems.org"
      gem "rails", "4.2.11"
      gem "rspec-rails", "~> 2.0"
    GEM
    corpus = FakeCorpus.new(payload: plan, migrations: [
      { "gem" => "rspec-rails", "kind" => "updated", "replacement" => "rspec-rails",
        "requirement" => "~> 2.14.0", "mechanical" => true,
        "note" => "the adapter gained a minitest branch", "source" => "the gem" }
    ])
    runner = FakeRunner.new(fail_on: "bundle install")

    record = step(dir, corpus: corpus, runner: runner).run

    assert_includes runner.calls, "bundle update rspec-rails --conservative",
      "the install failed and nothing re-resolved the lock: #{runner.calls.inspect}"
    assert_includes record.patch, %(gem "rspec-rails", "~> 2.14.0")
  end

  # A research pass, as a test double: it records the pins it was handed and answers with a
  # result the step's stage can render. The fetching itself is `research_test.rb`'s subject.
  class FakeResearch
    attr_reader :pins

    def initialize = @pins = []

    def run(pins)
      @pins = pins
      Agents::Upgrader::Research::Result.new(researched: pins.map(&:first), skipped: [], reason: "")
    end
  end

  # **The routing's `move` verdicts are what a `bundle update rails` cannot work out for
  # itself.** `rspec-rails 2.13` declares `railties ~> 3.1`, so a 5.0 rung cannot install it;
  # the line has to move before the pin is rewritten, and the record has to say which line
  # moved and why.
  def test_a_gem_the_routing_says_must_move_has_its_declaration_rewritten
    dir = track(app(gemfile: <<~GEM))
      source "https://rubygems.org"
      gem "rails", "4.2.11"
      gem "rspec-rails", "~> 2.13.0"
    GEM
    corpus = FakeCorpus.new(payload: plan, route: {
      "ruby" => "2.1.10", "rails" => "5.0.0", "gems_read" => 2,
      "counts" => { "keep" => 1, "move" => 1, "replace" => 0, "remove" => 0, "blocked" => 0,
                    "unknown" => 0 },
      "gems" => [{ "name" => "rspec-rails", "version" => "2.13.0", "verdict" => "move",
                   "to" => "3.0.0",
                   "reason" => "requires railties ~> 3.1, and rspec-rails 3.0.0 is the newest " \
                               "recorded release that fits" }],
      "stored" => false, "next_step" => "1 pin(s) have a recorded release that fits."
    })

    record = step(dir, corpus: corpus).run

    stages = record.stages.map(&:stage)
    assert_includes stages, "gems"
    assert_operator stages.index("gems"), :<, stages.index("pin"),
      "the moves must be applied before the Rails pin is rewritten"
    assert_includes File.read(File.join(dir, "Gemfile")), %(gem "rspec-rails", "~> 3.0.0")
    move = record.applied.find { |edit| edit.subject == "rspec-rails" }
    assert_equal %(gem "rspec-rails", "~> 3.0.0"), move.after
    assert_includes move.note, "newest recorded release that fits"
    assert_includes record.patch, %(gem "rspec-rails", "~> 3.0.0")
  end

  # **One statement per gem.** The preflight records a non-mechanical digest entry as a
  # decision ("this moves at the rung that takes Rails past 4.0.0"); when the rung makes that
  # move, the decision is withdrawn — otherwise the reviewer's list says a gem still needs a
  # person while the diff beside it shows the line already moved.
  def test_a_gem_the_rung_moved_is_no_longer_listed_as_needing_a_decision
    dir = track(app(gemfile: <<~GEM))
      source "https://rubygems.org"
      gem "rails", "4.2.11"
      gem "simple_form", github: "plataformatec/simple_form"
    GEM
    corpus = FakeCorpus.new(payload: plan, route: {
      "ruby" => "2.1.10", "rails" => "5.0.0", "gems_read" => 1,
      "counts" => { "keep" => 0, "move" => 0, "replace" => 1, "remove" => 0, "blocked" => 0,
                    "unknown" => 0 },
      "gems" => [{ "name" => "simple_form", "version" => "3.0.0.rc", "verdict" => "replace",
                   "replacement" => "simple_form", "requirement" => "~> 3.1", "mechanical" => false,
                   "note" => "the released line only fits once Rails has moved" }],
      "stored" => false, "next_step" => "1 pin(s) are the digest's own moves"
    })
    record = step(dir, corpus: corpus).run

    assert_includes File.read(File.join(dir, "Gemfile")), %(gem "simple_form", "~> 3.1")
    assert(record.applied.any? { |edit| edit.subject == "simple_form" },
      "the move is not in the record")
    refute(record.decisions.any? { |decision| decision.subject == "simple_form" },
      "a gem the rung moved is still listed as needing a decision")
  end

  # **A framework gem the pin itself moves is not a decision.** The routing reads recorded facts and
  # has none for the framework's own components at the target release, so it answers `blocked` — "no
  # recorded release of rails fits the target" — while the pin resolves exactly that, by naming those
  # gems in its own `bundle update`. Measured on the first real rung: six such verdicts among sixteen
  # decisions, every one of them handled. A decision that says the opposite of what happened is worse
  # than no decision; a gem outside the framework's own set still travels as one.
  def test_a_framework_gem_the_pin_moves_is_not_a_decision_and_another_gem_still_is
    dir = track(app)
    corpus = FakeCorpus.new(payload: plan, route: {
      "ruby" => "2.1.10", "rails" => "5.0.0", "gems_read" => 2,
      "counts" => { "keep" => 0, "move" => 0, "replace" => 0, "remove" => 0, "blocked" => 2,
                    "unknown" => 0 },
      "gems" => [
        { "name" => "rails", "version" => "4.2.11", "verdict" => "blocked",
          "reason" => "requires actionpack = 4.2.11, and no recorded release of rails fits the target" },
        { "name" => "who-knows", "version" => "1.0.0", "verdict" => "blocked",
          "reason" => "requires railties ~> 3.1, and no recorded release of who-knows fits the target" }
      ],
      "stored" => false, "next_step" => "1 pin(s) cannot sit beside the target as they stand"
    })

    record = step(dir, corpus: corpus).run

    subjects = record.decisions.map(&:subject)
    assert_includes subjects, "who-knows 1.0.0", "a gem the pin does not move is still a decision"
    refute_includes subjects, "rails 4.2.11",
      "the pin moves the framework's own gems, so their verdict is not a decision"
  end

  # A pin the routing could not answer about is researched — this client is the side that can
  # reach an index — and the routing is asked again. What the second answer still cannot
  # place is a decision naming the gem, never a silent pass.
  def test_unknown_pins_are_researched_and_the_route_is_asked_again
    dir = track(app)
    unknown = { "name" => "who-knows", "version" => "1.0.0", "verdict" => "unknown",
                "reason" => "no facts are recorded for who-knows 1.0.0 — an unknown gem is not a pass" }
    corpus = FakeCorpus.new(payload: plan, routes: [
      { "ruby" => "3.0.0", "rails" => "5.0.0", "gems_read" => 1,
        "counts" => { "keep" => 0, "move" => 0, "replace" => 0, "remove" => 0, "blocked" => 0,
                      "unknown" => 1 },
        "gems" => [unknown], "stored" => false, "next_step" => "1 pin(s) are unknown" },
      { "ruby" => "3.0.0", "rails" => "5.0.0", "gems_read" => 1,
        "counts" => { "keep" => 1, "move" => 0, "replace" => 0, "remove" => 0, "blocked" => 0,
                      "unknown" => 0 },
        "gems" => [{ "name" => "who-knows", "version" => "1.0.0", "verdict" => "keep",
                     "reason" => "every recorded requirement is satisfied" }],
        "stored" => false, "next_step" => "every pin is recorded" }
    ])
    research = FakeResearch.new

    record = step(dir, corpus: corpus, research: research).run

    assert_equal [["who-knows", "1.0.0"]], research.pins
    assert_equal 2, corpus.asked_routes.length, "the routing was not asked again after research"
    assert_includes record.stages.map(&:stage), "research"
    refute(record.decisions.any? { |decision| decision.subject.include?("who-knows") },
      "a closed unknown should not also be a decision")
  end

  # **One pass is a slice of the lockfile, so the step takes another.** `Research::MAX_GEMS` bounds
  # a pass and the pins beyond it stay unknown — measured at the 5.0 rung, where the first pass
  # recorded 60 of 104 and the gem the pin then failed on (`sass-rails`) was in the other 44, so the
  # route answered `unknown` for the very line the resolve needed moved. The loop closes the rest,
  # and stops when a pass records nothing new.
  def test_research_takes_another_pass_while_the_routing_still_has_unknowns
    dir = track(app)
    unknown = ->(name) do
      { "name" => name, "version" => "1.0.0", "verdict" => "unknown",
        "reason" => "no facts are recorded for #{name} 1.0.0 — an unknown gem is not a pass" }
    end
    route = ->(gems, counts, next_step) do
      { "ruby" => "2.1.10", "rails" => "5.0.0", "gems_read" => 2, "gems" => gems,
        "counts" => counts, "stored" => false, "next_step" => next_step }
    end
    counts = ->(keep, unknown) do
      { "keep" => keep, "move" => 0, "replace" => 0, "remove" => 0, "blocked" => 0, "unknown" => unknown }
    end
    corpus = FakeCorpus.new(payload: plan, routes: [
      route.call([unknown.call("a-gem"), unknown.call("z-gem")], counts.call(0, 2),
        "2 pin(s) are unknown"),
      route.call([unknown.call("z-gem")], counts.call(1, 1), "1 pin is unknown"),
      route.call([], counts.call(2, 0), "every pin is recorded")
    ])
    research = FakeResearch.new

    record = step(dir, corpus: corpus, research: research).run

    assert_equal [["z-gem", "1.0.0"]], research.pins,
      "the second pass has to be handed the unknowns the first left, not the whole lockfile again"
    assert_equal 3, corpus.asked_routes.length, "the routing was not asked again after each pass"
    assert_equal 2, record.stages.count { |stage| stage.stage == "research" },
      "both passes have to be in the record"
  end

  # **The agentic half, from the pipeline's side.** A green baseline and a red suite is the
  # one shape a repair may be attempted on — the failure is then attributable to the move —
  # and the verdict afterwards is the *suite's* again: a repaired step passes because the
  # suite says so, never because a model said it fixed something.
  # **A target that names the release the tree is on has no rung to walk.** The step used to ask the
  # ladder, be refused, and hand that refusal back as a run — which the loop recorded, every cycle,
  # for a target that was finished. `nil` means nothing ran, which the loop reports as idle.
  def test_a_target_that_is_the_tree_s_release_has_no_rung_and_records_nothing
    dir = track(app)
    corpus = RecordingCorpus.new(payload: plan)

    record = step(dir, corpus: corpus, to: "4.2.11", contribute: true).run

    assert_nil record, "a no-op target produced a record"
    assert_empty corpus.calls, "a no-op target was recorded: #{corpus.calls.map(&:first).inspect}"
  end

  # **A decision the project already made is applied before the scan reads the tree.** It is machinery:
  # the same edit on every walk, in the `decisions` stage, named by the decision that made it — which is
  # what the hand-made `agents/baseline` branch did, and the reason it could not be re-derived.
  def test_a_declared_decision_is_applied_before_the_scan_and_recorded_with_its_origin
    dir = track(app)
    FileUtils.mkdir_p(File.join(dir, "app/views/layouts"))
    File.write(File.join(dir, "app/views/layouts/application.html.erb"),
      "<html>\n  <%= link_to 'Categories', categories_path %>\n  <%= yield %>\n</html>\n")
    commit(dir, "the layout the decision is about")

    project = Agents::Upgrader::Project.parse({
      "slug" => "fixture", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0",
      "decisions" => [{
        "id" => "layout-category-link",
        "question" => "The layout renders a Categories link where @category is nil.",
        "answer" => "guard it",
        "accepted_by" => "operator:9f2c1ab8",
        "effects" => [{ "kind" => "patch",
          "payload" => { "path" => "app/views/layouts/application.html.erb",
                         "find" => "  <%= link_to 'Categories', categories_path %>\n",
                         "replace" => "  <% if @category %><%= link_to 'Categories', categories_path %><% end %>\n" },
          "applies_when" => { "rung_gte" => "6.0.0" } }]
      }]
    }.to_json)

    record = step(dir, corpus: FakeCorpus.new(payload: plan(to: "6.0.0")), project: project).run

    stages = record.stages.map(&:stage)
    assert_includes stages, "decisions"
    assert_operator stages.index("decisions"), :<, stages.index("baseline"),
      "the baseline measured the tree before the decision was applied to it"
    assert_operator stages.index("decisions"), :<, stages.index("apply"),
      "the scan read the tree before the decision was applied to it"
    edit = record.applied.find { |applied| applied.origin == "decision:layout-category-link" }
    refute_nil edit, "the decision's edit is not in the applied list"
    assert_equal "app/views/layouts/application.html.erb", edit.path
    assert_includes File.read(File.join(record.worktree, "app/views/layouts/application.html.erb")),
      "<% if @category %>"
    # The run body names the decisions it had in force, read off the edits' origins: the service links
    # a *passed* run to them, which is what verifies an answer.
    assert_equal ["layout-category-link"], Agents::Upgrader::Step.run_payload(record)["decisions"]
  end

  # **A skip rule removes the change from the walk, and the decision id still reaches the run.** The
  # scan is a window read with no change-key filter, so the skip is applied to what it returned: the
  # plan change leaves the rule/survey lists, its located call site is dropped, and no decision asks
  # a person to make it.
  def test_a_skip_rule_keeps_the_change_out_of_the_scan_and_the_residue
    dir = track(app)
    with_source(dir, "app/controllers/items_controller.rb", "before_filter :authenticate\n")
    skipped = change(subject: "before_filter", kind: "renamed")
      .merge("component" => "actionpack",
        "change_key" => "ruby|actionpack|before_filter")
    manual = [{ "path" => "app/controllers/items_controller.rb", "line" => 1,
                "subject" => "before_filter", "kind" => "renamed", "source" => "5.0",
                "note" => "found here" }]
    project = Agents::Upgrader::Project.parse({
      "slug" => "fixture", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0",
      "decisions" => [{
        "id" => "skip-before-filter",
        "question" => "Does this application need the old filter spelling?",
        "answer" => "no, it is generated code",
        "accepted_by" => "operator:9f2c1ab8",
        "effects" => [{ "kind" => "rule",
          "payload" => { "change_key" => "ruby|actionpack|before_filter", "kind" => "skip",
                         "payload" => {} } }]
      }]
    }.to_json)

    record = step(dir, corpus: FakeCorpus.new(payload: plan(changes: [skipped]), manual: manual),
      project: project).run

    assert_empty record.decisions, "a skipped change came back as work for a person"
    refute(record.applied.any? { |edit| edit.subject.to_s == "before_filter" },
      "a skipped change was applied")
    assert_equal ["skip-before-filter"], record.fired_rules.map { |rule| rule["decision_id"] }
    assert_includes Agents::Upgrader::Step.run_payload(record)["decisions"], "skip-before-filter"
    decisions_stage = record.stages.find { |stage| stage.stage == "decisions" }
    assert_includes decisions_stage.output_tail, "rule skip ruby|actionpack|before_filter"
  end

  # **A known failure is not filed as new evidence.** The expect rule matches this run's own suite
  # output, the run body names the decision so the service can retire it if the run falsified it,
  # and the failure report is skipped. The run record is still written: it is the verification.
  def test_an_expect_rule_suppresses_the_report_for_the_failure_it_names
    dir = track(app)
    project = Agents::Upgrader::Project.parse({
      "slug" => "fixture", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0",
      "decisions" => [{
        "id" => "expect-suite-red",
        "question" => "Is this suite failure the known one?",
        "answer" => "yes, it is the fixture's missing database",
        "accepted_by" => "operator:9f2c1ab8",
        "effects" => [{ "kind" => "rule",
          "payload" => { "change_key" => "ruby|actionpack|before_filter", "kind" => "expect",
                         "payload" => { "failure" => "1 examples, 1 failure" } } }]
      }]
    }.to_json)
    corpus = RecordingCorpus.new(payload: plan(changes: []))

    record = step(dir, corpus: corpus, project: project,
      tests: SequencedTests.new(results: [green, red]), contribute: true).run

    assert_equal "failed", record.verdict
    assert_equal ["expect-suite-red"], record.fired_rules.map { |rule| rule["decision_id"] }
    assert_includes Agents::Upgrader::Step.run_payload(record)["decisions"], "expect-suite-red"
    assert_empty corpus.calls_of(:precheck), "the expected failure was compared as if it were new"
    assert_empty corpus.calls_of(:create_report)
    refute_empty corpus.calls_of(:record_run), "the run itself was not recorded"
  end

  def test_a_red_suite_after_a_green_baseline_is_repaired_and_the_suite_decides
    dir = track(app)
    record = step(dir, tests: SequencedTests.new(results: [green, red, green]),
      repair: FakeRepair, env: { "UPGRADER_REPAIR_ATTEMPTS" => "1" }).run

    assert_equal "passed", record.verdict
    assert_includes record.why, "1 repair attempt(s)"
    repair_stage = record.stages.find { |stage| stage.stage == "repair" }
    refute_nil repair_stage, "the attempt is not in the record"
    assert_includes repair_stage.output_tail, "app/models/user.rb"
    assert_operator record.stages.count { |stage| stage.stage == "suite" }, :>=, 2,
      "the suite must be run again after the attempt"
  end

  # **What a repair did is captured while it is knowable, and filed as knowledge.** The record is
  # written from the final state, where the suite is green: the failure the repair answered, and the
  # files it changed to do so, exist only while the loop runs. Both travel in the record, and the
  # corpus receives the repair as a report whose problem is that failure and whose resolution is the
  # repair — the write-back rule the design notes state.
  def test_a_repair_is_recorded_with_what_it_answered_and_filed_as_a_report
    dir = track(app)
    corpus = RecordingCorpus.new(payload: plan(changes: []))
    record = step(dir, corpus: corpus, tests: SequencedTests.new(results: [green, red, green]),
      repair: FakeRepair, contribute: true,
      env: { "UPGRADER_REPAIR_ATTEMPTS" => "1" }).run

    assert_equal 1, record.repairs.length
    repair = record.repairs.first
    assert_includes repair.failure, "1 failure", "the failure the repair answered is not in the record"
    assert_equal ["app/models/user.rb"], repair.files
    assert_equal 1, repair.attempts

    filed = corpus.calls.select { |call| call.first == :create_report }.map(&:last)
    report = filed.find { |payload| payload["resolution"].to_s.include?("app/models/user.rb") }
    refute_nil report, "the repair was not filed; the run filed #{filed.map { |p| p["title"] }.inspect}"
    assert_includes report["problem"], "was red before the repair"
    assert_equal "ruby", report["ecosystem"]
  end

  # The switch. Off is the default for a step run by hand, and the deployment turns it on
  # with a number — so the same fixture, without the number, is a failed step with no model.
  def test_repair_is_off_unless_the_environment_asks_for_attempts
    dir = track(app)
    record = step(dir, tests: SequencedTests.new(results: [green, red]), repair: FakeRepair,
      env: {}).run

    assert_equal "failed", record.verdict
    refute_includes record.stages.map(&:stage), "repair"
    refute_includes record.why, "repair"
  end

  # And the preconditions: a baseline that was already red is not a failure the move caused,
  # so there is nothing here to repair — the step is `unverified`, with no model call at all.
  # **The baseline is repaired first, and this is the case old applications arrive in.** A
  # suite that was red before the step makes everything after it unmeasurable — the lighthouse's
  # was 133 examples red on `You must set config.secret_key_base in your app's config`, a
  # 4.0.0.rc1-era generator writing `secret_token` while the framework already wanted
  # `secret_key_base` — and the fix is a precondition of measuring anything rather than part of
  # the move. The re-run baseline is what makes it green, and the verdict says so: "the suite
  # was green before this step" is false without that clause, and a record that said it would be
  # describing an application that was measured before it was fixed.
  def test_a_red_baseline_is_repaired_before_the_move_and_the_verdict_says_so
    dir = track(app)
    record = step(dir, tests: SequencedTests.new(results: [red, green, green, green]),
      repair: FakeRepair, env: { "UPGRADER_REPAIR_ATTEMPTS" => "2" }).run

    stages = record.stages.map(&:stage)
    assert_equal "passed", record.verdict
    assert_operator stages.index("repair"), :<, stages.index("suite"),
      "the baseline's repair must come before the move"
    assert_includes record.why, "the baseline was red when the step arrived"
    assert_includes record.why, "before anything was moved"
  end

  # And with no budget there is no model call at all: the step is `unverified`, which is the
  # honest verdict for an application whose suite was already red.
  def test_a_red_baseline_with_no_repair_budget_is_unverified_and_spends_nothing
    dir = track(app)
    record = step(dir, tests: SequencedTests.new(results: [red, red]), repair: FakeRepair,
      env: {}).run

    assert_equal "unverified", record.verdict
    refute_includes record.stages.map(&:stage), "repair"
    refute_includes record.why, "repair"
  end

  # The brief is the step's own record, which is what makes the attempt a repair of *this*
  # failure rather than a guess: the evidence handed over names the move, the suite command
  # and the output it failed with.
  def test_the_repair_evidence_is_the_step_s_own_record
    dir = track(app)
    step(dir, tests: SequencedTests.new(results: [green, red, green]), repair: FakeRepair,
      env: { "UPGRADER_REPAIR_ATTEMPTS" => "1" }).run

    evidence = FakeRepair.last_evidence
    assert_equal "4.2.11", evidence[:from_version]
    assert_equal "5.0.0", evidence[:to_version]
    assert_equal "bundle exec rspec", evidence[:suite_command]
    assert_includes evidence[:output_tail], "1 examples, 1 failure"
    refute_nil evidence[:brief], "the repair stage did not receive the joined brief"
    assert_equal "framework", evidence[:brief].sections.first.key
  end

  # **One default at a time, judged by the application's own suite.** `app:update` writes the file
  # commented out on purpose; this pass enables one toggle, runs the suite, keeps it if it is green
  # and puts it back if it is not — so the failure is about the *toggle* rather than about the move,
  # which is what makes "revert this one" the right answer rather than a guess. A default this
  # application cannot take stays in the file, under Rails' own comment, as a decision.
  def test_a_new_default_that_breaks_the_suite_is_put_back_and_the_rest_are_kept
    dir = track(app)
    with_source(dir, "config/initializers/new_framework_defaults_5_0.rb", <<~RUBY)
      # Enable per-form CSRF tokens. Previous versions had false.
      # Rails.application.config.action_controller.per_form_csrf_tokens = true

      # Raise an error when a translation is missing. Previous versions had false.
      # Rails.application.config.i18n.raise_on_missing_translations = true
    RUBY
    with_source(dir, "config/application.rb",
      "module Storefront\n  class Application < Rails::Application\n  end\nend\n")
    tests = SequencedTests.new(results: [green, green, red, green])

    record = step(dir, tests: tests, env: { "UPGRADER_DEFAULT_STEPS" => "5" }).run

    assert record.passed?, record.why
    file = File.read(File.join(dir, "config/initializers/new_framework_defaults_5_0.rb"))
    assert_includes file, "# Rails.application.config.action_controller.per_form_csrf_tokens = true",
      "the toggle the suite refused must be commented out again"
    assert_includes file, "\nRails.application.config.i18n.raise_on_missing_translations = true"
    stages = record.stages.select { |stage| stage.stage == "defaults" }
    assert_equal 3, stages.size, "two toggles, each a suite run of its own, and the summary"
    assert_includes stages.first.output_tail, "per_form_csrf_tokens"
    assert_includes stages.first.output_tail, "reverted"
    assert_includes stages[1].output_tail, "kept"
    assert_includes stages.last.output_tail, "1 of 2 new default(s) are on"
  end

  # And when every toggle passes, the guide's last step is taken: the line goes into the
  # application's class, the file goes, and the suite runs once more to prove the state that
  # survives — both files having been saved first, so a red run there is reverted exactly.
  def test_when_every_default_passes_the_file_is_dropped_and_load_defaults_written
    dir = track(app)
    with_source(dir, "config/initializers/new_framework_defaults_5_0.rb", <<~RUBY)
      # Enable per-form CSRF tokens. Previous versions had false.
      # Rails.application.config.action_controller.per_form_csrf_tokens = true

      # Raise an error when a translation is missing. Previous versions had false.
      # Rails.application.config.i18n.raise_on_missing_translations = true
    RUBY
    with_source(dir, "config/application.rb",
      "module Storefront\n  class Application < Rails::Application\n  end\nend\n")
    tests = SequencedTests.new(results: [green, green, green, green, green])

    record = step(dir, tests: tests, env: { "UPGRADER_DEFAULT_STEPS" => "5" }).run

    assert record.passed?, record.why
    refute File.exist?(File.join(dir, "config/initializers/new_framework_defaults_5_0.rb")),
      "the file and the line say the same thing; the line is the one that survives"
    assert_includes File.read(File.join(dir, "config/application.rb")), "config.load_defaults 5.0"
    last = record.stages.reverse.find { |stage| stage.stage == "defaults" }
    assert_includes last.output_tail, "every new default is on"
  end

  # **Off unless a number says otherwise.** Every toggle is a suite run, so a deployment that has
  # not decided to spend that must not have it spent for it — the same posture as the repair budget,
  # and the reason this is a switch rather than a default behaviour.
  def test_the_defaults_pass_is_off_unless_a_number_turns_it_on
    dir = track(app)
    with_source(dir, "config/initializers/new_framework_defaults_5_0.rb", <<~RUBY)
      # Rails.application.config.action_controller.per_form_csrf_tokens = true
    RUBY

    record = step(dir, tests: SequencedTests.new(results: [green, green])).run

    assert record.passed?, record.why
    assert_empty record.stages.select { |stage| stage.stage == "defaults" },
      "the pass ran without being asked for"
  end

  # **The residue reaches the brief, not the blanket.** A change with a call site is work; a change
  # this rung carried that the application does not use is not — and the two are handed over
  # separately, so the agent is not sent looking for call sites that do not exist.
  def test_the_repair_evidence_carries_the_located_findings_and_the_carried_count
    dir = track(app)
    with_source(dir, "app/models/post.rb", "class Post\nend\n")
    located = { "path" => "app/models/post.rb", "line" => 2, "subject" => "attr_accessible",
                "kind" => "removed", "source" => "4.0", "note" => "found here" }
    carried = change(subject: "alias_attribute", kind: "default_changed", source: "7.2",
      replacement: nil, note: "it reads the column directly")
    corpus = FakeCorpus.new(payload: plan(changes: [carried]), manual: [located])

    step(dir, corpus: corpus, tests: SequencedTests.new(results: [green, red, green]),
      repair: FakeRepair, env: { "UPGRADER_REPAIR_ATTEMPTS" => "1" }).run

    evidence = FakeRepair.last_evidence
    assert_equal ["attr_accessible"], evidence[:decisions].map(&:subject)
    assert_equal 1, evidence[:carried], "a change this application does not use is not work"
    assert_equal ["attr_accessible"], evidence[:unapplied_rules],
      "a line a rule knows and would not touch is the most specific thing the brief can carry"
  end

  # **The application's own environment, when the deployment knows it.** A repository that
  # carries no secrets cannot boot its own suite — this walk's first real application reads
  # `ENV["RAILS_SECRET_TOKEN"]` from a git-ignored `config/application.yml`, and a fresh clone
  # therefore fails its baseline for ever. The file is `KEY=VALUE` lines; the values reach the
  # commands that run *the application* and never the ones that are this tool's own.
  def test_a_suite_env_file_reaches_the_application_s_commands_and_not_the_bundle
    dir = track(app)
    File.write(File.join(dir, "config"), "") if File.exist?(File.join(dir, "config"))
    env_file = File.join(Dir.mktmpdir, "suite.env")
    @dirs_to_clean ||= []
    @dirs_to_clean << File.dirname(env_file)
    File.write(env_file, <<~ENV)
      # the application's secrets, from wherever the operator keeps them
      RAILS_SECRET_TOKEN='a token for this run'
      SECRET_WITH_EQUALS=pa=ss

      BLANK_IGNORED=1
    ENV
    tests = CapturingTests.new
    runner = FakeRunner.new

    step(dir, tests: tests, runner: runner, suite_env: env_file).run

    assert_equal "a token for this run", tests.envs.first["RAILS_SECRET_TOKEN"],
      "the suite did not receive the application's environment"
    assert_equal "pa=ss", tests.envs.first["SECRET_WITH_EQUALS"],
      "a value with an `=` in it must survive the split"
    bundle_env = runner.envs.map { |_command, env| env }.first || {}
    refute bundle_env.key?("RAILS_SECRET_TOKEN"),
      "this tool's own commands must not be handed the application's secrets"
  end

  # The install is what makes the baseline a measurement. Without it the suite runs against
  # whatever the image happens to have and `bin/rails` fails to find a gem that was never
  # installed — measured on the fixture: a "baseline" that came back red in 0.09s carrying a
  # bundler stack trace, which is the same shape of mistake as probing a release that was
  # never in the environment. The assertion is on the runner's calls *at the moment the
  # baseline ran*, because that is the only vantage point from which the order is visible.
  def test_the_bundle_is_installed_before_the_baseline
    dir = track(app)
    runner = FakeRunner.new
    tests = CapturingTests.new(runner: runner)

    record = step(dir, runner: runner, tests: tests).run

    assert record.passed?, record.why
    assert_equal ["git rev-parse --short HEAD", "bundle --version", "bundle install"], tests.calls_when_it_ran.first,
      "the baseline ran before the application's bundle was installed"
    # And the pin is not what installed it: resolving a new Rails is a later stage, and a
    # baseline taken after it would be a baseline of the wrong tree.
    refute_includes tests.calls_when_it_ran.first, "bundle update rails"
    assert record.stages.find { |stage| stage.stage == Agents::Upgrader::Record::BUNDLE }&.ok?,
      "the install is not recorded as a stage of the run"
  end

  # A bundle that will not install is an environment fact, not a verdict about the move,
  # and it is the machine failing to make the measurement — the third answer `AGENTS.md`
  # names. Recorded `failed`, it would blame a release for a gem that would not build here.
  def test_a_bundle_that_cannot_be_installed_is_unverified_rather_than_failed
    dir = track(app)
    runner = FakeRunner.new(fail_on: "bundle install")

    record = step(dir, runner: runner).run

    assert record.unverified?, "the move was blamed for an environment that would not build: #{record.why}"
    assert_includes record.why, "bundle install"
    assert_includes record.why, "exited 1"
    # The command's own output survives into the sentence: which gem, which index or which
    # compiler answered is the only thing that makes it actionable.
    assert_includes record.why, "boom"
    # And nothing after it ran — no pin, no `app:update`, no boot. Carrying on would report
    # on a tree whose gems are missing.
    assert_equal ["git rev-parse --short HEAD", "bundle --version", "bundle install"], runner.calls
  end

  # **A native extension that will not build needs the gem to move, and the installer names it.** Measured at the 7.2 rung on the 3.2 era: `nio4r 2.3.1` is a *transitive* gem
  # (actioncable depends on it), so nothing this tool edited names it and the conservative update had
  # nothing to widen — the install stage stopped with a bundle it could not build. The installer's own
  # sentence is the evidence, and the fix is the one the pin uses for a line it cannot resolve: name the
  # gem and let the resolver take the newest release that fits.
  def test_a_transitive_extension_that_will_not_build_is_named_in_the_update
    dir = track(app(lockfile: LOCKFILE.sub(/^(  specs:\n)/, "\\1    nio4r (2.3.1)\n")))
    runner = BrokenExtensionRunner.new

    step(dir, runner: runner).run

    assert_includes runner.calls, "bundle update nio4r",
      "the gem the installer named was not moved: #{runner.calls.inspect}"
  end

  # A kept tree — one the loop owns across cycles — is put back to its base commit before
  # the step reads it, and the case this exists for is a *skipped rung*: a cycle killed
  # after `bundle update rails` had already rewritten the lockfile would be re-planned from
  # 7.2.0, so the loop would report the next step as passed having never run the one that
  # was interrupted. An interrupted step settled nothing, so the tree it was measured in
  # holds nothing either.
  def test_a_kept_tree_that_is_dirty_is_put_back_before_the_step_reads_it
    dir = track(app)
    # What the interrupted step left: the pin rewritten in the Gemfile and the lockfile
    # resolved forward, plus a file `app:update` had added.
    File.write(File.join(dir, "Gemfile"), %(source "https://rubygems.org"\ngem "rails", "6.0.0"\n))
    File.write(File.join(dir, "Gemfile.lock"), LOCKFILE.sub("rails (4.2.11)", "rails (6.0.0)"))
    File.write(File.join(dir, "config_moved.rb"), "# what app:update wrote\n")

    out = StringIO.new
    record = step(dir, reuse: true, out: out).run

    assert_equal "4.2.11", record.from_version,
      "the step read a lockfile an interrupted run had already moved forward"
    assert_equal "5.0.0", record.to_version
    assert_includes out.string, "reset to", "the reset was silent"
    # The 6.0.0 the interrupted run had written is gone: this step's own rewrite is what
    # the Gemfile holds now, which is only true if the tree was put back first.
    gemfile = File.read(File.join(dir, "Gemfile"))
    assert_includes gemfile, %(gem "rails", "5.0.0")
    refute_includes gemfile, "6.0.0"
    refute File.exist?(File.join(dir, "config_moved.rb")), "the interrupted step's file survived"
  end

  # **A clean tree is not proof a step finished.** Concern commits move HEAD, so a process killed
  # after one leaves a clean tree on a half-move; the marker is what puts it back. Without this,
  # the next cycle would read the half-moved Gemfile.lock and plan the rung after a rung nobody
  # established.
  def test_a_clean_kept_tree_on_a_concern_commit_is_reset_to_its_marker
    dir = track(app)
    base = Agents::Upgrader::Checkpoint.head(dir).first.to_s
    File.write(File.join(dir, "Gemfile"), %(source "https://rubygems.org"\ngem "rails", "6.0.0"\n))
    Agents::Upgrader::Checkpoint.commit(dir, from: "4.2.11", to: "6.0.0",
      out: StringIO.new, concern: "pin Rails and move gems")
    refute Agents::Upgrader::Checkpoint.dirty?(dir), "the tree is dirty, so this proves nothing"
    Agents::Upgrader::Checkpoint.remember_base(dir, base)

    out = StringIO.new
    record = step(dir, reuse: true, out: out).run

    assert_equal "4.2.11", record.from_version,
      "the step read the half-move commit instead of the marker's base"
    assert_equal base, record.commit,
      "the record named the half-move commit as its base"
    assert_includes out.string, "reset to", "the reset was silent"
    assert_includes File.read(File.join(dir, "Gemfile")), %(gem "rails", "5.0.0")
  end

  # **A project's declaration is where its walk is, and a kept tree outlives a project.**
  # Measured on a reconnect: the repository was connected again at the release its Gemfile names
  # (4.2.11) while the loop's tree still sat at the top of the earlier walk (5.0.0). Planning from
  # the tree asked for a backwards move, which the ladder rightly refused — and a refusal is a fact
  # about the move, so the queue row settled and the new project could never move again. The tree
  # is put back to the commit its walk began at, and the moves that walk settled above it are
  # re-derived because they are not this walk's history.
  def test_a_kept_tree_ahead_of_the_project_is_put_back_to_the_declared_release
    dir = track(app)
    # What the earlier walk left: the rung committed, and the marker moved to it.
    File.write(File.join(dir, "Gemfile"), %(source "https://rubygems.org"\ngem "rails", "5.0.0"\n))
    File.write(File.join(dir, "Gemfile.lock"), LOCKFILE.sub("rails (4.2.11)", "rails (5.0.0)"))
    Agents::Upgrader::Checkpoint.commit(dir, from: "4.2.11", to: "5.0.0", out: StringIO.new)
    top = Agents::Upgrader::Checkpoint.head(dir).first
    Agents::Upgrader::Checkpoint.remember_base(dir, top)

    ledger = Agents::Upgrader::Ledger.new(path: File.join(dir, "ledger.json"), machine: "ruby test")
    ledger.record(repo: "acme/storefront", commit: Agents::Upgrader::Checkpoint.origin(dir),
      from_version: "4.2.11", to_version: "5.0.0", verdict: "passed", baseline: 0)

    out = StringIO.new
    record = step(dir, reuse: true, out: out, ledger: ledger, project: declaration).run

    refute_nil record, "the rewound walk was skipped by the settled entry of the walk it replaced"
    assert_equal "4.2.11", record.from_version,
      "the step planned from the abandoned tree's release rather than the project's"
    assert_includes out.string, "put back to", "the rewind was silent"
    refute_equal top, record.commit, "the record named the abandoned walk's commit as its base"
    assert_includes File.read(File.join(dir, "Gemfile")), %(gem "rails", "5.0.0")
  end

  # **A rewind's parse follows the reset, because the lock is what names the framework.** The
  # pin asks the lock which gems are pinned at the release it is moving from, and a lock read
  # before the rewind describes the tree that was walked *ahead*: measured on the first real
  # reconnect, `pinned_at("4.0.0.rc1")` was asked of a 4.1.0 lock, named nothing, and the resolve
  # kept `activemodel` at rc1 while Rails moved to 4.0.13 — a patch rung that failed on a
  # `could not find compatible versions` the named set would have avoided.
  def test_a_rewound_tree_is_pinned_from_the_lock_it_was_put_back_to
    lock = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          activesupport (4.2.11)
          rails (4.2.11)

      PLATFORMS
        ruby

      DEPENDENCIES
        rails (= 4.2.11)

      BUNDLED WITH
         2.5.22
    LOCK
    dir = track(app(lockfile: lock))
    # What the earlier walk left: the rung committed, and the marker moved to it.
    File.write(File.join(dir, "Gemfile"), %(source "https://rubygems.org"\ngem "rails", "5.0.0"\n))
    File.write(File.join(dir, "Gemfile.lock"), lock.gsub("4.2.11", "5.0.0"))
    Agents::Upgrader::Checkpoint.commit(dir, from: "4.2.11", to: "5.0.0", out: StringIO.new)
    top = Agents::Upgrader::Checkpoint.head(dir).first
    Agents::Upgrader::Checkpoint.remember_base(dir, top)

    record = step(dir, reuse: true, out: StringIO.new, project: declaration).run

    assert record.passed?, record.why
    pin = record.stages.find { |stage| stage.stage == "pin" }
    refute_nil pin, "the step never asked the resolver to move the framework"
    assert_includes pin.command.to_s, "activesupport",
      "the pin read the abandoned tree's lock, so the framework's components were not named"
  end

  # The other half of the same rule: a tree already at the project's release is left alone, so
  # an ordinary cycle does not pay a reset — and the ledger keeps its say about a move it settled.
  def test_a_kept_tree_at_the_project_s_release_is_not_rewound
    dir = track(app)
    out = StringIO.new
    record = step(dir, reuse: true, out: out, project: declaration).run

    assert record.passed?, record.why
    assert_equal "4.2.11", record.from_version
    refute_includes out.string, "put back to"
  end

  def declaration
    Agents::Upgrader::Project.new(
      { "slug" => "storefront", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0" }
    )
  end

  # **A native machine cannot install a package, and says so rather than skipping it.** `apt` needs
  # root, and a walk that took root on somebody's laptop is not this tool's decision; the
  # declaration still travels into the record, so a bundle that fails for a missing header has a
  # named cause rather than an unexplained one.
  def test_a_native_machine_records_the_system_packages_it_did_not_install
    project = Agents::Upgrader::Project.new({
      "slug" => "storefront", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0",
      "toolchain" => { "apt" => ["libidn11-dev"] }
    })
    record = step(track(app), project: project).run

    stage = record.stages.find { |command| command.stage == Agents::Upgrader::Record::PACKAGES }
    refute_nil stage, "the declaration never reached the record"
    refute stage.ran, "a native machine ran an apt install"
    assert_includes stage.output_tail, "not a container"
    assert_includes stage.command, "libidn11-dev"
  end

  # A hand-run step never resets anything: it takes a fresh copy per run (the fake source
  # hands back the fixture itself, so a reset here would eat the test's own files), and
  # the flag is threaded all the way to the source rather than assumed.
  def test_the_step_asks_the_source_for_a_kept_tree_only_when_it_is_told_to
    dir = track(app)

    step(dir).run
    assert_equal false, @source.asked.last[:reuse]

    step(dir, reuse: true).run
    assert_equal true, @source.asked.last[:reuse]
  end

  # The whole point of installing the bundle into the run's own directory is that every
  # later stage loads *that* one. `Tests.run` and `bin/rails` are two different spawns and
  # the env is the only thing joining them to the install.
  def test_the_suite_and_the_application_run_under_the_bundle_this_run_installed
    dir = track(app)
    runner = FakeRunner.new
    tests = CapturingTests.new(runner: runner)

    record = step(dir, runner: runner, tests: tests).run
    expected = @source.bundle_env(machine: :any)["BUNDLE_PATH"]

    assert record.passed?, record.why
    expected = @source.bundle_env(machine: :any)["BUNDLE_PATH"]
    assert_equal [expected, expected], tests.envs.map { |env| env["BUNDLE_PATH"] },
      "the baseline and the post-step suite did not run under this run's bundle"
    rails_commands = runner.envs.select { |call, _env| call.match?(/bundle|rails/) }
    refute_empty rails_commands, "no bundler or Rails command ran"
    outside = rails_commands.reject { |_call, env| env["BUNDLE_PATH"] == expected }
    assert_empty outside, "a Rails command ran outside this run's bundle: #{outside.inspect}"
  end

  # **A patch checkpoint is maintenance, and the stages it leaves out are the point.** A patch release
  # documents no change the ladder could apply, so the run pins, boots and measures: no plan to fetch,
  # no scan, no accepted-decision edit, no `app:update` and no framework defaults. If any of those ran,
  # the tool would be changing an application for a release that documents no change to it. The
  # preflight does run: it is the repair that makes the Gemfile installable at all, not a change for
  # the release, and the interpreter probe is itself an install.
  def test_a_patch_checkpoint_runs_the_maintenance_pipeline_and_repairs_only_the_environment
    dir = track(app)
    corpus = FakeCorpus.new(payload: plan)
    runner = FakeRunner.new
    tests = CapturingTests.new(runner: runner)

    record = step(dir, corpus: corpus, runner: runner, tests: tests, to: "4.2.12").run

    assert record.passed?, record.why
    assert_equal "4.2.11", record.from_version
    assert_equal "4.2.12", record.to_version, "the record named a minor instead of the checkpoint"
    assert_includes File.read(File.join(dir, "Gemfile")), %(gem "rails", "4.2.12")
    assert_equal 2, tests.seen.size, "a patch run is a baseline and one suite"

    stages = record.stages.map(&:stage)
    assert_includes stages, "preflight", "the patch run installed a Gemfile it never made installable"
    assert_includes stages, "baseline"
    assert_includes stages, "pin"
    assert_includes stages, "suite"
    assert_empty stages & %w[apply decisions rails:update defaults style],
      "a patch run took a rung's stages: #{stages.inspect}"
    assert_empty runner.calls.grep(/app:update|rails:update/), "a patch run ran app:update"
    assert_empty (corpus.upgrade_calls || []), "a patch run asked the ladder for a plan"
  end

  # **A patch checkpoint cannot measure a Gemfile it cannot install, and the protocol is the
  # application's fact rather than the rung's.** The preflight's repairs run in both pipelines for
  # the reason the rung's own test states: the machine choice *is* a `bundle install`, so a dead
  # `git://` remote rejects every era and the record blames the matrix for it. This is the run that
  # proved it — an application on 4.0.0.rc1 whose lockfile still named the retired protocol.
  def test_a_patch_checkpoint_repairs_an_uninstallable_gemfile_before_the_install
    dir = track(app(gemfile: <<~GEM))
      source "https://rubygems.org"
      gem "rails", "4.2.11"
      gem "cancan", git: "git://github.com/moriz/cancan.git"
    GEM
    corpus = FakeCorpus.new(payload: plan, migrations: [
      { "gem" => "cancan", "kind" => "replaced", "replacement" => "cancancan",
        "requirement" => "~> 1.9", "mechanical" => true,
        "note" => "the Rails-4 fork is gone", "source" => "the index" }
    ])

    record = step(dir, corpus: corpus, to: "4.2.12").run

    stages = record.stages.map(&:stage)
    assert_operator stages.index("preflight"), :<, stages.index("bundle"),
      "the install ran before the Gemfile was made installable"
    assert_equal %w[cancan git://], record.applied.map(&:subject).sort,
      "a patch checkpoint ran without the repairs that let its bundle install"
    assert_includes record.patch, %(gem "cancancan", "~> 1.9")
  end

  # **The plan says which minor moved; the checkpoint says which patch is installed.** A latest-patch
  # checkpoint on 5.0.6 uses the 5.0 chapter and writes 5.0.6 — the record and the branch must never
  # say the chapter's `.0`, which is a release nobody approved.
  def test_a_minor_checkpoint_pins_its_exact_patch_while_using_the_minor_plan
    dir = track(app)
    corpus = FakeCorpus.new(payload: plan(to: "5.0.0", from: "4.2.11"))

    record = step(dir, corpus: corpus, to: "5.0.6").run

    assert record.passed?, record.why
    assert_equal "5.0.6", record.to_version, "the record named the plan's .0 instead of the checkpoint"
    assert_includes File.read(File.join(dir, "Gemfile")), %(gem "rails", "5.0.6")
    stages = record.stages.map(&:stage)
    assert_includes stages, "rails:update", "the minor plan's app:update did not run"
    refute_includes record.name.to_s, "5.0.0", "the plan's release leaked into the checkpoint's name"
  end

  # **The move records the tree's release, not the chapter's.** The service files the plan for a
  # 5.0 checkpoint under the 5.0 chapter, whose `from` is `4.2.0`; the application is on `4.2.11`.
  # A record that kept the chapter's from made the delivery look for
  # `agents/upgrade-4.2.0`, find no such branch, and base the request on the default branch —
  # so the walk opened a stack's worth of pull requests that were all based on master.
  def test_a_checkpoint_records_the_lockfile_s_release_as_the_move_s_from
    dir = track(app)
    corpus = FakeCorpus.new(payload: plan(to: "5.0.0", from: "4.2.0"))

    record = step(dir, corpus: corpus, to: "5.0.6").run

    assert record.passed?, record.why
    assert_equal "4.2.11", record.from_version,
      "the record kept the plan's rung instead of the release the branch was built from"
    assert_equal "5.0.6", record.to_version
  end

  # **A checkpoint behind the lockfile is a stale feed, not a patch move.** Pinning it would write
  # a downgrade and then report a pass the service refuses to advance; the step refuses instead.
  def test_a_checkpoint_behind_the_lockfile_is_refused_without_touching_the_tree
    dir = track(app)

    record = step(dir, to: "4.2.10").run

    assert_equal "refused", record.verdict
    assert_match(/behind the lockfile/, record.why)
    assert_includes File.read(File.join(dir, "Gemfile")), %(gem "rails", "4.2.11")
  end

  def test_the_baseline_runs_before_anything_is_written
    dir = track(app)
    tests = CapturingTests.new
    record = step(dir, tests: tests).run

    assert_equal 2, tests.seen.size, "the suite ran #{tests.seen.size} time(s): a baseline and a check is two"
    assert_includes tests.seen.first, %(gem "rails", "4.2.11"),
      "the baseline ran after the pin had already been rewritten"
    assert_includes tests.seen.last, %(gem "rails", "5.0.0"),
      "the suite after the step ran against the original Gemfile"
    assert record.baseline&.ok?, record.why
    assert record.passed?, record.why
    assert_includes File.read(File.join(dir, "Gemfile")), %(gem "rails", "5.0.0")

    stages = record.stages.map(&:stage)
    assert_operator stages.index("baseline"), :<, stages.index("pin"),
      "the pin was rewritten before the suite ran against the original"
  end

  # A settled move costs nothing — that is the whole point of keeping a ledger. What it
  # does *not* save is the preparation: the service's plan is the only thing that says
  # which move is next, and the starting release comes from a lockfile in a working copy,
  # so the clone and one `rev-parse` happen either way. The assertion is on the expensive
  # half, which is what a settled move exists to avoid: no bundle resolve, no Rails, no
  # suite.
  def test_a_move_the_ledger_has_settled_is_not_run_again
    dir = track(app)
    ledger_path = File.join(dir, "ledger.json")
    ledger = Agents::Upgrader::Ledger.new(path: ledger_path, machine: "ruby test")
    ledger.record(repo: "acme/storefront", commit: "9f2c1ab8", from_version: "4.2.11",
      to_version: "5.0.0", verdict: "passed", baseline: 0)
    runner = FakeRunner.new
    tests = CapturingTests.new

    assert_nil step(dir, runner: runner, tests: tests, ledger: ledger).run,
      "a settled move produced a record"

    expensive = runner.calls.select { |call| call.match?(/bundle|rails|rake/) }
    assert_empty expensive, "a settled move ran: #{expensive.inspect}"
    assert_empty tests.seen, "a settled move ran the suite"
  end

  # The service's sentence is the whole answer when it refuses, and it must survive to
  # the record rather than being read as a crash.
  def test_a_service_refusal_is_a_refusal_carrying_the_service_s_sentence
    dir = track(app)
    corpus = FakeCorpus.new(refuse: "this ladder reads forward upgrades only, so a move to 1.0.0 has no chapter")
    record = step(dir, corpus: corpus).run

    assert record.refused?
    assert_includes record.why, "reads forward upgrades only"
  end

  # A Gemfile this tool does not understand is refused rather than guessed at: choosing which
  # framework components move together is a decision, and says no decision is inferred.
  def test_a_gemfile_that_pins_components_is_refused_rather_than_guessed
    dir = track(app(lockfile: COMPONENTS_LOCKFILE,
      gemfile: %(source "https://rubygems.org"\ngem "railties", "5.2.8"\n)))
    runner = FakeRunner.new
    record = step(dir, runner: runner).run

    assert record.refused?
    assert_includes record.why, "does not pin the meta-gem"
    assert_empty runner.calls.select { |call| call.include?("update") }, "the bundle was updated anyway"
  end

  def test_a_step_with_no_suite_is_unverified_rather_than_passed
    dir = track(app)
    record = step(dir, tests: FakeTests.new(suite: nil)).run

    assert record.unverified?
    assert_includes record.why, "no test suite was found"
  end

  # Where the user is pointed: `--record` writes the patch and the JSON, and the JSON
  # says the caller's repository was not touched.
  def test_the_record_and_the_patch_are_written_where_the_operator_asked
    dir = track(app)
    out = track(Dir.mktmpdir)

    record = step(dir, record: out).run
    json, patch = record.write(out)
    body = JSON.parse(File.read(json))

    assert_equal "passed", body["verdict"]
    assert_equal true, body["wrote_nothing_to_the_repository"]
    assert File.file?(patch)
    assert_includes File.read(patch), %(gem "rails", "5.0.0")
  end

  # `app:update` proposes new versions of files the application already owns, and
  # "take theirs" is how an application loses its configuration. This is the rule that
  # keeps `config.load_defaults` where the application put it, without a special case.
  def test_app_update_may_keep_only_what_it_added
    dir = track(app)
    FileUtils.mkdir_p(File.join(dir, "config"))
    owned = File.join(dir, "config", "application.rb")
    File.write(owned, "load_defaults 6.0\n")
    # Committed first, so that the file is one the *application owns* and not a new one.
    # This line is the difference between testing the rule and testing nothing: a file
    # git has never seen is untracked, and git reports a wholly untracked directory as
    # one entry — `?? config/` — so the policy was handed a directory, found no conflict
    # in it, and this test passed while the case it exists for went unexercised.
    commit(dir, "the application's own config")
    assert_empty Agents::Upgrader::Step.dirty_paths(dir), "the fixture is not clean"

    before = Agents::Upgrader::Step.dirty_paths(dir)
    # What `app:update` does: rewrites a file the application owns and creates one.
    added = File.join(dir, "config", "new_defaults.rb")
    File.write(owned, "load_defaults 7.0\n")
    File.write(added, "# new\n")

    adopted, conflicts = Agents::Upgrader::Step.adopt_added_only(dir, before)

    assert_equal ["config/new_defaults.rb"], adopted
    assert_equal ["config/application.rb"], conflicts
    assert_equal "load_defaults 6.0\n", File.read(owned), "the application's version was overwritten"
    assert File.file?(added)
  end

  # **The 4.1 cookie default is for a new application, not this one.** The generated
  # `:json` would fail to read every Marshal cookie a 4.0 app already issued; `:hybrid`
  # reads both and writes JSON. The next rung completes the transition.
  def test_app_update_sets_the_4_1_cookie_transition_to_hybrid
    dir = track(Dir.mktmpdir)
    path = File.join(dir, "config", "initializers", "cookies_serializer.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "Rails.application.config.action_dispatch.cookies_serializer = :json\n")

    applied, refused, reconciled = Agents::Upgrader::Step.reconcile_app_update(
      root: dir, adopted: ["config/initializers/cookies_serializer.rb"], rung: "4.1.0"
    )

    assert_empty refused
    assert_equal 1, applied.length
    assert_equal "cookies_serializer", applied.first.subject
    assert_equal "app_update", applied.first.origin
    assert_includes File.read(path), "= :hybrid"
    assert_equal ["config/initializers/cookies_serializer.rb"], reconciled.map { |entry| entry["path"] }
  end

  # **The transition is one release long.** A 4.1 branch left `:hybrid` in place; the
  # 4.2 rung writes `:json` once the old cookies have aged out.
  def test_the_next_rung_completes_the_cookie_transition
    dir = track(Dir.mktmpdir)
    path = File.join(dir, "config", "initializers", "cookies_serializer.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "Rails.application.config.action_dispatch.cookies_serializer = :hybrid\n")

    applied, _refused, _reconciled = Agents::Upgrader::Step.reconcile_app_update(
      root: dir, adopted: [], rung: "4.2.0"
    )

    assert_equal 1, applied.length
    assert_includes File.read(path), "= :json"
  end

  # **One key source, the one the deployment already uses.** app:update adds
  # `secrets.yml` reading `SECRET_KEY_BASE`; the 4.0 initializer names
  # `RAILS_SECRET_TOKEN`. The generated file is pointed at the old name and the
  # initializer is removed, so the deploy does not have to change a variable.
  def test_app_update_moves_the_old_secret_key_to_secrets_yml
    dir = track(Dir.mktmpdir)
    secrets = File.join(dir, "config", "secrets.yml")
    legacy = File.join(dir, "config", "initializers", "secret_token.rb")
    FileUtils.mkdir_p(File.dirname(legacy))
    File.write(secrets, "production:\n  secret_key_base: <%= ENV[\"SECRET_KEY_BASE\"] %>\n")
    File.write(legacy, "Bidding::Application.config.secret_key_base = ENV[\"RAILS_SECRET_TOKEN\"]\n")

    applied, refused, reconciled = Agents::Upgrader::Step.reconcile_app_update(
      root: dir, adopted: ["config/secrets.yml"], rung: "4.1.0"
    )

    assert_empty refused
    assert_equal 2, applied.length
    assert_includes File.read(secrets), "ENV[\"RAILS_SECRET_TOKEN\"]"
    refute File.exist?(legacy), "the obsolete initializer survived the reconciliation"
    assert_equal 2, reconciled.length
  end

  # **A literal key is a person's decision.** The tool can move an `ENV[...]`; it must
  # not copy a literal secret into a tracked file or guess which source to keep.
  def test_a_literal_secret_key_is_refused_rather_than_moved
    dir = track(Dir.mktmpdir)
    secrets = File.join(dir, "config", "secrets.yml")
    legacy = File.join(dir, "config", "initializers", "secret_token.rb")
    FileUtils.mkdir_p(File.dirname(legacy))
    File.write(secrets, "production:\n  secret_key_base: <%= ENV[\"SECRET_KEY_BASE\"] %>\n")
    File.write(legacy, "Bidding::Application.config.secret_key_base = \"a literal key\"\n")

    applied, refused, reconciled = Agents::Upgrader::Step.reconcile_app_update(
      root: dir, adopted: ["config/secrets.yml"], rung: "4.1.0"
    )

    assert_empty applied
    assert_equal 1, refused.length
    assert_equal "secret_key_base", refused.first.subject
    assert File.file?(legacy), "a literal initializer was deleted"
    assert_empty reconciled
  end

  # The corpus is written to by the *loop*, not by a person running one step: a hand-run
  # step that filed a report would make a shared corpus the side effect of asking a
  # question, and the operator never asked for it.
  def test_a_step_run_by_hand_writes_nothing_to_the_corpus
    dir = track(app)
    corpus = RecordingCorpus.new(payload: plan)
    record = step(dir, corpus: corpus).run

    assert record.passed?, record.why
    assert_empty corpus.calls, "a hand-run step wrote to the corpus"
  end

  def test_a_serving_step_records_the_run_and_files_what_failed
    dir = track(app)
    corpus = RecordingCorpus.new(payload: plan)
    tests = SequencedTests.new(results: [green, red])
    record = step(dir, corpus: corpus, tests: tests, contribute: true).run

    assert record.failed?, record.why

    recorded = corpus.calls_of(:record_run)
    assert_equal 1, recorded.size, "the run was not recorded exactly once"
    assert_equal "failed", recorded.first["verdict"]
    assert_equal "passed", recorded.first["baseline_verdict"], "the baseline's own outcome was lost"
    assert_equal "4.2.11", recorded.first["from_version"]
    assert_equal "5.0.0", recorded.first["to_version"]
    assert recorded.first["commands"].any? { |command| command["stage"] == "suite" },
      "the commands the run carries do not include the suite that failed"

    # And the finding, through precheck first: the corpus decides whether it is already
    # known, which is the whole reason the write is two calls.
    assert_equal 1, corpus.calls_of(:precheck).size
    filed = corpus.calls_of(:create_report)
    assert_equal 1, filed.size, "a failed step filed no report"
    assert_equal "rails", filed.first["library"]
    assert_equal "5.0.0", filed.first["version"]
    assert_equal "ruby", filed.first["ecosystem"]
    assert_equal "4.2.11", filed.first["from_version"]
    assert_includes filed.first["problem"], "exited 1"
    assert_includes filed.first["trace"], "1 failure"
  end

  def test_a_passing_serving_step_is_recorded_and_files_nothing
    dir = track(app)
    corpus = RecordingCorpus.new(payload: plan)
    record = step(dir, corpus: corpus, contribute: true).run

    assert record.passed?, record.why
    assert_equal 1, corpus.calls_of(:record_run).size
    assert_empty corpus.calls_of(:create_report), "a passing step filed a report"
    assert_empty corpus.calls_of(:precheck), "a passing step was prechecked"
  end

  # **A run is not lost to a restart beside the walk.** The corpus is a remote; measured on this
  # deployment, `5.1.0 -> 5.2.0` passed while `service:8001` was being recreated, the client logged
  # `not recorded: … ECONNREFUSED`, and the rung — settled, never revisited — kept no run at all. The
  # push and the pull request retry; this is the third write with the same shape.
  def test_a_run_is_retried_when_the_corpus_is_briefly_unreachable
    dir = track(app)
    corpus = FlakyRecordingCorpus.new(payload: plan, failures: 2)
    pauses = []

    record = step(dir, corpus: corpus, contribute: true,
      pause: ->(seconds) { pauses << seconds }).run

    assert record.passed?, record.why
    assert_equal 1, corpus.calls_of(:record_run).size, "the run was recorded more than once"
    assert_equal [5, 10], pauses, "the retries did not back off"
  end

  # The run body is the whole of what this tool tells the service, so it is asserted
  # rather than implied by the call above.
  # **Recall happens before the pin, and the record carries it.** The brief is asked where the rung's
  # gems are known and nothing that can change has happened yet; what comes back travels in the record
  # and in the run body, so a reader of the pull request or the site admin sees what the walk knew before
  # it decided. A brief that lived only in the log is the failure the design notes name.
  def test_the_rung_is_briefed_before_it_acts_and_the_brief_travels_with_the_record
    payload = plan(changes: [change])
    payload["steps"].first["observed"] = []
    corpus = FakeCorpus.new(payload: payload,
      route: { "ruby" => "2.2.2", "rails" => "5.0.0", "gems_read" => 1,
               "counts" => { "keep" => 0, "move" => 1, "replace" => 0, "remove" => 0, "blocked" => 0,
                             "unknown" => 0 },
               "gems" => [{ "name" => "factory_girl", "version" => "2.6.0", "to" => "4.0.0",
                            "verdict" => "replace" }] })

    record = step(track(app), corpus: corpus).run

    refute_nil record.brief, "the rung was walked without a brief"
    gem_section = record.brief.sections.find { |section| section.key == "gem:factory_girl" }
    refute_nil gem_section, "the brief did not ask about the gem the routing moves"
    assert_equal %w[factory_girl], corpus.upgrade_calls.map(&:first),
      "the framework section re-asked the window instead of reading the plan it already had"

    payload = Agents::Upgrader::Step.run_payload(record)
    assert_equal record.brief.asked, payload.dig("brief", "asked")
    assert_equal gem_section.key, payload.dig("brief", "sections").map { |s| s["key"] }.find { |k| k == gem_section.key }
  end

  # **The plan's joined half reaches the brief the step records.** The plan already fetched the
  # rung's observed reports, the reports that joined nothing and the rules in force; the step hands
  # the plan to the brief instead of asking the library window a second time.
  def test_the_brief_carries_the_plan_s_observed_and_unmatched_changes
    payload = plan(changes: [change(subject: "before_filter", kind: "renamed")])
    payload["steps"].first["observed"] = [{
      "report_id" => "r1", "title" => "before_filter is gone", "library" => "actionpack",
      "broken_in" => "5.0.0", "status" => "resolved_verified",
      "change_kind" => "symbol_removed", "change_key" => "ruby|actionpack|before_filter",
      "resolution" => "use before_action"
    }]
    payload["steps"].first["observed_unmatched"] = [{
      "report_id" => "r2", "title" => "a report nobody documented", "library" => "rails",
      "broken_in" => "5.0.0", "status" => "open", "change_key" => "ruby|rails|unknown"
    }]
    payload["steps"].first["rules"] = [{ "change_key" => "ruby|actionpack|before_filter",
      "kind" => "rewrite", "authority" => "curated" }]
    payload["steps"].first["counts"] = { "observed_unclassified" => 1 }
    corpus = FakeCorpus.new(payload: payload)

    record = step(track(app), corpus: corpus).run

    section = record.brief.sections.first
    assert_equal %w[r1 r2], section.items.filter_map(&:id)
    assert_equal "ruby|actionpack|before_filter", section.items.first.change_key
    assert_equal "unmatched", section.items[1].match
    assert_equal "curated", section.items.last.authority
    assert_empty Array(corpus.upgrade_calls),
      "the brief asked the window after the plan had already joined it"
  end

  # **The run body carries the review brief's internal sections.** The service stores them for the
  # site admin; the public run response stays frozen.
  def test_the_run_body_carries_the_gate_the_commits_and_the_update
    project = Agents::Upgrader::Project.parse({
      "slug" => "storefront", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0",
      "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" },
      "checks" => [{ "id" => "lint", "kind" => "lint", "command" => "ruby -e 'exit 0'" }],
      "toolchain" => { "ruby" => "3.3.12", "postgres" => "pgvector/pgvector:pg16" },
      "app_update" => { "framework_defaults" => "step" }
    }.to_json)

    record = step(track(app), project: project).run
    payload = Agents::Upgrader::Step.run_payload(record)

    assert_equal ["lint"], payload["checks"].map { |check| check["id"] }
    assert_includes payload["commits"].map { |commit| commit["concern"] }, "pin Rails and move gems"
    assert_equal "step", payload["app_update"]["framework_defaults"]
    assert_equal "3.3.12", payload["toolchain"]["ruby"]
    assert_includes payload["interpreter"], "ruby"
  end

  # **The service refuses a body larger than its own bound rather than clipping it.** A real
  # application's app:update patch is over two million characters; the run body sends the
  # first two million and the local record keeps the whole patch.
  def test_the_run_body_clips_a_patch_beyond_the_service_s_bound
    record = step(track(app), corpus: FakeCorpus.new(payload: plan(changes: [change]))).run
    record.instance_variable_set(:@patch, "x" * (Agents::Upgrader::Step::RUN_PATCH_LIMIT + 10))

    payload = Agents::Upgrader::Step.run_payload(record)

    assert_equal Agents::Upgrader::Step::RUN_PATCH_LIMIT, payload["patch"].length,
      "the run body carried a patch the service refuses"
  end

  def test_a_refused_run_names_the_field_the_service_would_not_take
    out = StringIO.new
    step(track(app), corpus: RefusingRunCorpus.new(payload: plan(changes: [change])),
      contribute: true, out: out).run

    assert_includes out.string, "not recorded: Request validation failed."
    assert_includes out.string, "patch: is too long"
    assert_includes out.string, "send at most 2,000,000 characters"
  end

  # **A long field is a summary the service clips, not a run it discards.** The second
  # lighthouse's plan source was 101 characters, and the service refused the whole run.
  def test_a_long_decision_source_is_clipped_rather_than_refused
    source = "the guide's chapter and the paragraph it is on, again and again " * 3
    decision = Agents::Upgrader::Record::Decision.new(
      subject: "config/initializers/x.rb", kind: "manual", source: source, reason: "why")
    record = Agents::Upgrader::Record.new(
      repository: "acme/storefront", from_version: "4.2.11", to_version: "5.0.0",
      verdict: "passed", why: "ok", decisions: [decision])

    refusal = Agents::Upgrader::Step.run_payload(record)["refusals"].first

    assert_equal 100, refusal["source"].length,
      "the payload sent a source the service refuses"
    assert_equal source, record.decisions.first.source, "the record gave up the whole sentence"
  end

  # **The application's own JavaScript dependencies are installed before the suite.** The
  # second lighthouse renders `_application.scss`, which imports `perfect-scrollbar/css/...`
  # from `node_modules`; the application's CI runs `yarn install`, and a fresh tree does not.
  def test_a_javascript_lockfile_is_installed_before_the_suite
    dir = track(app)
    File.write(File.join(dir, "yarn.lock"), "# yarn lockfile v1\n")

    record = step(dir, corpus: FakeCorpus.new(payload: plan(changes: [change]))).run

    stage = record.stages.find { |s| s.stage == Agents::Upgrader::Record::JAVASCRIPT }
    refute_nil stage, "the yarn.lock was not installed"
    assert_includes stage.command, "yarn install --frozen-lockfile"
    assert_equal 0, stage.exit_code
  end

  # **The asset manifest is a build product the application's CI makes.** The second
  # lighthouse's suite renders `javascript_include_tag :main`, and sprockets-rails refuses
  # an undeclared asset when `public/assets` was never built; the baseline compiles it first.
  def test_assets_are_precompiled_before_the_suite
    dir = track(app)
    FileUtils.mkdir_p(File.join(dir, "app", "assets"))

    record = step(dir, corpus: FakeCorpus.new(payload: plan(changes: [change]))).run

    stage = record.stages.find { |s| s.stage == Agents::Upgrader::Record::ASSETS }
    refute_nil stage, "the asset manifest was not built"
    assert_includes stage.command, "assets:precompile"
    assert_equal 0, stage.exit_code
  end

  # **The asset compile has to happen twice, and the second one is the one that matters.**
  # The first stage runs on the application's old bundle; the 4.1 rung's `jquery-rails 3.1.5`
  # stopped shipping jQuery UI and only a post-pin compile sees it. The stage is after the
  # pin and before the suite, because that is the bundle the suite and the deployment get.
  def test_assets_are_precompiled_again_after_the_pin_and_before_the_suite
    dir = track(app)
    FileUtils.mkdir_p(File.join(dir, "app", "assets"))

    record = step(dir, corpus: FakeCorpus.new(payload: plan(changes: [change]))).run
    assets = record.stages.each_index.select { |i| record.stages[i].stage == Agents::Upgrader::Record::ASSETS }
    pin = record.stages.index { |s| s.stage == Agents::Upgrader::Record::PIN }
    suite = record.stages.index { |s| s.stage == Agents::Upgrader::Record::SUITE }

    assert_equal 2, assets.length, "the assets were not compiled after the pin"
    assert_operator assets.last, :>, pin, "the second compile is not after the pin"
    assert_operator assets.last, :<, suite, "the second compile is not before the suite"
  end

  # **A conflict the generator's prompt answered `n` to is still a conflict.** The 4.1
  # rung's `rails:update` listed eight files it wanted to overwrite; the walker answered
  # `n` for every one, so they were never dirty and `adopt_added_only` recorded none of
  # them — and the PR body said “0 conflict(s)” while the task's output listed eight.
  def test_the_generator_s_prompt_conflicts_are_read_off_its_own_output
    output = <<~TEXT
      \e[1m\e[34m       exist\e[0m  config
      \e[1m\e[31m    conflict\e[0m  config/routes.rb
      Overwrite /tmp/tree/config/routes.rb? (enter "h" for help) [Ynaqdh]         skip  config/routes.rb
      \e[1m\e[31m    conflict\e[0m  config/application.rb
      Overwrite /tmp/tree/config/application.rb? (enter "h" for help) [Ynaqdh]         skip  config/application.rb
    TEXT

    assert_equal %w[config/routes.rb config/application.rb],
      Agents::Upgrader::Step.update_conflicts(output)
  end

  def test_the_run_body_carries_the_evidence_and_the_refusals
    dir = track(app)
    planned = plan(changes: [change])
    record = step(dir, corpus: FakeCorpus.new(payload: planned)).run
    payload = Agents::Upgrader::Step.run_payload(record)

    assert_equal "acme/storefront", payload["repo_url"]
    assert_equal "passed", payload["baseline_verdict"]
    assert_includes payload["patch"].to_s, %(gem "rails", "5.0.0"), "the patch is not in the run"
    assert payload["finished_at"]
    assert payload["commands"].all? { |command| command.key?("exit_code") }
    assert payload["commands"].all? { |command| command.key?("display") }
    assert payload["commands"].any? { |command| command["display"].to_s.include?("bundle") },
      "the run body did not carry the application's own command"
    baseline = payload["commands"].find { |command| command["stage"] == "baseline" }
    assert_equal "bundle exec rspec", baseline["display"],
      "the suite stage lost its command because it carries no separate display"
    assert payload["commands"].any? { |command| command["stage"] == "pin" }
    # The ladder's manual half is a decision for a person, and it travels as one — a
    # refusal list that could not name the change could say how much was left to do and
    # not what it was.
    refute_empty payload["refusals"], "a step that carried a decision filed no refusal"
    refusal = payload["refusals"].first
    assert_equal "before_filter", refusal["subject"]
    assert_equal "5.0", refusal["source"]
    assert_equal "before_action", refusal["replacement"]
    # And the fields mean what the service's own model says they mean. They used to carry
    # this tool's word for *who* refused — `"plan"` / `"applier"` — where the service
    # reads the kind of change and the guide chapter.
    refute_includes %w[plan applier], refusal["kind"]
  end

  # The service's 422 names the field it would not take; the client has to carry that to
  # the operator rather than log only the generic sentence.
  class RefusingRunCorpus < FakeCorpus
    def record_run(_payload)
      raise Agents::Upgrader::Corpus::Refused.new("Request validation failed.",
        { "error" => { "details" => [{ "field" => "patch", "message" => "is too long" }] },
          "next_step" => "send at most 2,000,000 characters" })
    end
  end

  def green
    Agents::Upgrader::Tests::Result.new(
      command: "bundle exec rspec", ran: true, passed: true, exit_code: 0, seconds: 0.2,
      output_tail: "3 examples, 0 failures", timed_out: false
    )
  end

  def red
    Agents::Upgrader::Tests::Result.new(
      command: "bundle exec rspec", ran: true, passed: false, exit_code: 1, seconds: 0.2,
      output_tail: "1 examples, 1 failure", timed_out: false
    )
  end

  # The refusal list is half the product, and the half no patch carries: a change this
  # step carried and no machine may make, with the ladder's own reason. It is driven by
  # the *plan's* list, which is the part a real step found missing — the 7.1 -> 7.2 rung
  # documents `alias_attribute` and an application that never mentions it has no call
  # site, so a record built from the scan's `manual` list read "0 need(s) a decision"
  # beside a plan that named one.
  #
  # **What changed is what the record says about it.** A survey exists for this subject and
  # it read the tree: no call site, so there is nothing to edit and nothing a rule could be
  # written for. Measured on the walk's last rungs, the decision carried "not automated yet:
  # …" beside the survey's own "none found", which reads as work somebody skipped; it is
  # carried now as `checked`, and the summary counts it apart from located work.
  def test_a_change_with_no_call_site_is_carried_as_checked_rather_than_owed
    dir = track(app)
    # The survey needs a tree to read: a repository with no Ruby source answers before the
    # survey runs, and that path is "nobody looked" rather than "nothing found".
    with_source(dir, "app/models/user.rb", "class User < ActiveRecord::Base\nend\n")
    payload = plan(changes: [change(subject: "alias_attribute", kind: "default_changed",
      source: "7.2", replacement: nil,
      note: "it reads the column directly")])

    record = step(dir, corpus: FakeCorpus.new(payload: payload)).run

    assert record.passed?, record.why
    assert_equal 1, record.decisions.size, "the plan's own change is not in the record"
    decision = record.decisions.first
    assert_equal "alias_attribute", decision.subject
    assert_equal "default_changed", decision.kind
    assert_equal "7.2", decision.source
    assert_includes decision.reason, "reads the column directly"
    assert_nil decision.path, "a call site was invented for a name the application never uses"
    # **The survey is the answer, and it is the answer even when it found nothing.**
    assert decision.checked?, "a surveyed change with no call site is checked, not owed: #{decision.inspect}"
    assert_includes decision.reason, "none found"
    assert_includes decision.reason, "nothing to edit here"
    refute_includes decision.reason, "not automated yet:",
      "a gap sentence over a change this application does not use reads as skipped work"
    assert_includes record.to_s, "1 change(s) this rung carries (0 located, 0 carried, 1 not used here)"
  end

  # **And a change nobody has surveyed keeps its gap.** The sentence above is a claim that the
  # *tree* was read; without a survey there is nothing to base it on, and the record says which
  # mechanism is missing rather than calling the change unused. `schema.rb column order` has a gap
  # and no reader, which is exactly the shape.
  def test_a_change_with_no_call_site_and_no_survey_keeps_its_gap
    payload = plan(changes: [change(subject: "schema.rb column order", kind: "default_changed",
      source: "7.0", replacement: nil, note: "the dump's order changes")])

    decision = step(track(app), corpus: FakeCorpus.new(payload: payload)).run.decisions.first

    refute decision.checked?, "nobody read this tree, so the record cannot say the change is unused"
    assert_includes decision.reason, "not automated yet:"
    assert_includes decision.reason, "informational"
  end

  # And where the scan *did* find it, the decision points at the line, because that is
  # what makes it actionable. The reason joins the two notes rather than picking one.
  def test_a_decision_the_scan_located_carries_the_path_and_the_line
    dir = track(app)
    with_source(dir, "app/controllers/posts_controller.rb", "class PostsController\nend\n")
    located = { "path" => "app/controllers/posts_controller.rb", "line" => 7,
                "subject" => "before_filter", "kind" => "renamed", "source" => "5.0",
                "note" => "found here as `before_filter :set_post`", "automatic" => false }
    corpus = FakeCorpus.new(payload: plan(changes: [change]), manual: [located])

    record = step(dir, corpus: corpus).run

    decision = record.decisions.first
    assert_equal "app/controllers/posts_controller.rb", decision.path
    assert_equal 7, decision.line
    assert_includes decision.reason, "renamed in Rails 5.0"
    assert_includes decision.reason, "found here as"
    assert_equal 1, record.decisions.size, "the located change was counted twice"
  end

  # **A rule makes the edit the service would not.** The scan locates the call site and stops —
  # its contract is a statement about the *ladder* — and this tool's own rules (`Rewrites`) apply
  # to what it located, through the same line-checked write as the service's own edits. A change a
  # rule applies stops being a decision, because it is no longer one, and the record says which
  # rules did the work.
  def test_a_rule_applies_a_located_change_and_withdraws_its_decision
    dir = track(app)
    with_source(dir, "app/controllers/posts_controller.rb",
      "class PostsController\n  def create\n    type = request.content_type\n  end\nend\n")
    located = { "path" => "app/controllers/posts_controller.rb", "line" => 3,
                "text" => "    type = request.content_type", "after" => nil,
                "subject" => "request.content_type", "kind" => "default_changed",
                "replacement" => "request.media_type", "source" => "6.0",
                "note" => "media_type is the old value", "automatic" => false }
    payload = plan(changes: [change(subject: "request.content_type", kind: "default_changed",
      source: "6.0", replacement: "request.media_type", note: "media_type is the old value")])
    corpus = FakeCorpus.new(payload: payload, manual: [located])

    # The real applier: the write is half of what is being asserted, and the fake one is a stub
    # that never touches a file.
    record = step(dir, corpus: corpus, applier: Agents::Upgrader::Applier).run

    assert record.passed?, record.why
    applied = record.stages.find { |stage| stage.stage == "apply" }
    assert_includes applied.output_tail, "by this tool's own rules (request.content_type)"
    assert_equal 1, record.applied.size, "the rule's edit is not in the record"
    assert_equal "request.content_type", record.applied.first.subject
    assert_equal "rule", record.applied.first.origin
    assert_equal "media_type is the old value", record.applied.first.note,
      "the change's own note travels with the edit, because the decision it withdrew carried it"
    assert_empty record.decisions, "a change a rule applied is not a decision any more"
    assert_includes File.read(File.join(dir, "app/controllers/posts_controller.rb")),
      "type = request.media_type"
    assert_includes record.to_s, "1 of those edit(s) were made by this tool's own rules"
  end

  # **A rule's edit may depend on a file, and the file is created for it.** `class Item <
  # ActiveRecord::Base` cannot become `class Item < ApplicationRecord` before `ApplicationRecord`
  # exists, so the rule carries the definition and the step writes it — after the edits and before the
  # suite, so the suite is judging the move rather than a missing constant. The apply stage names the
  # file, because a reader of the patch has to know the diff is not the whole change.
  def test_a_rule_that_needs_a_file_has_it_created_before_the_suite_runs
    dir = track(app)
    with_source(dir, "app/models/item.rb", "class Item < ActiveRecord::Base\nend\n")
    located = { "path" => "app/models/item.rb", "line" => 1,
                "text" => "class Item < ActiveRecord::Base", "after" => nil,
                "subject" => "ActiveRecord::Base as a model's superclass", "kind" => "moved",
                "replacement" => "ApplicationRecord", "source" => "5.0",
                "note" => "the definition itself is the one ActiveRecord::Base that stays",
                "automatic" => false }
    payload = plan(changes: [change(subject: "ActiveRecord::Base as a model's superclass",
      kind: "moved", source: "5.0", replacement: "ApplicationRecord")])
    corpus = FakeCorpus.new(payload: payload, manual: [located])

    record = step(dir, corpus: corpus, applier: Agents::Upgrader::Applier).run

    assert record.passed?, record.why
    definition = File.join(dir, "app/models/application_record.rb")
    assert File.file?(definition), "the class the renamed superclass names was not created"
    assert_includes File.read(definition), "self.abstract_class = true"
    assert_includes File.read(File.join(dir, "app/models/item.rb")),
      "class Item < ApplicationRecord"
    applied = record.stages.find { |stage| stage.stage == "apply" }
    assert_includes applied.output_tail,
      "1 file(s) created for a rule (app/models/application_record.rb)"
  end

  # An application that has already made the move keeps its own definition: the file it wrote may have
  # anything in it, and overwriting it would be this tool editing a file nobody asked it to.
  def test_a_scaffold_leaves_a_file_the_application_already_has
    dir = track(app)
    with_source(dir, "app/models/item.rb", "class Item < ActiveRecord::Base\nend\n")
    ours = "class ApplicationRecord < ActiveRecord::Base\n  self.abstract_class = true\n  # ours\nend\n"
    with_source(dir, "app/models/application_record.rb", ours)
    located = { "path" => "app/models/item.rb", "line" => 1,
                "text" => "class Item < ActiveRecord::Base", "after" => nil,
                "subject" => "ActiveRecord::Base as a model's superclass", "kind" => "moved",
                "replacement" => "ApplicationRecord", "source" => "5.0", "note" => "",
                "automatic" => false }
    payload = plan(changes: [change(subject: "ActiveRecord::Base as a model's superclass",
      kind: "moved", source: "5.0", replacement: "ApplicationRecord")])
    corpus = FakeCorpus.new(payload: payload, manual: [located])

    record = step(dir, corpus: corpus, applier: Agents::Upgrader::Applier).run

    assert record.passed?, record.why
    assert_equal ours, File.read(File.join(dir, "app/models/application_record.rb"))
    applied = record.stages.find { |stage| stage.stage == "apply" }
    refute_includes applied.output_tail, "file(s) created for a rule"
  end

  # **A change whose fix is a gem, and where the line goes.** `assigns` and `assert_template` moved into
  # `rails-controller-testing`; the call sites need no edit, so what handles them is a declaration —
  # and it goes inside the block that names the test group, because a controller-testing helper
  # declared at the top level is installed in production. The declaration lands in the record as the
  # same `Preflight::Repair` a digest move does, and the change stops being a decision.
  def test_a_bridge_declares_the_gem_in_its_group_and_withdraws_the_decision
    dir = track(app(gemfile: <<~GEM))
      source "https://rubygems.org"
      gem "rails", "4.2.11"

      group :test do
        gem "rspec-rails"
      end
    GEM
    with_source(dir, "spec/controllers/posts_controller_spec.rb",
      "describe PostsController do\n  it { expect(assigns(:post)).to be_a(Post) }\nend\n")
    located = { "path" => "spec/controllers/posts_controller_spec.rb", "line" => 2,
                "text" => "  it { expect(assigns(:post)).to be_a(Post) }", "after" => nil,
                "subject" => "assigns / assert_template", "kind" => "moved",
                "replacement" => "the rails-controller-testing gem", "source" => "5.0",
                "note" => "the helpers moved out of Rails", "automatic" => false }
    payload = plan(changes: [change(subject: "assigns / assert_template", kind: "moved",
      source: "5.0", replacement: "the rails-controller-testing gem")])
    corpus = FakeCorpus.new(payload: payload, manual: [located])

    record = step(dir, corpus: corpus, applier: Agents::Upgrader::Applier).run

    assert record.passed?, record.why
    gemfile = File.read(File.join(dir, "Gemfile"))
    assert_match(/group :test do\n.*^  gem 'rails-controller-testing'$\nend/m, gemfile,
      "the declaration did not land indented inside the block that names the test group")
    assert_empty record.decisions, "the gem handles every one of the change's call sites"
    applied = record.stages.find { |stage| stage.stage == "apply" }
    assert_includes applied.output_tail,
      "1 gem(s) declared for a change (assigns / assert_template)"
    assert_equal 1, record.applied.size
    assert_equal "Gemfile", record.applied.first.path
    assert_includes record.applied.first.after, "rails-controller-testing"
  end

  # **The suite is scanned even when the project's declaration does not name it.** A project
  # connected before detection read `spec`/`test` carries `app lib config`, and the 5.0 bridge's only
  # call sites are in `spec/` — measured on the first real walk, where the declaration was not a
  # statement that tests may not be read but a row written before a rule read them, and the eleven
  # controller specs failed on `assigns has been extracted to a gem`.
  def test_the_suite_is_scanned_when_the_declaration_predates_the_rule
    dir = track(app)
    with_source(dir, "spec/controllers/posts_controller_spec.rb",
      "describe PostsController do\n  it { expect(assigns(:post)).to be_a(Post) }\nend\n")
    project = Agents::Upgrader::Project.new(
      { "slug" => "storefront", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0",
        "source_roots" => %w[app lib config] }
    )
    corpus = FakeCorpus.new(payload: plan)

    step(dir, corpus: corpus, project: project).run

    assert_includes corpus.asked_files.flatten, "spec/controllers/posts_controller_spec.rb",
      "the bridge's call sites were in a directory the declaration did not name, so none was sent"
  end

  # **The one refusal here.** A test-only gem appended to the end of the file is installed in
  # production, and that is a fact about the deployment rather than about the line — so a Gemfile with
  # no block for the gem's group keeps the change as a decision.
  def test_a_bridge_leaves_the_decision_when_the_gemfile_has_no_block_for_its_group
    dir = track(app(gemfile: %(source "https://rubygems.org"\ngem "rails", "4.2.11"\n)))
    with_source(dir, "spec/controllers/posts_controller_spec.rb",
      "describe PostsController do\n  it { expect(assigns(:post)).to be_a(Post) }\nend\n")
    located = { "path" => "spec/controllers/posts_controller_spec.rb", "line" => 2,
                "text" => "  it { expect(assigns(:post)).to be_a(Post) }", "after" => nil,
                "subject" => "assigns / assert_template", "kind" => "moved",
                "replacement" => "the rails-controller-testing gem", "source" => "5.0",
                "note" => "the helpers moved out of Rails", "automatic" => false }
    payload = plan(changes: [change(subject: "assigns / assert_template", kind: "moved",
      source: "5.0", replacement: "the rails-controller-testing gem")])
    corpus = FakeCorpus.new(payload: payload, manual: [located])

    record = step(dir, corpus: corpus, applier: Agents::Upgrader::Applier).run

    refute_includes File.read(File.join(dir, "Gemfile")), "rails-controller-testing"
    assert_equal ["assigns / assert_template"], record.decisions.map(&:subject)
    assert_includes record.decisions.first.reason, "installed in production"
  end

  # An application that already declared the gem is *handled* without an edit: the change is satisfied
  # whether this step declared it or the application did, and re-declaring it would be editing a
  # Gemfile for no reason.
  def test_a_bridge_counts_a_gem_the_application_already_declared_as_handled
    dir = track(app(gemfile: <<~GEM))
      source "https://rubygems.org"
      gem "rails", "4.2.11"
      gem "rails-controller-testing"
    GEM
    with_source(dir, "spec/controllers/posts_controller_spec.rb",
      "describe PostsController do\n  it { expect(assigns(:post)).to be_a(Post) }\nend\n")
    located = { "path" => "spec/controllers/posts_controller_spec.rb", "line" => 2,
                "text" => "  it { expect(assigns(:post)).to be_a(Post) }", "after" => nil,
                "subject" => "assigns / assert_template", "kind" => "moved",
                "replacement" => "the rails-controller-testing gem", "source" => "5.0",
                "note" => "the helpers moved out of Rails", "automatic" => false }
    payload = plan(changes: [change(subject: "assigns / assert_template", kind: "moved",
      source: "5.0", replacement: "the rails-controller-testing gem")])
    corpus = FakeCorpus.new(payload: payload, manual: [located])

    record = step(dir, corpus: corpus, applier: Agents::Upgrader::Applier).run

    assert_empty record.decisions
    assert_empty record.applied, "the gem was already declared, so there was nothing to write"
  end

  # **A bridge whose evidence is the rung.** `bootsnap`'s evidence does not exist at apply time —
  # `app:update` writes `require "bootsnap/setup"` into `config/boot.rb` *after* the install — so the
  # rung is what the declaration rests on, and the pin's `bundle update` is the install that follows it.
  # Nothing is located: the change has no pattern for the scan to find, which is why the scan's list
  # cannot be the gate for every bridge.
  def test_a_bridge_whose_evidence_is_the_rung_declares_the_gem_with_nothing_located
    dir = track(app)
    with_source(dir, "config/boot.rb", %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)\n))
    payload = plan(changes: [change(subject: "bootsnap", kind: "moved", source: "5.2",
      replacement: nil, note: "app:update writes Bootsnap into config/boot.rb")])
    corpus = FakeCorpus.new(payload: payload)

    record = step(dir, corpus: corpus, applier: Agents::Upgrader::Applier).run

    assert record.passed?, record.why
    assert_includes File.read(File.join(dir, "Gemfile")), "gem 'bootsnap'"
    assert_empty record.decisions, "the declaration is the change's whole fix"
    applied = record.stages.find { |stage| stage.stage == "apply" }
    assert_includes applied.output_tail, "1 gem(s) declared for a change (bootsnap)"
  end

  # **A bridge whose evidence is a file the application owns.** `config/application.rb` asking for
  # `sprockets/railtie` is what says this application still uses the asset pipeline, and Rails 7 no
  # longer depends on the gem. The evidence is matched against the file's own bytes rather than a masked
  # line, because what is being looked for is *inside a string* — which is what the mask blanks. An
  # application that has dropped the line keeps the change as a decision.
  def test_a_bridge_whose_evidence_is_the_tree_reads_it_and_leaves_an_application_without_it
    payload = plan(changes: [change(subject: "sprockets-rails", kind: "moved", source: "7.0",
      replacement: nil, note: "Rails 7 does not depend on it")])

    uses_pipeline = track(app)
    with_source(uses_pipeline, "config/application.rb", %(require "rails"\nrequire "sprockets/railtie"\n))
    record = step(uses_pipeline, corpus: FakeCorpus.new(payload: payload),
      applier: Agents::Upgrader::Applier).run
    assert_includes File.read(File.join(uses_pipeline, "Gemfile")), "gem 'sprockets-rails'"

    plain = track(app)
    with_source(plain, "config/application.rb", %(require "rails"\n))
    record = step(plain, corpus: FakeCorpus.new(payload: payload),
      applier: Agents::Upgrader::Applier).run
    refute_includes File.read(File.join(plain, "Gemfile")), "sprockets-rails"
    assert_equal ["sprockets-rails"], record.decisions.map(&:subject)
  end

  # **The survey's evidence travels in the decision**, which is where a person reads it. `default_scope`
  # is the case the survey mechanism was built for: the edit is a judgement — `unscope`, `rewhere` and
  # `unscoped` are three different intentions — and the *evidence* is a fact about the tree. So the
  # residue names the lines rather than saying "needs a person" and stopping.
  def test_a_survey_puts_the_lines_that_read_differently_into_the_decision
    dir = track(app)
    with_source(dir, "app/models/item.rb",
      "class Item < ApplicationRecord\n  default_scope { where(active: true) }\nend\n")
    with_source(dir, "app/controllers/items_controller.rb",
      "class ItemsController\n  def index\n    @items = Item.where(active: false)\n  end\nend\n")
    located = { "path" => "app/models/item.rb", "line" => 2,
                "text" => "  default_scope { where(active: true) }", "after" => nil,
                "subject" => "default_scope", "kind" => "changed",
                "replacement" => nil, "source" => "4.1", "note" => "merged rather than overridden",
                "automatic" => false }
    payload = plan(changes: [change(subject: "default_scope", kind: "changed", source: "4.1",
      replacement: nil, note: "merged rather than overridden")])

    record = step(dir, corpus: FakeCorpus.new(payload: payload, manual: [located]),
      applier: Agents::Upgrader::Applier).run

    decision = record.decisions.find { |candidate| candidate.subject == "default_scope" }
    refute_nil decision, "nothing edits a default scope, so it is still a decision"
    assert_includes decision.reason, "this application: the callers that chain a condition on the same"
    assert_includes decision.reason, "app/controllers/items_controller.rb:3"
    assert_includes decision.reason, "Item.where(active: false)"
    refute_includes decision.reason, "app/models/item.rb:2",
      "the declaration is not a caller of itself"
  end

  # And an application with no such caller says so — the sentence a person needs in order to know the
  # question was asked, which is the difference between "none found" and "nobody looked".
  def test_a_survey_that_finds_nothing_says_the_question_was_asked
    dir = track(app)
    with_source(dir, "app/models/item.rb",
      "class Item < ApplicationRecord\n  default_scope { where(active: true) }\nend\n")
    located = { "path" => "app/models/item.rb", "line" => 2,
                "text" => "  default_scope { where(active: true) }", "after" => nil,
                "subject" => "default_scope", "kind" => "changed",
                "replacement" => nil, "source" => "4.1", "note" => "merged rather than overridden",
                "automatic" => false }
    payload = plan(changes: [change(subject: "default_scope", kind: "changed", source: "4.1",
      replacement: nil, note: "merged rather than overridden")])

    record = step(dir, corpus: FakeCorpus.new(payload: payload, manual: [located]),
      applier: Agents::Upgrader::Applier).run

    decision = record.decisions.find { |candidate| candidate.subject == "default_scope" }
    assert_includes decision.reason, "this application: the callers that chain a condition"
    assert_includes decision.reason, "none found"
  end

  # **A floor is a bridge whose work is a version rather than a presence.** "Spring 3.0.0 or newer" is
  # the change's own words, and an older Spring raises `undefined method 'mechanism='` before the
  # application boots — which reads as an application error rather than as a stale development
  # dependency. Three cases, because the interesting one is the third: a Gemfile that already names a
  # version is a person's call, and calling it handled would be the settled-work trap with the sign
  # flipped.
  def test_a_floor_bridge_rewrites_a_declaration_that_asks_for_no_version
    payload = plan(changes: [change(subject: "Spring", kind: "moved", source: "7.0",
      replacement: "Spring 3.0.0 or newer", note: "an older Spring raises before the app boots")])

    plain = track(app(gemfile: %(source "https://rubygems.org"\ngem "rails", "4.2.11"\ngem "spring"\n)))
    with_source(plain, "app/models/item.rb", "class Item\nend\n")
    record = step(plain, corpus: FakeCorpus.new(payload: payload), applier: Agents::Upgrader::Applier).run
    assert_includes File.read(File.join(plain, "Gemfile")), %(gem "spring", ">= 3.0.0")
    assert_empty record.decisions, "the declaration is the change's whole fix"

    # A declaration that already asks for a version is left, and the change stays a decision.
    pinned = track(app(gemfile: %(source "https://rubygems.org"\ngem "rails", "4.2.11"\ngem "spring", "~> 2.0"\n)))
    with_source(pinned, "app/models/item.rb", "class Item\nend\n")
    record = step(pinned, corpus: FakeCorpus.new(payload: payload), applier: Agents::Upgrader::Applier).run
    assert_includes File.read(File.join(pinned, "Gemfile")), %(gem "spring", "~> 2.0")
    assert_equal ["Spring"], record.decisions.map(&:subject)

    # And an application that does not use Spring is not asked to install it.
    absent = track(app)
    with_source(absent, "app/models/item.rb", "class Item\nend\n")
    record = step(absent, corpus: FakeCorpus.new(payload: payload), applier: Agents::Upgrader::Applier).run
    refute_includes File.read(File.join(absent, "Gemfile")), "spring"
    assert_empty record.decisions, "a change about a gem the application does not have is not its work"
  end

  # **A line a rule knows and will not touch is a reason before it is a count.** `belongs_to` is the case:
  # the rule adds `optional: true` where the model does *not* already validate the association, and a
  # model that does validate it needs nothing — so the count alone would read as work left when it is
  # work already done. The sentence is the rule's `PARTIAL`, and a `left` line produces no *decision*, so
  # without this the record would be the one place the explanation cannot be found.
  def test_the_apply_tail_says_why_a_rule_would_not_touch_a_line
    dir = track(app)
    with_source(dir, "app/models/bid.rb",
      "class Bid < ApplicationRecord\n  belongs_to :item\n  validates_presence_of :item\nend\n")
    located = { "path" => "app/models/bid.rb", "line" => 2, "text" => "  belongs_to :item",
                "after" => nil, "subject" => "belongs_to", "kind" => "default_changed",
                "replacement" => nil, "source" => "5.0", "note" => "required by default now",
                "automatic" => false }
    payload = plan(changes: [change(subject: "belongs_to", kind: "default_changed", source: "5.0",
      replacement: nil, note: "required by default now")])

    record = step(dir, corpus: FakeCorpus.new(payload: payload, manual: [located]),
      applier: Agents::Upgrader::Applier).run

    tail = record.stages.find { |stage| stage.stage == "apply" }.output_tail
    assert_includes tail, "1 line(s) a rule knows and would not touch (belongs_to)"
    assert_includes tail, "already validate"
    assert_includes File.read(File.join(dir, "app/models/bid.rb")), "belongs_to :item\n",
      "the line the model already requires is not written to"
  end

  # **The step reads the file a rule names for itself**, which is the half a pure test cannot drive: a rule
  # that finds its own call sites is useless if the walker never reads the file it named. This is the shape
  # of every change whose fix is not in Ruby — `package.json` is the first, and the mechanism is the point
  # rather than the package.
  def test_the_step_reads_the_file_a_rule_names_for_itself
    dir = track(app)
    with_source(dir, "app/models/item.rb", "class Item\nend\n")
    with_source(dir, "package.json", %({\n  "dependencies": {\n    "actioncable": "^5.2.0"\n  }\n}\n))
    payload = plan(changes: [change(subject: "@rails npm packages", kind: "renamed", source: "6.0",
      replacement: nil, note: "the npm packages moved under the @rails scope")])

    record = step(dir, corpus: FakeCorpus.new(payload: payload), applier: Agents::Upgrader::Applier).run

    assert record.passed?, record.why
    assert_includes File.read(File.join(dir, "package.json")), "\"@rails/actioncable\""
    assert_empty record.decisions, "the rule applied, so the change is not a decision"
    tail = record.stages.find { |stage| stage.stage == "apply" }.output_tail
    assert_includes tail, "by this tool's own rules (@rails npm packages)"
  end

  # **A generator runs in the application's own default environment.** Everything else in the pipeline runs
  # in `test` — the suite is a test suite and the database it prepares is the test one — and that was right
  # for every stage until this one. A real walk showed why it is wrong there: `rails:update` loaded
  # `shoulda-matchers 2.1.0` out of the application's *test* group, and that gem cannot load under the
  # minitest 5 the release brought, so a task about config files failed on a test gem. Nothing about
  # `app:update` is test-specific; a person runs it in development, which is what this does.
  def test_the_update_task_runs_in_the_applications_own_environment_and_not_the_test_one
    dir = track(app)
    with_source(dir, "app/models/item.rb", "class Item\nend\n")
    runner = FakeRunner.new

    step(dir, corpus: FakeCorpus.new(payload: plan), runner: runner,
      applier: Agents::Upgrader::Applier).run

    update = runner.envs.find { |command, _env| command.include?("rails:update") }
    refute_nil update, "the update task ran, so this proves something"
    assert_equal "development", update.last["RAILS_ENV"]
    assert_equal "development", update.last["RACK_ENV"]

    # **And the stage that must stay in `test` does**, which is the half a change like this can quietly
    # take with it: the boot that runs before the suite boots the application the suite's way.
    boot = runner.envs.find { |command, _env| command.include?("Rails.version") }
    refute_nil boot
    assert_equal "test", boot.last["RAILS_ENV"]

    # **Every command is bounded**, and the knob moves the bound. Nothing bounded them before: the suite had
    # its own, the corpus client had one for HTTP, and a `bundle update` whose container could not reach
    # rubygems hung until somebody noticed.
    assert_equal [Agents::Upgrader::Shell::DEFAULT_COMMAND_TIMEOUT] * runner.timeouts.size,
      runner.timeouts.map(&:last), "each command carries the default bound"

    bound = FakeRunner.new
    step(dir, corpus: FakeCorpus.new(payload: plan), runner: bound,
      applier: Agents::Upgrader::Applier, env: { "UPGRADER_COMMAND_TIMEOUT" => "42" }).run
    assert_equal [42] * bound.timeouts.size, bound.timeouts.map(&:last)

    # **The update task is given the answer, and nothing else is.** `app:update` stops on every file the
    # application owns and asks whether to overwrite it; the walker's rule is that an application-owned file
    # keeps the application's version, so the answer is `n` for every question — and a walk that left it to a
    # prompt was killed at its bound with `Overwrite config/boot.rb?` on screen.
    asked = runner.stdins.find { |command, _| command.include?("rails:update") }
    refute_nil asked, "the update task ran"
    assert_equal "n\n" * Agents::Upgrader::Step::OVERWRITE_ANSWERS, asked.last
    install = runner.stdins.find { |command, _| command.include?("bundle install") }
    assert_equal File::NULL, install.last, "every other command reads nothing, and gets EOF if it tries"
  end

  # **`app:update` can write a migration, and the database the baseline prepared is then stale.**
  # Measured at the 6.0 rung: `app:update` adds
  # `db/migrate/*_add_foreign_key_constraint_to_active_storage_attachments_for_blob_id.rb` — the
  # generated migration is guarded and therefore a no-op, but it is a *migration* — and the
  # application's own `spec_helper` calls `ActiveRecord::Migration.check_pending!`, so the suite died
  # before a single example ran: "Migrations are pending. To resolve this issue, run: rails db:migrate
  # RAILS_ENV=test". `db:test:prepare` is not the command for it (that loads `db/schema.rb`, which only
  # `db:migrate` has brought up to date), so the second preparation is the one Rails' own message names
  # — and it must run *only* when a migration arrived, because it touches the database the suite reads.
  def test_a_migration_from_the_update_task_is_applied_before_the_suite
    dir = track(app)
    with_source(dir, "config/database.yml", "test:\n  adapter: sqlite3\n  database: db/test.sqlite3\n")
    # The dump is here, and committed, so the *first* preparation is `db:test:prepare`; without one
    # the fixture is a tree that has to be migrated, and `db:migrate` in `calls` would be the
    # baseline's.
    with_source(dir, "db/schema.rb", "ActiveRecord::Schema.define\n")
    commit(dir, "schema")
    runner = MigratingRunner.new(dir, path: "db/migrate/20261018221457_add_foreign_key_constraint.rb")

    record = step(dir, corpus: FakeCorpus.new(payload: plan), runner: runner).run

    migrate = runner.calls.index { |command| command.include?("db:migrate") }
    refute_nil migrate, "the migration app:update wrote was never applied: #{runner.calls.inspect}"
    update = runner.calls.index { |command| command.match?(/app:update|rails:update/) }
    assert_operator update, :<, migrate, "the migration was applied before app:update wrote it"
    assert_operator migrate, :<, runner.calls.index { |command| command.include?("Rails.version") },
      "the migration was applied after the boot that precedes the suite"
    stage = record.stages.find { |each| each.stage == "database" && each.command.include?("db:migrate") }
    refute_nil stage, "the second preparation is not in the record"
    assert_includes stage.output_tail, "db/migrate/",
      "the record does not say what made the second preparation necessary"

    # And a rung whose `app:update` wrote no migration prepares nothing a second time.
    plain = track(app)
    with_source(plain, "config/database.yml", "test:\n  adapter: sqlite3\n  database: db/test.sqlite3\n")
    with_source(plain, "db/schema.rb", "ActiveRecord::Schema.define\n")
    commit(plain, "schema")
    quiet = FakeRunner.new
    step(plain, corpus: FakeCorpus.new(payload: plan), runner: quiet).run

    assert(quiet.calls.none? { |command| command.include?("db:migrate") },
      "a second preparation ran for a rung that changed no migration: #{quiet.calls.inspect}")
  end

  # **A migration `app:update` copies for an engine the application does not have is not kept.**
  # Measured at the 6.1 rung: `app:update` ran `active_storage:update`, which copied two
  # `.active_storage.rb` migrations into a 2013 application whose `db/schema.rb` mentions
  # `active_storage` zero times, and the step's own `db:migrate` died on
  # `PG::UndefinedTable: ERROR: relation "active_storage_blobs" does not exist` — after which the
  # suite aborted on `ActiveRecord::Migration.check_pending!` before an example ran. Rails' engines
  # name their migrations with their own suffix, so the test is mechanical: an addition under
  # `db/migrate/` whose engine suffix names an engine with no table in the schema is a migration for
  # a component this application does not use, and it is removed with the reason recorded.
  def test_an_engine_migration_the_application_has_no_tables_for_is_not_kept
    dir = track(app)
    with_source(dir, "config/database.yml", "test:\n  adapter: sqlite3\n  database: db/test.sqlite3\n")
    with_source(dir, "db/schema.rb",
      "ActiveRecord::Schema.define(version: 1) do\n  create_table \"bids\" do |t|\n  end\nend\n")
    path = "db/migrate/20261018235537_add_service_name_to_active_storage_blobs.active_storage.rb"
    runner = MigratingRunner.new(dir, path: path)

    record = step(dir, corpus: FakeCorpus.new(payload: plan), runner: runner).run

    refute File.exist?(File.join(dir, path)),
      "a migration for a component this application does not have was kept"
    edit = record.applied.find { |each| each.subject.to_s.include?("active_storage") }
    refute_nil edit, "the removal was not recorded as an edit: #{record.applied.map(&:subject).inspect}"
    assert_includes edit.note, "no `active_storage_*` table"
    assert_includes edit.note, "active_storage:install",
      "the note has to say what to do next"
    assert_empty record.decisions.select { |each| each.subject.to_s.include?("active_storage") },
      "a removal the tool made is not work for a person"
    refute_includes runner.calls.join("\n"), "db:migrate",
      "the second preparation ran for a migration that was not kept: #{runner.calls.inspect}"
  end

  # **A boot that cannot load a gem the pin stopped providing is repaired by declaring it.** The
  # evidence is both halves of the tree: the require the boot named, and the version the base
  # commit's lockfile carried. A report is filed through the same `Outcome` as a suite repair, so
  # the corpus learns the shape rather than this walk deriving it again.
  def test_a_boot_that_cannot_load_a_gem_the_pin_stopped_providing_declares_it_and_boots_again
    dir = track(app(lockfile: LOCKFILE_WITH_ATTR_ENCRYPTED))
    runner = DroppingGemRunner.new(dir, require_name: "attr_encrypted")

    record = step(dir, corpus: FakeCorpus.new(payload: plan), runner: runner).run

    assert record.passed?, record.why
    assert_includes File.read(File.join(dir, "Gemfile")), "gem \"attr_encrypted\", \"4.2.0\""
    assert_equal 2, runner.boots, "the boot was not asked again after the declaration"
    repair = record.stages.find { |stage| stage.command.to_s.include?("boot repair") }
    refute_nil repair, "the record does not say the boot was repaired"
    assert_includes repair.output_tail, "attr_encrypted 4.2.0"

    outcome = record.repairs.find { |each| each.gate.to_s == "the boot" }
    refute_nil outcome, "the boot repair is not in the record's repairs: #{record.repairs.inspect}"
    payload = Agents::Upgrader::Filing.repair_report_for(record: record, outcome: outcome)
    refute_nil payload
    assert_includes payload["resolution"], "the boot was green after it"
  end

  # And the other side of the same rule: an application that *has* the engine's tables keeps the
  # migration and applies it, because that is what the migration is for.
  def test_an_engine_migration_is_kept_when_the_application_has_the_tables
    dir = track(app)
    with_source(dir, "config/database.yml", "test:\n  adapter: sqlite3\n  database: db/test.sqlite3\n")
    with_source(dir, "db/schema.rb",
      "ActiveRecord::Schema.define(version: 1) do\n  create_table \"active_storage_blobs\" do |t|\n  end\nend\n")
    path = "db/migrate/20261018235537_add_service_name_to_active_storage_blobs.active_storage.rb"
    runner = MigratingRunner.new(dir, path: path)

    step(dir, corpus: FakeCorpus.new(payload: plan), runner: runner).run

    assert File.exist?(File.join(dir, path)),
      "a migration for a component this application has was removed"
    assert_includes runner.calls.join("\n"), "db:migrate",
      "the migration was kept and never applied: #{runner.calls.inspect}"
  end

  # **The scan looks below the rung, because an application can be behind the release it declares.** The
  # lighthouse says 4.0.0.rc1 and still calls `find(:all, conditions: ...)` — a change the ladder documents
  # for the rung that *arrives at* 4.0, which kept working until 4.1 because Rails 4.0 depended on
  # `activerecord-deprecated_finders`. The step never asked about that rung, so the suite failed on a change
  # the residue said nothing about. Three things have to hold, and each is driven here: the window starts at
  # the ladder's bottom, an entry from an earlier rung says so, and a ladder this client cannot read falls
  # back to the rung's own window rather than refusing the move.
  def test_the_scan_looks_below_the_rung_and_says_which_rung_a_call_site_came_from
    dir = track(app)
    with_source(dir, "app/models/category.rb",
      "class Category < ActiveRecord::Base\n  def tech\n    find(:all, conditions: {url: \"x\"}, order: \"name\")\n  end\nend\n")
    earlier = { "path" => "app/models/category.rb", "line" => 3,
                "text" => "    find(:all, conditions: {url: \"x\"}, order: \"name\")", "after" => nil,
                "step" => "4.0.0", "subject" => "find(:all, ...)", "kind" => "removed",
                "replacement" => "where(...)", "note" => "the old hash-based finder options are gone",
                "automatic" => false }
    corpus = FakeCorpus.new(payload: plan, manual: [earlier], earliest: "3.2.0")

    record = step(dir, corpus: corpus, applier: Agents::Upgrader::Applier).run

    assert_equal [["3.2.0", "5.0.0"]], corpus.asked_scans,
      "the window starts at the ladder's bottom rather than at the application's version"
    decision = record.decisions.find { |candidate| candidate.subject == "find(:all, ...)" }
    assert_includes decision.reason, "carried by an earlier rung"
    assert_includes decision.reason, "the one that arrives at 4.0.0"

    # And a ladder the client cannot read is the rung's window, not a refusal.
    plain = track(app)
    with_source(plain, "app/models/item.rb", "class Item < ActiveRecord::Base\nend\n")
    unreadable = FakeCorpus.new(payload: plan, earliest: "3.2.0",
      ladder_error: Agents::Upgrader::Corpus::Refused.new("no ladder"))
    step(plain, corpus: unreadable, applier: Agents::Upgrader::Applier).run
    assert_equal [["4.2.11", "5.0.0"]], unreadable.asked_scans
  end

  # **A change the application has already made is not a decision, and a line the rule cannot read still is.**
  # The first real walk's three located entries were `:confirm option on link_to` lines that already carry
  # `data: { confirm: … }` — the ladder's detect is `confirm:`, which matches the new form too — and the
  # residue said three decisions were owed. A rule's own idempotence guard is the reader that can tell the
  # difference, so it is asked twice: once to stop the edit, once to stop the decision. The other direction
  # matters as much: a line whose value the rule cannot see the end of is still a person's to read.
  def test_a_line_the_application_already_migrated_is_not_a_decision
    migrated = "<%= link_to 'Delete', post, method: :delete, data: { confirm: 'Are you sure?' } %>"
    unreadable = "<%= link_to 'Delete', post, confirm: t(:x, count: 1) %>"
    payload = plan(changes: [change(subject: ":confirm option on link_to", kind: "renamed", source: "4.0",
      replacement: "data: { confirm: … }", note: "the confirm option becomes a data attribute")])

    already = track(app)
    with_source(already, "app/views/posts/index.html.erb", "#{migrated}\n")
    record = step(already, corpus: FakeCorpus.new(payload: payload,
      manual: [entry_for("app/views/posts/index.html.erb", 1, migrated)]),
      applier: Agents::Upgrader::Applier).run

    assert_empty record.decisions, "the line already reads the new way, so nothing is owed"
    tail = record.stages.find { |stage| stage.stage == "apply" }.output_tail
    assert_includes tail, "1 change(s) this application already has (:confirm option on link_to)"

    owed = track(app)
    with_source(owed, "app/views/posts/index.html.erb", "#{unreadable}\n")
    record = step(owed, corpus: FakeCorpus.new(payload: payload,
      manual: [entry_for("app/views/posts/index.html.erb", 1, unreadable)]),
      applier: Agents::Upgrader::Applier).run

    assert_equal [":confirm option on link_to"], record.decisions.map(&:subject),
      "a value the rule cannot see the end of is still a person's to read"
  end

  # **A rule's glob that matched more files than it read is said, not silent.** `SOURCE_LIMIT` bounds how many
  # files one rule's pattern is tried against; a rule that read a slice and found nothing would look exactly
  # like a rule with nothing to find, which is the empty answer this pipeline keeps paying for — in a rule
  # instead of a scan. The bound is not raised here: at that point the rule is reading a tree rather than a
  # file, and the honest thing is to say so and let the rule be narrowed.
  def test_a_rule_glob_that_matched_more_files_than_it_read_says_so
    dir = track(app)
    with_source(dir, "app/models/item.rb", "class Item\nend\n")
    # The JavaScript glob is the only one in the rule table, so it is the one to overflow — and
    # its `filter` means the files have to mention ActionCable to be candidates at all.
    (Agents::Upgrader::Rewrites::SOURCE_LIMIT + 1).times do |index|
      with_source(dir, "app/assets/javascripts/file_#{index}.js", "// ActionCable\n")
    end

    record = step(dir, corpus: FakeCorpus.new(payload: plan), applier: Agents::Upgrader::Applier).run

    tail = record.stages.find { |stage| stage.stage == "apply" }.output_tail
    assert_includes tail, "a rule's file glob was truncated"
    assert_includes tail, "#{Agents::Upgrader::Rewrites::SOURCE_LIMIT + 1} file(s), first " \
      "#{Agents::Upgrader::Rewrites::SOURCE_LIMIT} read"
  end

  def entry_for(path, line, text)
    { "path" => path, "line" => line, "text" => text, "after" => nil,
      "subject" => ":confirm option on link_to", "kind" => "renamed",
      "replacement" => "data: { confirm: … }", "source" => "4.0", "automatic" => false }
  end

  # A manual call site the plan does not name is the most useful thing a refusal can
  # say — a change nobody has written into the ladder — so it is a decision too.
  def test_a_manual_call_site_the_ladder_does_not_name_is_still_a_decision
    dir = track(app)
    with_source(dir, "app/models/post.rb", "class Post\nend\n")
    found = { "path" => "app/models/post.rb", "line" => 3, "subject" => "serialize_with",
              "kind" => "changed", "source" => "7.0", "note" => "the argument moved" }
    corpus = FakeCorpus.new(payload: plan(changes: [change]), manual: [found])

    record = step(dir, corpus: corpus).run

    subjects = record.decisions.map(&:subject)
    assert_equal %w[before_filter serialize_with], subjects.sort
    unplanned = record.decisions.find { |decision| decision.subject == "serialize_with" }
    assert_equal "app/models/post.rb", unplanned.path
  end

  # The scan's counts read as one thing and mean three, and the service writes the
  # sentence that says which — so the client prints it rather than leaving a log where
  # "35 files, 0 lines" looks like a read that did nothing. That line is real: the
  # 7.2 -> 8.0 rung has no pattern to search for at all, so the service returns before
  # reading a line.
  def test_a_scan_that_found_nothing_says_which_kind_of_nothing_it_was
    dir = track(app)
    with_source(dir, "app/models/post.rb", "class Post\nend\n")
    out = StringIO.new

    step(dir, out: out).run

    assert_includes out.string, "scan: nothing to apply here",
      "a scan with nothing in it reported only its counts"
    assert_includes out.string, "no call site"
  end

  # **The application's gate is a list, and a failed check fails the rung even when the suite is
  # green.** The style formatter runs first, because a style commit after the suite would be a change
  # the suite never saw, and its check is the same question asked without writing.
  def test_a_declared_check_and_formatter_run_and_a_failed_check_fails_the_rung
    dir = track(app)
    project = Agents::Upgrader::Project.parse({
      "slug" => "storefront", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0",
      "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" },
      "source_roots" => ["app"],
      "checks" => [{ "id" => "lint", "kind" => "lint",
                     "command" => "ruby -e 'STDERR.puts \"lint says no\"; exit 1'" }],
      "style" => { "format" => "ruby -e 'exit 0'", "check" => "ruby -e 'exit 0'" }
    }.to_json)

    out = StringIO.new
    record = step(dir, project: project, out: out).run

    refute record.passed?, record.why
    assert record.failed?, record.why
    assert_includes record.why, "lint"
    assert_equal %w[lint style], record.checks.map(&:id).sort
    assert_equal "failed", record.checks.find { |check| check.id == "lint" }.status
    assert_equal "passed", record.checks.find { |check| check.id == "style" }.status
    assert record.stages.any? { |stage| stage.stage == "style" },
      "the formatter is a stage, not a commit somebody makes afterwards"
    assert_includes out.string, "lint says no",
      "a failed check's output was not printed as the reason the rung stopped"
  end

  # **A check the base commit already failed is neither this rung's failure nor the formatter's
  # invitation.** Measured on diaspora: 444 offences on a clean `develop`, because its own lint job
  # runs `pronto` over the lines a pull request changes; the walker's formatter then rewrote 40 files
  # with an unsafe correction and one of them broke the boot. The check is asked of the base commit
  # first, the rung carries the result as `preexisting`, and no formatter stage runs.
  def test_a_style_check_the_base_commit_already_fails_is_not_this_rung_s_failure
    dir = track(app)
    project = Agents::Upgrader::Project.parse({
      "slug" => "storefront", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0",
      "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" },
      "style" => { "format" => "ruby -e 'exit 0'",
                   "check" => "ruby -e 'STDERR.puts \"444 offences\"; exit 1'" }
    }.to_json)

    out = StringIO.new
    record = step(dir, project: project, out: out).run

    assert record.passed?, record.why
    style = record.checks.find { |check| check.id == "style" }
    assert_equal "preexisting", style.status
    assert_includes style.reason, "exit 1"
    refute record.stages.any? { |stage| stage.stage == "style" },
      "the formatter rewrote a tree that arrived unformatted"
    base = record.stages.find { |stage| stage.command.to_s.end_with?("(at the base commit)") }
    refute_nil base, "the base commit was not asked the check"
    assert_equal 1, base.exit_code
    assert_includes out.string, "already fails"
  end

  # **A prepare check runs before the baseline, not after the suite.** The application's CI prepares
  # its database and its JavaScript before it tests; a walker that ran the same command afterwards
  # would be preparing a tree the suite had already judged.
  def test_a_prepare_check_runs_before_the_baseline
    dir = track(app)
    project = Agents::Upgrader::Project.parse({
      "slug" => "storefront", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0",
      "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" },
      "checks" => [{ "id" => "prepare", "kind" => "prepare",
                     "command" => "ruby -e 'exit 0'" }]
    }.to_json)

    record = step(dir, project: project).run

    stages = record.stages.map(&:stage)
    assert_operator stages.index("check"), :<, stages.index("baseline"),
      "the prepare check ran after the baseline"
    assert_equal "passed", record.checks.first.status
  end

  # **An external check is recorded, not run and not green.** The rung can still pass on what the
  # walk measured, and the record says the application's CI owns the other answer.
  def test_an_external_check_is_carried_and_does_not_turn_a_green_rung_red
    dir = track(app)
    project = Agents::Upgrader::Project.parse({
      "slug" => "storefront", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0",
      "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" },
      "checks" => [{ "id" => "ci", "kind" => "external",
                     "reason" => "the application's GitHub Actions test job" }]
    }.to_json)

    record = step(dir, project: project).run

    assert record.passed?, record.why
    check = record.checks.first
    assert_equal "external", check.status
    assert check.external?
    assert_includes check.reason, "GitHub Actions"
    refute record.to_h["checks"].first.key?("exit_code")
  end

  # **The branch is a series of concerns, and the patch is still the whole rung.** A reviewer reads
  # the pin commit beside the app:update commit, and the diff they apply is `base..head`.
  def test_the_step_commits_its_concerns_and_the_patch_is_the_whole_move
    dir = track(app)
    project = Agents::Upgrader::Project.parse({
      "slug" => "storefront", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0",
      "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" }
    }.to_json)

    record = step(dir, project: project).run

    assert record.passed?, record.why
    refute_empty record.commits, "the step made no concern commit"
    messages = record.commits.map { |commit| commit["message"] }
    assert_includes messages.join("\n"), "pin Rails and move gems"
    assert_includes record.patch, %(gem "rails", "5.0.0")
    head = record.commits.last["commit"]
    assert_equal head, Agents::Upgrader::Checkpoint.head(dir).first,
      "the last concern commit is the tree's head"
  end

  # **The project's app:update policy is applied after the added-only rule.** A generated file the
  # project does not want is removed, and the record says which policy skipped it — an absent file
  # with no sentence is the shape that reads as a generator that did nothing.
  # **The PR names the decisions that were in force, not every decision the project ever made.**
  # An accepted answer scoped to a later rung is not part of this rung's story; the applied edit's
  # origin is the evidence, and the record carries the question and answer beside it.
  def test_the_record_carries_the_accepted_decisions_whose_effects_applied
    dir = track(app)
    with_source(dir, "app/models/item.rb", "ITEM = 1\n")
    project = Agents::Upgrader::Project.parse({
      "slug" => "storefront", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0",
      "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" },
      "decisions" => [{
        "id" => "d1", "question" => "Use the new constant?", "answer" => "yes",
        "accepted_by" => "operator:9f2c",
        "effects" => [{ "kind" => "patch",
                        "payload" => { "path" => "app/models/item.rb", "find" => "ITEM = 1",
                                       "replace" => "ITEM = 2" } }]
      }, {
        "id" => "d2", "question" => "Later rung?", "answer" => "not yet",
        "accepted_by" => "operator:9f2c",
        "effects" => [{ "kind" => "patch",
                        "payload" => { "path" => "app/models/item.rb", "find" => "ITEM = 2",
                                       "replace" => "ITEM = 3" },
                        "applies_when" => { "rung_gte" => "7.0.0" } }]
      }]
    }.to_json)

    record = step(dir, project: project).run

    assert_equal ["d1"], record.accepted_decisions.map { |decision| decision["id"] }
    assert_includes record.to_h["accepted_decisions"].first["question"], "new constant"
    assert_equal "ITEM = 2\n", File.read(File.join(dir, "app/models/item.rb"))
  end

  # **The scan reads the application's source roots and its own suite, not the whole checkout.**
  # A project that keeps its code under `app` and `lib` does not send its vendor tree or its CI
  # configuration; a modular monolith that keeps models under `components` declares that root and
  # does. The suite is read whatever the declaration says, because the framework's test-side API is
  # called there and nowhere else: `assigns`/`assert_template` moved into a gem at 5.0 and every call
  # site of the change is in `spec/` — a declaration written before that rule existed
  # (`app lib config`) meant the bridge's evidence was never sent.
  def test_the_scan_is_scoped_to_the_declared_source_roots_and_the_suite
    dir = track(app)
    with_source(dir, "app/models/item.rb", "class Item\nend\n")
    with_source(dir, "spec/models/item_spec.rb", "describe Item do\nend\n")
    with_source(dir, "vendor/bundle/item.rb", "class Item\nend\n")
    project = Agents::Upgrader::Project.parse({
      "slug" => "storefront", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0",
      "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" },
      "source_roots" => ["app", "lib"]
    }.to_json)
    corpus = FakeCorpus.new(payload: plan)

    step(dir, project: project, corpus: corpus).run

    sent = corpus.asked_files.first
    assert_includes sent, "app/models/item.rb"
    assert_includes sent, "spec/models/item_spec.rb",
      "the project's own suite was not read, so a test-side change has no evidence"
    refute_includes sent, "vendor/bundle/item.rb",
      "a declared root scopes the scan and vendor is not one"
  end

  def test_an_app_update_file_the_project_skips_is_removed_and_recorded
    dir = track(app)
    runner = MigratingRunner.new(dir, path: "config/storage.yml")
    project = Agents::Upgrader::Project.parse({
      "slug" => "storefront", "repo" => "acme/storefront", "from" => "4.2.11", "to" => "6.0.0",
      "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" },
      "app_update" => { "skip" => ["config/storage.yml"] }
    }.to_json)

    record = step(dir, project: project, runner: runner,
      applier: Agents::Upgrader::Applier).run

    refute File.exist?(File.join(dir, "config/storage.yml")),
      "the policy skipped the file, so it is not in the tree"
    skipped = record.app_update["skipped"]
    assert_equal ["config/storage.yml"], skipped.map { |entry| entry["path"] }
    assert_includes skipped.first["reason"], "app_update policy"
    assert_empty record.app_update["adopted"]
  end

  def test_the_pin_rewrite_touches_one_line_and_leaves_the_rest_alone
    text = %(source "https://rubygems.org"\ngem "rails", "4.2.11"\ngem "pg", "1.4"\n)

    assert_equal %(source "https://rubygems.org"\ngem "rails", "5.0.0"\ngem "pg", "1.4"\n),
      step(Dir.tmpdir).send(:rewrite_pin, text, "5.0.0")
  end

  def test_the_pin_rewrite_adds_a_version_where_the_line_has_none
    assert_equal %(gem "rails", "5.0.0"\n), step(Dir.tmpdir).send(:rewrite_pin, %(gem "rails"\n), "5.0.0")
  end

  # A pin with arguments this does not understand — a git source, a group with options —
  # is left alone: a rewrite it cannot read is a rewrite it must not make.
  def test_the_pin_rewrite_refuses_a_line_it_does_not_understand
    assert_nil step(Dir.tmpdir).send(:rewrite_pin, %(gem "rails", github: "rails/api/rails"\n), "5.0.0")
    assert_nil step(Dir.tmpdir).send(:rewrite_pin, %(gem "pg", "1.4"\n), "5.0.0")
  end

  # **The hold's two halves, held still.** What moved is a fact read out of two locks rather than
  # reasoned about from a dependency graph, and the line that puts it back is written for one resolve
  # and no longer — so both are pure, and both are asserted rather than left for a walk to notice.
  def test_the_hold_names_what_moved_without_being_asked_to_and_only_that
    s = step(Dir.tmpdir)

    moved = s.send(:moved_without_need,
      { "rake" => "10.0.4", "rails" => "4.0.0.rc1", "i18n" => "0.6.4" },
      %w[rails],
      { "rake" => "12.3.3", "rails" => "4.1.0", "i18n" => "0.6.4" })

    assert_equal({ "rake" => "10.0.4" }, moved,
      "the named gem is not a hold, and neither is a gem that did not move")
    assert_equal [%(gem "rake", "= 10.0.4")], s.send(:hold_lines, moved)
    assert_equal %(source "x"\ngem "rake", "= 10.0.4"\n),
      s.send(:held_gemfile, %(source "x"\n), moved)
    assert_equal %(source "x"\n), s.send(:held_gemfile, %(source "x"\n), {}),
      "nothing to hold leaves the Gemfile untouched"
  end

  # **A gem the application declares is the application's line, not this tool's.** Appending a
  # second line for one is not a hold: bundler refuses the Gemfile outright — measured, the first
  # hold failed the pin on `capistrano (>= 0)` against `capistrano (= 2.15.4)` — and rewriting the
  # line is not the answer either, because the preflight will not touch a declaration that carries
  # an option, which is exactly what that line carries.
  def test_the_hold_leaves_the_gems_the_gemfile_declares_alone
    s = step(Dir.tmpdir)
    gemfile = %(source "https://rubygems.org"\ngem "capistrano", require: false\ngem 'rake'\n)

    held = s.send(:undeclared,
      { "capistrano" => "2.15.4", "rake" => "10.0.4", "i18n" => "0.6.4" }, gemfile)

    assert_equal({ "i18n" => "0.6.4" }, held,
      "a declared gem is the application's line and cannot be held twice")
  end

  # **A fresh clone is configured before anything reads it, and the record says so.** The measured
  # failure was two stages deep: `config/database.yml` is git-ignored and ships as an example, the
  # services stage found no file and started no PostgreSQL, and the baseline failed on a database
  # the walk had never tried to provide. The copy is detected from the repository's own ignore
  # rules and example, and the bundle's groups follow from the adapter the copy names.
  def test_a_git_ignored_database_example_is_seeded_before_the_bundle_and_recorded
    dir = track(app(gemfile: <<~GEM))
      source "https://rubygems.org"
      gem "rails", "4.2.11"
      group :postgresql, optional: true do
        gem "pg", "1.6.3"
      end
    GEM
    File.write(File.join(dir, ".gitignore"), "config/database.yml\n")
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "database.yml.example"), <<~YAML)
      test:
        adapter: postgresql
        database: app_test
    YAML
    commit(dir, "the database example")
    runner = FakeRunner.new

    record = step(dir, runner: runner, tests: CapturingTests.new).run

    assert File.file?(File.join(dir, "config", "database.yml")),
      "the walk measured a tree it had not configured"
    bootstrap = record.stages.find { |stage| stage.stage == Agents::Upgrader::Record::BOOTSTRAP }
    refute_nil bootstrap, "the record does not say the tree was configured"
    assert_includes bootstrap.output_tail, "config/database.yml.example"
    install = runner.envs.find { |command, _env| command == "bundle install" }
    refute_nil install, "the step never installed the bundle"
    assert_equal "postgresql", install.last["BUNDLE_WITH"],
      "the adapter's optional group was not part of the bundle"
  end

  # **A repair that only changes how a gem is required does not ask the resolver to move it.**
  # Measured on the first real application's patch rung: `capistrano` was named in
  # `bundle update` because the preflight had written `require: false` on its line, the resolve
  # took capistrano 3 beside `rvm-capistrano ~> 2.15.4`, and a patch release that changes no
  # documented API failed at the pin. The named set is the gems whose *requirement* moved.
  def test_a_require_option_repair_is_not_a_gem_the_pin_asks_to_move
    s = step(Dir.tmpdir)
    applied = lambda do |after|
      Agents::Upgrader::Applier::Applied.new(
        path: "Gemfile", line: 2, text: %(gem "capistrano"\n), after: after,
        subject: "capistrano", origin: "preflight", note: nil
      )
    end

    refute(s.send(:version_move?, applied.call(%(gem "capistrano", require: false\n))),
      "a require-option repair names a gem the lock should keep where it is")
    assert(s.send(:version_move?, applied.call(%(gem "capistrano", "~> 3.0"\n))),
      "a requirement that moved is a gem the pin must name")
  end

  # **A binstub the checkout did not mark executable is run through its own interpreter.**
  # `rails_modular_monolith` commits its whole `bin/` directory at 0644, and a volume mounted without
  # file modes drops the bit from files git records at 100755; both answer
  # `exec: "bin/rails": permission denied` and the step then reads a database that was never created
  # as a base suite that fails. The tree is not changed — thirty mode changes in the patch is a change
  # the application never asked for — and the record keeps the command a reader recognises.
  def test_a_binstub_without_its_execute_bit_runs_through_its_shebang
    dir = track(Dir.mktmpdir)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    File.write(File.join(dir, "bin", "rails"), "#!/usr/bin/env ruby\n")
    File.chmod(0o644, File.join(dir, "bin", "rails"))
    s = step(dir)

    assert_equal %w[ruby bin/rails db:create db:test:prepare],
      s.send(:runnable, %w[bin/rails db:create db:test:prepare], dir)
    assert_equal ["ruby", "bin/rails", "assets:precompile"],
      s.send(:runnable, ["bin/rails", "assets:precompile"], dir)
  end

  def test_a_binstub_shell_script_runs_through_the_shell_its_shebang_names
    dir = track(Dir.mktmpdir)
    FileUtils.mkdir_p(File.join(dir, "script"))
    File.write(File.join(dir, "script", "serve"), "#!/bin/bash\nexec bundle exec puma\n")
    File.chmod(0o644, File.join(dir, "script", "serve"))

    assert_equal %w[bash script/serve], step(dir).send(:runnable, %w[script/serve], dir)
  end

  # Everything else is left exactly as it was: an executable script is its own entry point, a program
  # that is not a file in the tree (`bundle`, `yarn`, `git`) is not this tool's to prefix, and a file
  # with no shebang names no interpreter — in which case exit 126 is the honest answer rather than a
  # guess about what to run.
  def test_a_command_that_is_not_a_script_in_the_tree_is_left_alone
    dir = track(Dir.mktmpdir)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    File.write(File.join(dir, "bin", "rails"), "#!/usr/bin/env ruby\n")
    File.chmod(0o755, File.join(dir, "bin", "rails"))
    File.write(File.join(dir, "bin", "plain"), "no shebang here\n")
    File.chmod(0o644, File.join(dir, "bin", "plain"))
    s = step(dir)

    assert_equal %w[bin/rails db:create], s.send(:runnable, %w[bin/rails db:create], dir)
    assert_equal %w[bundle exec rspec], s.send(:runnable, %w[bundle exec rspec], dir)
    assert_equal %w[yarn install --frozen-lockfile],
      s.send(:runnable, ["yarn", "install", "--frozen-lockfile"], dir)
    assert_equal %w[bin/plain --flag], s.send(:runnable, %w[bin/plain --flag], dir)
  end

  # The record still reads the command a person recognises, and says what actually ran: `display` is
  # the application's own argv, and `command` is the one the machine was handed.
  def test_the_record_shows_the_binstub_and_runs_the_interpreter
    dir = track(app(lockfile: LOCKFILE.sub("rails (4.2.11)", "rails (5.0.0)")))
    File.chmod(0o644, File.join(dir, "bin", "rails"))
    commit(dir, "the binstub arrived without its mode")
    runner = FakeRunner.new
    corpus = FakeCorpus.new(payload: plan(to: "5.0.0", from: "4.2.11"))

    record = step(dir, corpus: corpus, runner: runner).run

    assert_includes runner.calls, "ruby bin/rails app:update"
    stage = record.stages.find { |each| each.stage == Agents::Upgrader::Record::RAILS_UPDATE }
    refute_nil stage, "the update task never ran"
    assert_equal "ruby bin/rails app:update", stage.command
    assert_equal "bin/rails app:update", stage.display
  end
end
