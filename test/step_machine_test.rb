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

  # A lockfile where the framework's own new requirement rules a version out — `activesupport` asks
  # for `i18n ~> 0.7` and the application has 0.6.4 — and where a gem nothing requires anything *of*
  # has moved past its own dependency, which is the shape that cost the real walk three rounds. Nothing
  # requires anything of `rake`, so it is the one that goes back.
  REQUIRING_LOCK = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        activesupport (4.0.0.rc1)
          i18n (~> 0.7)
        i18n (0.6.4)
        old_thing (1.0.0)
          i18n (~> 0.6.4)
        rails (4.0.0.rc1)
          activesupport (= 4.0.0.rc1)
        rake (10.0.4)

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
    def initialize(requires_ruby: "1.9.3", migrations: [])
      @requires_ruby = requires_ruby
      @migrations = migrations
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
      # The service's own rule, mirrored so the double cannot lie: a `declared` entry is for a gem
      # the caller does not hold — the framework brings it in — so it travels with every answer.
      { "migrations" => @migrations.select { |migration|
        gems.include?(migration["gem"]) || migration["kind"] == "declared"
      }, "counts" => { "selected" => 0, "total" => @migrations.size }, "stored" => false,
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

    def run(argv, stage:, chdir:, env: {}, stdin: nil, timeout: nil)
      line = argv.join(" ")
      @calls << line
      exit_code, output = @answers.find { |needle, _| line.include?(needle) }&.last || [0, ""]
      Command.new(stage: stage, command: line, ran: true, exit_code: exit_code, seconds: 0.0,
        output_tail: output.to_s)
    end
  end

  # A runner that resolves the way bundler does: the lock it is asked to update comes back changed, and
  # the Gemfile it was handed at that moment is remembered. Nothing else in the suite needs a resolver;
  # this is the one property about what the *second* resolve sees.
  class ResolvingRunner < FakeRunner
    attr_reader :gemfile_during

    def initialize(bump: { "rake" => %w[10.0.4 12.3.3] })
      super()
      @bump = bump
      @gemfile_during = []
      @resolves = 0
    end

    def run(argv, stage:, chdir: nil, env: {}, stdin: nil, timeout: nil)
      if argv.join(" ").include?("bundle update")
        @resolves += 1
        gemfile = File.read(File.join(chdir, "Gemfile"))
        @gemfile_during << gemfile
        path = File.join(chdir, "Gemfile.lock")
        lock = File.read(path)
        @bump.each do |name, (from, to)|
          # The first resolve moves them, which is the leak this stage exists to undo; a later one
          # asked to hold a gem puts it back, which is what a resolve with the constraint does.
          lock = if @resolves == 1
            lock.sub("    #{name} (#{from})", "    #{name} (#{to})")
          elsif gemfile.include?(%(gem "#{name}", "= #{from}"))
            held = lock.sub("    #{name} (#{to})", "    #{name} (#{from})")
            # A resolve records what it was asked to hold in the lock's own `DEPENDENCIES`, because for
            # the length of that resolve the Gemfile really did declare it.
            held.sub(/^DEPENDENCIES\n/, "DEPENDENCIES\n  #{name} (= #{from})\n")
          else
            lock
          end
        end
        File.write(path, lock)
      end
      super
    end
  end

  # A routing that answers what the service answered on the walk this test exists for: the
  # framework's own components routed `move`, not `blocked`.
  class FrameworkMoveCorpus < FakeCorpus
    def route(ruby:, rails:, lockfile:)
      super.merge("gems" => [
        { "name" => "actionpack", "version" => "4.0.0.rc1", "verdict" => "move", "to" => "4.1.0",
          "reason" => "requires activesupport = 4.0.0.rc1, which Rails 4.1.0 does not meet" },
        { "name" => "rake", "version" => "10.0.4", "verdict" => "move", "to" => "12.3.3",
          "reason" => "the release moved this line" }
      ])
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

  def step(dir, machines:, runner: nil, tests: nil, corpus: nil, ledger: nil, runtime: "docker",
           to: "4.1.0")
    Step.new(
      repository: "acme/old", to: to, home: dir, out: nil,
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

  # **What the resolve moved without being asked to goes back.** `--conservative` does not keep it where
  # the application put it — measured on the lighthouse, rake 10.0.4 → 12.3.3 although railties 4.1 asks
  # only `rake >= 0.8.7` — so the pin holds it at the version it found, for the length of a second
  # resolve, and puts the Gemfile back afterwards. The lock is what keeps it there.
  def test_the_pin_holds_what_the_resolve_moved_without_being_asked_to
    dir = app(lockfile: FRAMEWORK_LOCK)
    runner = ResolvingRunner.new

    step(dir, machines: machines, runner: runner).run

    assert_equal 2, runner.gemfile_during.length,
      "the resolve should have been asked again with the hold in place: #{runner.gemfile_during.length}"
    refute_includes runner.gemfile_during.first, %(gem "rake", "= 10.0.4"),
      "the hold was there before anything had moved"
    assert_includes runner.gemfile_during.last, %(gem "rake", "= 10.0.4"),
      "rake moved and nothing held it"
    # **The constraint alone cannot put it back.** A resolve that does not *name* the gem does not
    # re-resolve it, so bundler answers "You have requested: bcrypt-ruby = 3.0.1 ... the bundle
    # currently has bcrypt-ruby locked at 3.1.5" and the pin fails — measured on the lighthouse, on
    # a transitive dependency of the application's own `capistrano` line.
    assert runner.calls.any? { |call| call.split.include?("rake") && call.include?("bundle update") },
      "a gem cannot be put back by a resolve that does not name it: " \
      "#{runner.calls.grep(/bundle update/).inspect}"
    refute_includes File.read(File.join(dir, "Gemfile")), %(gem "rake"),
      "the tool's own line stayed in the application's Gemfile"
    refute_includes File.read(File.join(dir, "Gemfile.lock")), "  rake (=",
      "the hold left a claim in the lockfile that the application's Gemfile does not make, and a " \
      "lock that disagrees with its Gemfile is one the next bundle install re-resolves"
  end

  # **A gem the pin moves is not a decision, whatever the routing calls it.** The guard that keeps
  # the framework's components out of the decision list reads the *verdict*, and the verdict is not
  # stable: the first real rung routed them `blocked` ("no recorded release of rails fits the
  # target") and the walk after the digest grew routed the same components `move`, so they fell
  # through to the branch that asks whether a person has a line to edit — and five *located*
  # decisions appeared for gems whose lines the pin's own `bundle update` names.
  def test_a_framework_gem_the_pin_moves_is_not_a_decision_when_the_routing_calls_it_a_move
    dir = app(lockfile: FRAMEWORK_LOCK)

    record = step(dir, machines: machines, corpus: FrameworkMoveCorpus.new).run

    refute record.decisions.any? { |decision| decision.subject.to_s.start_with?("actionpack") },
      "the pin moves actionpack and it was left as a line for a person: " \
      "#{record.decisions.map(&:subject).inspect}"
    assert record.decisions.any? { |decision| decision.subject.to_s.start_with?("rake") },
      "a gem the pin does not name is still a line for a person: " \
      "#{record.decisions.map(&:subject).inspect}"
  end

  # **A gem the resolved graph no longer accepts has to move, and holding it makes every resolve
  # impossible.** Measured on the lighthouse: the resolve moved thirty gems, and twenty-eight of them
  # were the framework's own new requirements — `activesupport 4.1` asks `i18n >= 0.6.9, ~> 0.6`
  # against the application's 0.6.4 — so a hold on all of them failed the pin on a constraint nothing
  # could satisfy. The graph states its own requirements, and `rake`, which nothing required anything
  # of, is the gem the move had no reason to touch.
  def test_the_hold_leaves_a_gem_the_resolved_graph_no_longer_accepts
    dir = app(lockfile: REQUIRING_LOCK)
    runner = ResolvingRunner.new(bump: {
      "i18n" => %w[0.6.4 0.9.5], "rake" => %w[10.0.4 12.3.3], "old_thing" => %w[1.0.0 2.0.0]
    })

    step(dir, machines: machines, runner: runner).run

    held = runner.gemfile_during.last
    assert_includes held, %(gem "rake", "= 10.0.4"),
      "nothing required anything of rake, so it goes back"
    refute_includes held, %(gem "i18n"),
      "activesupport asks for i18n ~> 0.7 and 0.6.4 does not satisfy it"
    refute_includes held, %(gem "old_thing"),
      "old_thing asks for i18n ~> 0.6.4 and the move takes i18n past it: a hold that cannot be " \
      "satisfied is worse than no hold, because it fails the resolve"
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

  # **And the gem the message says *resolved* against the conflict.** Adding only what bundler names
  # as the conflict does not converge when the gem holding it back is a *different* gem: on the
  # lighthouse's rspec-rails move bundler named `rspec-mocks`, then `rspec-expectations`, then
  # `rspec-core` in three rounds, while the pin that made all three impossible was the `rspec`
  # *meta*-gem's own `~> 2.13.0` — which its sentence names only as the requirer ("`rspec` was
  # resolved to 2.13.0, which depends on `rspec-mocks (~> 2.13.0)`"). Read rather than guessed, the
  # same way the conflicting name is, and the line unlocks because `--conservative` leaves every gem
  # the move does not need where it was.
  def test_a_pin_also_unlocks_the_gem_bundler_says_resolved_against_the_conflict
    lockfile = <<~LOCK
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
            actionpack (= 4.0.0.rc1)
            activesupport (= 4.0.0.rc1)
          rspec (2.13.0)
            rspec-core (~> 2.13.0)
            rspec-mocks (~> 2.13.0)
          rspec-core (2.13.1)
          rspec-mocks (2.13.1)
          sprockets-rails (2.0.1)

      PLATFORMS
        ruby

      DEPENDENCIES
        rails (= 4.0.0.rc1)
        rspec (~> 2.13)

      BUNDLED WITH
         2.5.22
    LOCK
    runner = FakeRunner.new(answers: {
      "rspec-mocks" => [0, ""],
      "bundle update" => [6, "Resolving dependencies...\nBundler could not find compatible " \
                             "versions for gem \"rspec-mocks\":\n  In Gemfile:\n    rspec " \
                             "was resolved to 2.13.0, which depends on\n      " \
                             "rspec-mocks (~> 2.13.0)\n"]
    })

    record = step(app(lockfile: lockfile), machines: machines, runner: runner).run

    pins = record.stages.select { |stage| stage.stage == AgentsFyi::Upgrader::Record::PIN }

    assert_equal 2, pins.length, "the pin should have been asked again: #{pins.map(&:command)}"
    refute_includes pins.first.command, "rspec", pins.first.command
    assert_includes pins.last.command, "rspec ", "#{pins.last.command} (the requirer, not the conflict)"
    assert_includes pins.last.command, "rspec-mocks", pins.last.command
    assert pins.last.ok?, pins.last.output_tail
  end

  # **A requirer line carries its requirement, and the widening has to read through it.** Bundler
  # writes a requirer as `sinatra (>= 0.9.2) was resolved to 1.4.2`, and a pattern that expected the
  # name to be followed straight by " was resolved to" saw none of them: measured at the 5.0 rung,
  # the conflict on `rack` named `sinatra`, `rack-protection`, `vegas` and `warden` that way, the
  # widening extracted none, and the pin was asked once and failed on a `rack` four other gems could
  # have unlocked.
  def test_a_pin_unlocks_a_requirer_whose_line_carries_its_requirement
    lockfile = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          rack (1.6.13)
          rack-protection (1.5.0)
          rails (4.2.0)
            rack (~> 1.6.0)
          resque (1.24.1)
            sinatra (>= 0.9.2)
          sinatra (1.4.2)
            rack (>= 1.5.2, ~> 1.5)

      PLATFORMS
        ruby

      DEPENDENCIES
        rails (= 4.2.0)
        resque

      BUNDLED WITH
         1.17.3
    LOCK
    runner = FakeRunner.new(answers: {
      "sinatra" => [0, ""],
      "bundle update" => [6, "Resolving dependencies...\nBundler could not find compatible " \
                             "versions for gem \"rack\":\n  In Gemfile:\n    rails (= 4.2.0) was " \
                             "resolved to 4.2.0, which depends on\n      rack (~> 1.6.0)\n\n    " \
                             "resque was resolved to 1.24.1, which depends on\n      " \
                             "sinatra (>= 0.9.2) was resolved to 1.4.2, which depends on\n        " \
                             "rack (>= 1.5.2, ~> 1.5)\n"]
    })

    record = step(app(lockfile: lockfile), machines: machines, runner: runner).run

    pins = record.stages.select { |stage| stage.stage == AgentsFyi::Upgrader::Record::PIN }

    assert_equal 2, pins.length, "the pin should have been asked again: #{pins.map(&:command)}"
    assert_includes pins.last.command, "sinatra",
      "the requirer's own line carries a requirement the widening has to read through: #{pins.last.command}"
    assert pins.last.ok?, pins.last.output_tail
  end

  # **A requirer that merely *reaches* the conflict is not named, and that is measured rather than
  # tidy.** The message nests, and a gem three hops down is one that only touches the conflict:
  # measured at the 4.2 rung, `resque` appeared as a requirer of `rack` through `sinatra` and
  # `rack-protection`, naming it unlocked resque itself, and it resolved to 2.7.0 — a release that
  # needs Ruby 2.3 while the era's interpreter is 2.1, which bundler reports but does not resolve
  # around. The pin then failed on a gem the move never had to touch, and the same run with `rack`
  # named and resque left alone resolves. So the requirer is the name on the line whose *next* line
  # begins with the gem bundler could not place.
  def test_a_pin_does_not_unlock_a_requirer_that_only_reaches_the_conflict
    lockfile = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          rack (1.5.2)
          rails (4.2.0)
            rack (~> 1.6.0)
          resque (1.24.1)
            sinatra (>= 0.9.2)
          sinatra (1.4.2)
            rack-protection (~> 1.4)
          rack-protection (1.5.0)
            rack

      PLATFORMS
        ruby

      DEPENDENCIES
        rails (= 4.2.0)
        resque

      BUNDLED WITH
         2.5.22
    LOCK
    runner = FakeRunner.new(answers: {
      "bundle update" => [6, "Resolving dependencies...\nBundler could not find compatible " \
                             "versions for gem \"rack\":\n  In snapshot (Gemfile.lock):\n    " \
                             "rack (= 1.5.2)\n\n  In Gemfile:\n    rails (= 4.2.0) was " \
                             "resolved to 4.2.0, which depends on\n      rack (~> 1.6.0)\n\n    " \
                             "resque was resolved to 1.24.1, which depends on\n      " \
                             "sinatra (>= 0.9.2)\n"]
    })

    record = step(app(lockfile: lockfile), machines: machines, runner: runner).run

    pins = record.stages.select { |stage| stage.stage == AgentsFyi::Upgrader::Record::PIN }

    assert_equal 2, pins.length, "the pin should have been asked again: #{pins.map(&:command)}"
    assert_includes pins.last.command, "rack ", pins.last.command
    refute_includes pins.last.command, "resque",
      "#{pins.last.command} (resque only reaches the conflict through sinatra, and naming it " \
      "unlocks a release this Ruby cannot run)"
  end

  # **A declaration's requirement is a line the *lock* does not satisfy, and bundler names the gem
  # to unlock rather than answering with a version conflict.** Measured at the 4.2 rung: the
  # declarations stage adds `responders ~> 2.0` beside a 4.1 lock that does not hold responders at
  # all — devise 3.0.4 does not depend on it, and the resolve that arrives with 4.2 brings it in —
  # and the pin's first round, which names only the framework, exits 7 with "You have requested:
  # responders ~> 2.0 / The bundle currently has responders locked at 1.1.2. / Try running `bundle
  # update responders`". That name is *not* in the snapshot the step read, so the lockfile filter the
  # conflict names go through drops it; it is filtered out here only if it is missing from the
  # fixture, which is why this lockfile has no responders.
  def test_a_pin_unlocks_the_gem_a_declaration_adds_that_the_lock_does_not_satisfy
    lockfile = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          actionpack (4.1.0)
            activesupport (= 4.1.0)
          activesupport (4.1.0)
          rails (4.1.0)
            actionpack (= 4.1.0)
            railties (= 4.1.0)
          railties (4.1.0)

      PLATFORMS
        ruby

      DEPENDENCIES
        rails (= 4.1.0)

      BUNDLED WITH
         1.17.3
    LOCK
    gemfile = %(source "https://rubygems.org"\ngem "rails", "4.1.0"\n)
    corpus = FakeCorpus.new(migrations: [
      { "gem" => "responders", "kind" => "declared", "requirement" => "~> 2.0", "mechanical" => true,
        "when" => { "rails_at_least" => "4.2" },
        "note" => "the resolver picks a release that cannot sit beside the Rails being moved to",
        "source" => "the 4.2 rung's own `bundle update` output" }
    ])
    runner = FakeRunner.new(answers: {
      "responders" => [0, ""],
      "bundle update" => [7, "Fetching gem metadata from https://rubygems.org/...........\n" \
                             "You have requested:\n  responders ~> 2.0\n\n" \
                             "The bundle currently has responders locked at 1.1.2.\n" \
                             "Try running `bundle update responders`\n"]
    })
    dir = app(lockfile: lockfile, gemfile: gemfile)

    record = step(dir, machines: machines, runner: runner, corpus: corpus, to: "4.2.0").run

    pins = record.stages.select { |stage| stage.stage == AgentsFyi::Upgrader::Record::PIN }
    assert_operator pins.length, :>=, 2, "the pin should have been asked again: #{pins.map(&:command)}"
    refute_includes pins.first.command, "responders",
      "the first round names only the framework: #{pins.first.command}"
    assert_includes pins.last.command, "responders",
      "the gem bundler says to unlock was not named: #{pins.last.command}"
    assert pins.last.ok?, pins.last.output_tail
    assert_includes File.read(File.join(dir, "Gemfile")), %(gem "responders", "~> 2.0")
    assert_equal "passed", record.verdict, record.why
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
