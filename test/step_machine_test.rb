# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents_fyi/upgrader"

# The pipeline with a machine behind it: which interpreter a step executes on, what happens
# when none can serve it, and that every command the application runs goes through the machine
# the step chose.
#
# `step_test.rb` drives the pipeline natively, which is what a hand-run step is. This file
# drives the *selection*: the era matrix, with a machine per era whose `bundle install` does
# what the test says — so "2.1 cannot install it, 2.2 can" is a fact a test can assert rather
# than six minutes of gem builds. The real images are exercised by the walk, not here.
class StepMachineTest < Minitest::Test
  Command = AgentsFyi::Upgrader::Record::Command
  Step = AgentsFyi::Upgrader::Step

  # The matrix's eras, in the order the selection tries them for this lockfile (no `ruby` line
  # and no `RUBY VERSION`, so the floor is the only filter and the walk starts at the oldest).
  ERAS = %w[2.1 2.2 2.5 2.7 3.2 3.3].freeze

  LOCKFILE = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        rails (4.0.0.rc1)

    PLATFORMS
      ruby

    DEPENDENCIES
      rails (= 4.0.0.rc1)
  LOCK

  GEMFILE = %(source "https://rubygems.org"\ngem "rails", "4.0.0.rc1"\n)

  # A lockfile shaped like a real application's: the meta-gem pins its components at its own
  # version, and the gems it depends on that are not components are pinned elsewhere.
  FRAMEWORK_LOCK = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        actionpack (4.0.0.rc1)
          activesupport (= 4.0.0.rc1)
        activesupport (4.0.0.rc1)
        i18n (0.6.4)
        rails (4.0.0.rc1)
          actionpack (= 4.0.0.rc1)
          railties (= 4.0.0.rc1)
          sprockets-rails (~> 2.0.0)
        railties (4.0.0.rc1)
        rake (10.0.4)
        sprockets-rails (2.0.0)

    PLATFORMS
      ruby

    DEPENDENCIES
      rails (= 4.0.0.rc1)
  LOCK

  class FakeSource
    def initialize(root, commit: "abc12345", home: nil)
      @root = root
      @commit = commit
      @home = home || root
    end

    attr_reader :root, :commit

    def description = "fixture"
    def bundle_env = { "BUNDLE_PATH" => File.join(@home, "bundles", "fixture") }

    def worktree(_reference, ref:, home:, run:, reuse: false)
      self
    end
  end

  class FakeCorpus
    def initialize(requires_ruby: "1.9.3")
      @requires_ruby = requires_ruby
    end

    def upgrade(from:, to:)
      { "steps" => [{ "from_version" => from, "to_version" => to, "name" => "Rails #{to}",
                      "requires_ruby" => @requires_ruby, "changes" => [], "note" => "" }],
        "next_step" => "one step" }
    end

    def route(ruby:, rails:, lockfile:)
      { "ruby" => ruby, "rails" => rails, "gems_read" => 0,
        "counts" => { "keep" => 0, "move" => 0, "replace" => 0, "remove" => 0, "blocked" => 0,
                      "unknown" => 0 },
        "gems" => [], "stored" => false, "next_step" => "every pin is recorded" }
    end

    def gem_migrations(gems:)
      { "migrations" => [], "counts" => { "selected" => 0, "total" => 0 }, "stored" => false,
        "next_step" => "the digest's own sentence" }
    end

    def scan(from:, to:, files:)
      { "edits" => [], "manual" => [], "counts" => { "automatic" => 0, "manual" => 0 },
        "next_step" => "nothing" }
    end

    # The scan's own window starts at the ladder's bottom, so the double answers the ladder.
    def ladder = { "earliest" => "4.2.11", "top" => "8.1.0", "steps" => [] }
  end

  class FakeTests
    attr_reader :machines

    def initialize(results: nil)
      @results = results
      @machines = []
    end

    def detect(_root) = AgentsFyi::Upgrader::Tests::Suite.new(kind: :rspec, command: "bundle exec rspec")
    def no_suite_reason(_root) = "no suite"

    def run(root, _suite, timeout:, env:, machine: nil)
      @machines << machine
      (@results&.shift || @results&.last) || green
    end

    def green
      AgentsFyi::Upgrader::Tests::Result.new(command: "bundle exec rspec", ran: true, passed: true,
        exit_code: 0, seconds: 0.1, output_tail: "3 examples", timed_out: false)
    end

    def machine_test_env = { "RAILS_ENV" => "test" }
  end

  # The shell, answering by substring. Every command a fake machine carries is prefixed with
  # its era, so "this era's bundle install fails" is one line of setup.
  class FakeRunner
    attr_reader :calls

    def initialize(answers: {})
      @answers = answers
      @calls = []
    end

    def run(argv, stage:, chdir:, env: {}, stdin: nil)
      line = argv.join(" ")
      @calls << line
      exit_code, output = @answers.find { |needle, _| line.include?(needle) }&.last || [0, ""]
      Command.new(stage: stage, command: line, ran: true, exit_code: exit_code, seconds: 0.0,
        output_tail: output.to_s)
    end
  end

  # A machine whose world is stated by the test: whether it starts, and what it services.
  class FakeMachine
    attr_reader :era, :started, :stopped

    def initialize(era, starts: true, services: true)
      @era = era
      @starts = starts
      @services = services
      @started = false
      @stopped = false
    end

    def start!(stage:, stages:)
      @started = true
      stages << Command.new(stage: stage, command: "fake start #{era}", ran: true, exit_code: 0,
        seconds: 0.0, output_tail: "")
      @starts
    end

    def unavailable = "the image for #{era} is not built here"
    def stop! = (@stopped = true)
    def command(argv, chdir:, env: {}) = [["fake", era, *argv], {}]
    def script(command, chdir:, env: {}) = [["fake", era, "sh", "-lc", command], {}]
    def interpreter = "ruby #{era}"
    def ruby_version = era
    def image = "era-#{era}"
    def services? = @services
    def stamp = "ruby #{era} (era-#{era}@sha256:#{"f" * 64})"
  end

  def setup
    @dirs = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def app(lockfile: LOCKFILE, gemfile: GEMFILE)
    dir = Dir.mktmpdir
    File.write(File.join(dir, "Gemfile.lock"), lockfile)
    File.write(File.join(dir, "Gemfile"), gemfile)
    FileUtils.mkdir_p(File.join(dir, "spec"))
    File.write(File.join(dir, "spec", "spec_helper.rb"), "")
    # `bin/rails` *and* a `Rakefile`, because `rails:update` is one of the stages a step must
    # be able to run and this fixture is a Rails **4.2** application: on 4.x both
    # `rails:update` and `db:create` are rake tasks (`bin/rails app:update` arrived in 5.0),
    # so the runner is chosen from the version and a fixture with only a binstub is one this
    # tool cannot move. Every test in this file is about the machine, not about that refusal.
    FileUtils.mkdir_p(File.join(dir, "bin"))
    File.write(File.join(dir, "bin", "rails"), "#!/usr/bin/env ruby\n")
    File.chmod(0o755, File.join(dir, "bin", "rails"))
    File.write(File.join(dir, "Rakefile"), "require File.expand_path(\"../config/application\", __FILE__)\n")
    system("git", "init", "--quiet", dir, out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "add", "--all", out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "-c", "user.email=t@example.com", "-c", "user.name=t",
      "commit", "--quiet", "-m", "fixture", out: File::NULL, err: File::NULL)
    @dirs << dir
    dir
  end

  def machines(&block)
    ERAS.to_h { |era| [era, FakeMachine.new(era, **(block ? yield(era) : {}))] }
  end

  def step(dir, machines:, runner: nil, tests: nil, corpus: nil, ledger: nil, runtime: "docker")
    Step.new(
      repository: "acme/old", to: "4.1.0", home: dir, out: nil,
      source: FakeSource.new(dir), corpus: corpus || FakeCorpus.new,
      tests: tests || FakeTests.new, runner: runner || FakeRunner.new, ledger: ledger,
      runtime: runtime, machine_factory: ->(entry) { machines.fetch(entry.name) }
    )
  end

  # The first era that installs the bundle is the one the step runs on: 2.1's attempt fails,
  # 2.2's succeeds, nothing after 2.2 is started — and both attempts are in the record, because
  # "which interpreter was tried and why it was rejected" is the answer to the question a
  # failed walk asks.
  def test_the_first_era_that_installs_the_bundle_is_the_one_the_step_runs_on
    dir = app
    fleet = machines
    runner = FakeRunner.new(answers: { "fake 2.1 bundle install" => [1, "json 1.7.7 fails to build"] })
    tests = FakeTests.new
    record = step(dir, machines: fleet, runner: runner, tests: tests).run

    assert_equal "passed", record.verdict, record.why
    assert_equal "ruby 2.2", record.interpreter
    assert_equal "2.2", record.era
    assert_equal "ruby 2.2 (era-2.2@sha256:#{"f" * 64})", record.machine
    assert fleet["2.2"].started
    assert fleet["2.1"].stopped, "the rejected era's container was left running"
    assert fleet["2.2"].stopped,
      "the container the step ran in was left running: `--rm` does not end a keepalive"
    refute fleet["2.5"].started, "an era was started after one already installed the bundle"

    assert_equal 2, record.stages.count { |stage| stage.stage == "interpreter" },
      "both attempts should be recorded"
    stages = record.stages.map(&:stage)
    assert_operator stages.index("services"), :<, stages.index("baseline"),
      "the suite must run against the services, so they start before it"
    assert(runner.calls.any? { |call| call.start_with?("fake 2.2 bundle install") },
      "the install did not go through the chosen machine")
    assert_equal ["2.2"], tests.machines.map(&:era).uniq
  end

  # **A rung moves Rails; it does not move the world.** `bundle update rails` resolves every
  # dependency afresh, and the lighthouse showed what that costs: a 2013 application pinned
  # rake 10.0.4, the unconstrained update pulled 12.3.3, and Rails 4.1's own `rails:update`
  # then died on `Rake::Application#last_comment`, which rake 11 removed — the rung failed on
  # a gem the move had no reason to touch. `--conservative` keeps the locked versions of
  # everything the resolution does not have to change.
  def test_the_pin_moves_rails_and_leaves_the_rest_of_the_bundle_where_it_was
    record = step(app, machines: machines).run

    pin = record.stages.find { |stage| stage.stage == AgentsFyi::Upgrader::Record::PIN }

    assert pin, "the pin stage is not in the record"
    # The era is whatever the fleet settles on; what is asserted is the command's own shape.
    assert_equal "bundle update rails --conservative", pin.command.split(" ", 3).last
  end

  # **The framework's own gems are named with the meta-gem; nothing else is unlocked.** A
  # conservative resolve that left `activemodel` at the version the move is leaving cannot find
  # a compatible set at all — bundler named exactly that gem and advised rebuilding the
  # snapshot, which is the unconstrained update that moved rake to 12.3.3 and broke
  # `rails:update`. The gems pinned at the framework's version move with it; `rake` and
  # `sprockets-rails` stay where the application put them.
  def test_the_pin_unlocks_the_framework_s_own_gems_and_leaves_the_rest_locked
    record = step(app(lockfile: FRAMEWORK_LOCK), machines: machines).run

    pin = record.stages.find { |stage| stage.stage == AgentsFyi::Upgrader::Record::PIN }
    command = pin.command.split(" ", 3).last

    assert_includes command, "actionpack", command
    assert_includes command, "railties", command
    assert_includes command, "--conservative", command
    refute_includes command, "rake ", command
    refute_includes command, "sprockets-rails", command
  end

  # **A locked gem the move requires is named by bundler itself, and the pin asks again.** The
  # lighthouse proved the framework's own gems are not enough: `i18n` was locked at 0.6.4 and
  # activesupport 4.1.0 requires `i18n (>= 0.6.9, ~> 0.6)`, so the first resolve could not find
  # a compatible set. Bundler's message names exactly that gem — it is the resolver's own answer
  # for this application, which no matrix here could have — and the next round unlocks it while
  # everything else stays where it was. The first round's failure stays in the record.
  def test_a_pin_bundler_could_not_resolve_names_what_bundler_named_and_tries_again
    runner = FakeRunner.new(answers: {
      "i18n" => [0, ""],
      "bundle update" => [6, "Resolving dependencies...\nBundler could not find compatible " \
                             "versions for gem \"i18n\":\n  In snapshot (Gemfile.lock):\n    " \
                             "i18n (= 0.6.4)\n"]
    })

    record = step(app(lockfile: FRAMEWORK_LOCK), machines: machines, runner: runner).run

    pins = record.stages.select { |stage| stage.stage == AgentsFyi::Upgrader::Record::PIN }

    assert_equal 2, pins.length, "the pin should have been asked again with the gem bundler named"
    refute_includes pins.first.command, "i18n", pins.first.command
    assert_includes pins.last.command, "i18n", pins.last.command
    assert pins.last.ok?, pins.last.output_tail
    assert record.passed?, record.why
  end

  # **A step prunes before it installs, not only when an operator asks.** The home it mounts
  # into its own container is the bind mount Docker sets up at `docker run`, and what a finished
  # run left there is paid by the *next* step's container start — measured, twenty seconds to
  # five minutes as the bundles accumulated.
  def test_a_step_prunes_the_bundles_of_runs_that_are_over_before_it_installs
    dir = app
    gone = Process.spawn("true")
    Process.wait(gone)
    root = File.join(dir, "work", "abc123", "run-20261017203314-#{gone}")
    FileUtils.mkdir_p(root)
    bundle = File.join(dir, "bundles", Digest::SHA256.hexdigest(root)[0, 16])
    FileUtils.mkdir_p(bundle)

    step(dir, machines: machines).run

    refute File.exist?(bundle), "a finished run's bundle was left in the home this step mounts"
  end

  # No interpreter can install this application's bundle. The verdict is `unverified` — the
  # machine could not make the measurement — and every attempt's reason travels, because the
  # fix (a missing system library, a newer era, a compiler in the image) is decided from them.
  def test_a_step_no_interpreter_can_install_is_unverified_and_names_every_attempt
    dir = app
    runner = FakeRunner.new(answers: { "bundle install" => [1, "native extension fails"] })
    record = step(dir, machines: machines, runner: runner).run

    assert_equal "unverified", record.verdict
    assert_includes record.why, "no interpreter installed the application's bundle"
    assert_includes record.why, "2.1: native extension fails"
    # The stamp is not this process's, or the verdict would settle and stand for ever against
    # a matrix somebody has since extended.
    assert_match(/\Ano interpreter: requires ruby /, record.machine.to_s)
  end

  def test_a_container_that_will_not_start_is_an_attempt_that_says_why
    dir = app
    fleet = machines { |_era| { starts: false } }
    record = step(dir, machines: fleet).run

    assert_equal "unverified", record.verdict
    assert_includes record.why, "the image for 2.1 is not built here"
  end

  # A step the *process's* interpreter cannot serve says so before spending a bundle resolve,
  # and names the way to run it: this is the sentence a person who ran `step` by hand needs.
  def test_a_native_step_whose_interpreter_is_below_the_floor_says_how_to_run_it
    dir = app
    record = step(dir, machines: machines, corpus: FakeCorpus.new(requires_ruby: "99.0.0"),
      runtime: "native").run

    assert_equal "unverified", record.verdict
    assert_includes record.why, "requires Ruby 99.0.0"
    assert_includes record.why, "UPGRADER_RUNTIME=docker"
  end

  # The services stage runs on a container machine, and a service that could not start is the
  # verdict: the suite that follows would fail for a reason nobody reading the record could
  # see.
  def test_services_start_before_the_baseline_and_a_failure_to_start_is_the_verdict
    dir = app
    runner = FakeRunner.new(answers: { "agents-fyi-services" => [1, "no PostgreSQL server"] })
    record = step(dir, machines: machines, runner: runner).run

    assert_equal "failed", record.verdict
    assert_includes record.why, "services"
    assert_equal "services", record.stages.last.stage,
      "a failed services stage should stop the step before anything is measured"
  end

  def test_the_application_s_database_is_prepared_before_the_baseline
    dir = app
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "database.yml"), "test:\n  adapter: postgresql\n")
    FileUtils.mkdir_p(File.join(dir, "bin"))
    File.write(File.join(dir, "bin", "rails"), "#!/usr/bin/env ruby\n")
    File.chmod(0o755, File.join(dir, "bin", "rails"))
    runner = FakeRunner.new
    record = step(dir, machines: machines, runner: runner).run

    stages = record.stages.map(&:stage)
    assert_operator stages.index("database"), :<, stages.index("baseline")
    assert(runner.calls.any? { |call| call.include?("db:create db:test:prepare") })
  end

  # **The other half of the version rule, and the reason it is a rule rather than a file
  # check.** `rails db:create` and `rails app:update` arrived in Rails 5.0; on 4.x both are
  # rake tasks. The first real walk's application carries a `bin/rails` binstub *and* runs
  # 4.0.0.rc1, so "does bin/rails exist" answers the wrong question — and the wrong answer
  # leaves the suite with no database and the record with a command-not-found.
  def test_a_rails_five_application_runs_both_moved_commands_through_bin_rails
    dir = app(lockfile: LOCKFILE.sub("4.0.0.rc1", "5.2.8"), gemfile: GEMFILE.sub("4.0.0.rc1", "5.2.8"))
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "database.yml"), "test:\n  adapter: postgresql\n")
    runner = FakeRunner.new
    record = step(dir, machines: machines, runner: runner).run

    calls = runner.calls.map { |call| Array(call).join(" ") }
    assert(calls.any? { |call| call.include?("bin/rails db:create db:test:prepare") },
      "a Rails 5 application was sent to rake for its database")
    assert(calls.any? { |call| call.include?("bin/rails app:update") },
      "a Rails 5 application was sent to rake for its update")
    refute(calls.any? { |call| call.include?("rake") },
      "a Rails 5 application ran a rake task for a command the CLI owns")
    refute_nil record
  end

  # A database that could not be prepared is named beside the suite failure rather than
  # becoming a failure of its own: a red suite after a green baseline is a finding about the
  # move, unless the schema never loaded, in which case nothing was measured.
  def test_a_failed_database_stage_is_named_in_a_suite_failure
    dir = app
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "database.yml"), "test:\n  adapter: postgresql\n")
    FileUtils.mkdir_p(File.join(dir, "bin"))
    File.write(File.join(dir, "bin", "rails"), "#!/usr/bin/env ruby\n")
    File.chmod(0o755, File.join(dir, "bin", "rails"))
    red = AgentsFyi::Upgrader::Tests::Result.new(command: "bundle exec rspec", ran: true,
      passed: false, exit_code: 1, seconds: 0.1, output_tail: "2 examples, 1 failure", timed_out: false)
    # Green first, red second: a red *baseline* would make the verdict `unverified`, which is
    # the other test's subject.
    tests = FakeTests.new(results: [FakeTests.new.green, red])
    runner = FakeRunner.new(answers: { "db:create" => [1, "could not connect"] })
    record = step(dir, machines: machines, runner: runner, tests: tests).run

    assert_equal "failed", record.verdict
    assert_includes record.why, "database preparation failed"
  end

  # A move settled under one machine is settled when that same machine would run it now, and
  # re-opened when the machine changed — the digest is the difference a rebuilt era image
  # makes, which is the case the ledger's stamp exists for.
  def test_a_settled_move_is_re_opened_when_the_machine_changes
    dir = app
    ledger = AgentsFyi::Upgrader::Ledger.new(path: File.join(dir, "ledger.json"), machine: "ruby 3.3.12")
    ledger.record(repo: "acme/old", commit: "abc12345", from_version: "4.0.0.rc1",
      to_version: "4.1.0", verdict: "passed",
      machine: "ruby 2.1 (era-2.1@sha256:#{"f" * 64})", era: "2.1")

    fleet = machines
    assert_nil step(dir, machines: fleet, ledger: ledger).run,
      "the same machine would run this move again, so it should be settled"
    refute fleet["2.1"].started

    # The same era, rebuilt: the tag is the same and the bytes are not, so the stamp differs
    # and the move is walked again.
    rebuilt = machines
    ledger.record(repo: "acme/old", commit: "abc12345", from_version: "4.0.0.rc1",
      to_version: "4.1.0", verdict: "passed",
      machine: "ruby 2.1 (era-2.1@sha256:#{"e" * 64})", era: "2.1")
    record = step(dir, machines: rebuilt, ledger: ledger).run

    assert_equal "passed", record.verdict
    assert rebuilt["2.1"].started, "a move settled under another machine was not re-opened"
  end
end
