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
  def app(lockfile: LOCKFILE, gemfile: %(source "https://rubygems.org"\ngem "rails", "4.2.11"\n))
    dir = Dir.mktmpdir
    File.write(File.join(dir, "Gemfile.lock"), lockfile)
    File.write(File.join(dir, "Gemfile"), gemfile)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    File.write(File.join(dir, "bin", "rails"), "#!/usr/bin/env ruby\n")
    File.chmod(0o755, File.join(dir, "bin", "rails"))
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
    @dirs&.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
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
    def initialize(payload: nil, refuse: nil, edits: [], manual: [])
      @payload = payload
      @refuse = refuse
      @edits = edits
      @manual = manual
    end

    def upgrade(from:, to:)
      raise AgentsFyi::Upgrader::Corpus::Refused, @refuse if @refuse

      @payload
    end

    def scan(from:, to:, files:)
      { "edits" => @edits, "manual" => @manual,
        "counts" => { "files" => files.size, "automatic" => @edits.size, "manual" => @manual.size },
        "next_step" => "this window's documented changes are all defaults with no call site" }
    end
  end

  class FakeTests
    def initialize(suite: :default, result: nil)
      @suite = suite
      @result = result
    end

    def detect(_root)
      return nil if @suite.nil?

      AgentsFyi::Upgrader::Tests::Suite.new(kind: :rspec, command: "bundle exec rspec")
    end

    def no_suite_reason(_root) = "no test directory, no spec directory and no Rakefile"

    def run(_root, _suite, timeout:, env:)
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

    def run(root, _suite, timeout:, env:)
      @seen << File.read(File.join(root, "Gemfile"))
      @results.shift || @results.last
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

    def run(root, _suite, timeout:, env:)
      @seen << File.read(File.join(root, "Gemfile"))
      @envs << env
      @calls_when_it_ran << (@runner && @runner.calls.dup)
      super
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
           reuse: false, source: nil, out: nil)
    @source = source || FakeSource.new(dir, home: dir)
    AgentsFyi::Upgrader::Step.new(
      repository: "acme/storefront", to: "6.0.0", api: "http://api.test", home: dir,
      out: out, record: record, ledger: ledger, source: @source,
      corpus: corpus || FakeCorpus.new(payload: plan), tests: tests || FakeTests.new,
      applier: FakeApplier, runner: runner || FakeRunner.new, contribute: contribute,
      reuse: reuse
    )
  end

  # The baseline is the reason the verdict means anything, so it has to run on the copy
  # as it arrived — before the pin is rewritten and before an edit is applied. The
  # assertion is on the Gemfile the suite was handed rather than on a runner's call
  # list, because `Tests.run` spawns the suite itself: an injected runner never sees it,
  # so the call list could only ever have shown the *absence* of a suite that did run.
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
