# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "agents_fyi/upgrader"

# The pipeline, driven without a network, a bundle or an application.
#
# A step that installs gems and boots Rails is not something a unit test can do, so the
# three decisions inside it are held still instead: the baseline runs before anything is
# written, the pin rewrite either changes one line or refuses, and `app:update` may keep
# only what it added. Those are the parts whose failure reaches somebody's repository or
# somebody's corpus, and they are the ones this file exists for.
class StepTest < Minitest::Test
  Command = AgentsFyi::Upgrader::Record::Command
  Lockfile = AgentsFyi::Upgrader::Lockfile

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
    def bundle_env = { "BUNDLE_PATH" => File.join(@home, "bundles", "fixture") }

    def worktree(_reference, ref:, home:, run:, reuse: false)
      @asked << { ref: ref, home: home, run: run, reuse: reuse }
      self
    end
  end

  class FakeCorpus
    attr_reader :gem_requests

    attr_reader :routes

    def initialize(payload: nil, refuse: nil, edits: [], manual: [], migrations: [],
                   route: nil, routes: nil, route_error: nil)
      @payload = payload
      @refuse = refuse
      @edits = edits
      @manual = manual
      @migrations = migrations
      @route = route
      @routes = routes
      @route_error = route_error
      @gem_requests = []
      @asked_routes = []
    end

    # The routing answer, as the service writes it: no moves unless the test says otherwise,
    # which is what keeps every existing step test about its own subject. `routes:` is a
    # *sequence*, for the one test about what a second ask looks like after research.
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
      raise AgentsFyi::Upgrader::Corpus::Refused, @refuse if @refuse

      @payload
    end

    def gem_migrations(gems:)
      @gem_requests << gems
      { "migrations" => @migrations.select { |migration| gems.include?(migration["gem"]) },
        "counts" => { "selected" => 0, "total" => @migrations.size }, "stored" => false,
        "next_step" => "the digest's own sentence" }
    end

    def scan(from:, to:, files:)
      { "edits" => @edits, "manual" => @manual,
        "counts" => { "files" => files.size, "automatic" => @edits.size, "manual" => @manual.size },
        "next_step" => "this window's documented changes are all defaults with no call site" }
    end
  end

  class FakeTests
    attr_reader :machines

    def initialize(suite: :default, result: nil)
      @suite = suite
      @result = result
      @machines = []
    end

    def detect(_root)
      return nil if @suite.nil?

      AgentsFyi::Upgrader::Tests::Suite.new(kind: :rspec, command: "bundle exec rspec")
    end

    def no_suite_reason(_root) = "no test directory, no spec directory and no Rakefile"

    def run(_root, _suite, timeout:, env:, machine: nil)
      # Recorded rather than ignored: "the suite ran through the machine the step chose" is
      # the wiring the selection tests exist for, and a double that dropped the argument
      # would let the pipeline stop passing it without a red test.
      @machines << machine
      @result || AgentsFyi::Upgrader::Tests::Result.new(
        command: "bundle exec rspec", ran: true, passed: true, exit_code: 0,
        seconds: 0.2, output_tail: "3 examples, 0 failures", timed_out: false
      )
    end

    def machine_test_env = { "RAILS_ENV" => "test" }
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

    def run(root, _suite, timeout:, env:, machine: nil)
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

  class FakeApplier
    attr_reader :applied

    def initialize(_root) = @applied = []

    def apply(_edits)
      AgentsFyi::Upgrader::Applier::Result.new(applied: @applied, refused: [], files_written: 0)
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

    def run(root, _suite, timeout:, env:, machine: nil)
      @seen << File.read(File.join(root, "Gemfile"))
      @envs << env
      @calls_when_it_ran << (@runner && @runner.calls.dup)
      super(root, _suite, timeout: timeout, env: env, machine: machine)
    end
  end

  # Records every command it is asked to run *and* the environment it was given, so a test
  # can assert what ran, in what order, and under which bundle — which is the whole of what
  # the install stage promises the stages after it.
  class FakeRunner
    attr_reader :calls, :envs

    def initialize(fail_on: nil, ran: true)
      @fail_on = fail_on
      @ran = ran
      @calls = []
      @envs = []
    end

    def run(argv, stage:, chdir:, env: {}, stdin: nil)
      @calls << argv.join(" ")
      @envs << [argv.join(" "), env]
      failing = @fail_on && argv.join(" ").include?(@fail_on)
      Command.new(stage: stage, command: argv.join(" "), ran: failing ? @ran : true,
        exit_code: failing ? (@ran ? 1 : nil) : 0, seconds: 0.1,
        output_tail: failing ? "boom" : "")
    end
  end

  def step(dir, corpus: nil, tests: nil, runner: nil, ledger: nil, record: nil, contribute: false,
           reuse: false, source: nil, out: nil, research: nil, env: {}, repair: nil,
           suite_env: nil, applier: nil)
    @source = source || FakeSource.new(dir, home: dir)
    AgentsFyi::Upgrader::Step.new(
      repository: "acme/storefront", to: "6.0.0", api: "http://api.test", home: dir,
      out: out, record: record, ledger: ledger, source: @source,
      corpus: corpus || FakeCorpus.new(payload: plan), tests: tests || FakeTests.new,
      applier: applier || FakeApplier, runner: runner || FakeRunner.new, contribute: contribute,
      reuse: reuse, research: research, env: env, repair: repair, suite_env: suite_env
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

  # A research pass, as a test double: it records the pins it was handed and answers with a
  # result the step's stage can render. The fetching itself is `research_test.rb`'s subject.
  class FakeResearch
    attr_reader :pins

    def initialize = @pins = []

    def run(pins)
      @pins = pins
      AgentsFyi::Upgrader::Research::Result.new(researched: pins.map(&:first), skipped: [], reason: "")
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

  # **The agentic half, from the pipeline's side.** A green baseline and a red suite is the
  # one shape a repair may be attempted on — the failure is then attributable to the move —
  # and the verdict afterwards is the *suite's* again: a repaired step passes because the
  # suite says so, never because a model said it fixed something.
  def test_a_red_suite_after_a_green_baseline_is_repaired_and_the_suite_decides
    dir = track(app)
    record = step(dir, tests: SequencedTests.new(results: [green, red, green]),
      repair: FakeRepair, env: { "UPGRADER_REPAIR_ATTEMPTS" => "1" }).run

    assert_equal "passed", record.verdict
    assert_includes record.why, "1 agent repair attempt(s)"
    repair_stage = record.stages.find { |stage| stage.stage == "repair" }
    refute_nil repair_stage, "the attempt is not in the record"
    assert_includes repair_stage.output_tail, "app/models/user.rb"
    assert_operator record.stages.count { |stage| stage.stage == "suite" }, :>=, 2,
      "the suite must be run again after the attempt"
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
    assert_equal ["git rev-parse --short HEAD", "bundle install"], tests.calls_when_it_ran.first,
      "the baseline ran before the application's bundle was installed"
    # And the pin is not what installed it: resolving a new Rails is a later stage, and a
    # baseline taken after it would be a baseline of the wrong tree.
    refute_includes tests.calls_when_it_ran.first, "bundle update rails"
    assert record.stages.find { |stage| stage.stage == AgentsFyi::Upgrader::Record::BUNDLE }&.ok?,
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
    assert_equal ["git rev-parse --short HEAD", "bundle install"], runner.calls
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
    expected = @source.bundle_env["BUNDLE_PATH"]

    assert record.passed?, record.why
    expected = @source.bundle_env["BUNDLE_PATH"]
    assert_equal [expected, expected], tests.envs.map { |env| env["BUNDLE_PATH"] },
      "the baseline and the post-step suite did not run under this run's bundle"
    rails_commands = runner.envs.select { |call, _env| call.match?(/bundle|rails/) }
    refute_empty rails_commands, "no bundler or Rails command ran"
    outside = rails_commands.reject { |_call, env| env["BUNDLE_PATH"] == expected }
    assert_empty outside, "a Rails command ran outside this run's bundle: #{outside.inspect}"
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
    ledger = AgentsFyi::Upgrader::Ledger.new(path: ledger_path, machine: "ruby test")
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
    assert_empty AgentsFyi::Upgrader::Step.dirty_paths(dir), "the fixture is not clean"

    before = AgentsFyi::Upgrader::Step.dirty_paths(dir)
    # What `app:update` does: rewrites a file the application owns and creates one.
    added = File.join(dir, "config", "new_defaults.rb")
    File.write(owned, "load_defaults 7.0\n")
    File.write(added, "# new\n")

    adopted, conflicts = AgentsFyi::Upgrader::Step.adopt_added_only(dir, before)

    assert_equal ["config/new_defaults.rb"], adopted
    assert_equal ["config/application.rb"], conflicts
    assert_equal "load_defaults 6.0\n", File.read(owned), "the application's version was overwritten"
    assert File.file?(added)
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

  # The run body is the whole of what this tool tells the service, so it is asserted
  # rather than implied by the call above.
  def test_the_run_body_carries_the_evidence_and_the_refusals
    dir = track(app)
    planned = plan(changes: [change])
    record = step(dir, corpus: FakeCorpus.new(payload: planned)).run
    payload = AgentsFyi::Upgrader::Step.run_payload(record)

    assert_equal "acme/storefront", payload["repo_url"]
    assert_equal "passed", payload["baseline_verdict"]
    assert_includes payload["patch"].to_s, %(gem "rails", "5.0.0"), "the patch is not in the run"
    assert payload["finished_at"]
    assert payload["commands"].all? { |command| command.key?("exit_code") }
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

  def green
    AgentsFyi::Upgrader::Tests::Result.new(
      command: "bundle exec rspec", ran: true, passed: true, exit_code: 0, seconds: 0.2,
      output_tail: "3 examples, 0 failures", timed_out: false
    )
  end

  def red
    AgentsFyi::Upgrader::Tests::Result.new(
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
  def test_a_change_no_machine_may_make_is_a_decision_even_with_no_call_site_to_find
    dir = track(app)
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
    # **The gap travels with it.** A change no rule covers is a queue entry with a reason, so the
    # residue says what would close it rather than handing over the same blank list every rung.
    assert_includes decision.reason, "not automated yet:"
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
    record = step(dir, corpus: corpus, applier: AgentsFyi::Upgrader::Applier).run

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

    record = step(dir, corpus: corpus, applier: AgentsFyi::Upgrader::Applier).run

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

    record = step(dir, corpus: corpus, applier: AgentsFyi::Upgrader::Applier).run

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

    record = step(dir, corpus: corpus, applier: AgentsFyi::Upgrader::Applier).run

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

    record = step(dir, corpus: corpus, applier: AgentsFyi::Upgrader::Applier).run

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

    record = step(dir, corpus: corpus, applier: AgentsFyi::Upgrader::Applier).run

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

    record = step(dir, corpus: corpus, applier: AgentsFyi::Upgrader::Applier).run

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
      applier: AgentsFyi::Upgrader::Applier).run
    assert_includes File.read(File.join(uses_pipeline, "Gemfile")), "gem 'sprockets-rails'"

    plain = track(app)
    with_source(plain, "config/application.rb", %(require "rails"\n))
    record = step(plain, corpus: FakeCorpus.new(payload: payload),
      applier: AgentsFyi::Upgrader::Applier).run
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
      applier: AgentsFyi::Upgrader::Applier).run

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
      applier: AgentsFyi::Upgrader::Applier).run

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
    record = step(plain, corpus: FakeCorpus.new(payload: payload), applier: AgentsFyi::Upgrader::Applier).run
    assert_includes File.read(File.join(plain, "Gemfile")), %(gem "spring", ">= 3.0.0")
    assert_empty record.decisions, "the declaration is the change's whole fix"

    # A declaration that already asks for a version is left, and the change stays a decision.
    pinned = track(app(gemfile: %(source "https://rubygems.org"\ngem "rails", "4.2.11"\ngem "spring", "~> 2.0"\n)))
    with_source(pinned, "app/models/item.rb", "class Item\nend\n")
    record = step(pinned, corpus: FakeCorpus.new(payload: payload), applier: AgentsFyi::Upgrader::Applier).run
    assert_includes File.read(File.join(pinned, "Gemfile")), %(gem "spring", "~> 2.0")
    assert_equal ["Spring"], record.decisions.map(&:subject)

    # And an application that does not use Spring is not asked to install it.
    absent = track(app)
    with_source(absent, "app/models/item.rb", "class Item\nend\n")
    record = step(absent, corpus: FakeCorpus.new(payload: payload), applier: AgentsFyi::Upgrader::Applier).run
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
      applier: AgentsFyi::Upgrader::Applier).run

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

    record = step(dir, corpus: FakeCorpus.new(payload: payload), applier: AgentsFyi::Upgrader::Applier).run

    assert record.passed?, record.why
    assert_includes File.read(File.join(dir, "package.json")), "\"@rails/actioncable\""
    assert_empty record.decisions, "the rule applied, so the change is not a decision"
    tail = record.stages.find { |stage| stage.stage == "apply" }.output_tail
    assert_includes tail, "by this tool's own rules (@rails npm packages)"
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
    assert_nil step(Dir.tmpdir).send(:rewrite_pin, %(gem "rails", github: "rails/rails"\n), "5.0.0")
    assert_nil step(Dir.tmpdir).send(:rewrite_pin, %(gem "pg", "1.4"\n), "5.0.0")
  end
end
