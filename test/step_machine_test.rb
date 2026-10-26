# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "rbconfig"
require "stringio"
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
  ERAS = %w[2.1 2.2 2.5 2.7 3.1 3.2 3.3].freeze

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

  # A lockfile that holds a gem the application's suite brings in, so a step that moves that gem's line
  # has something in the snapshot to name.
  RSPEC_LOCK = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        rails (4.0.0.rc1)
        rspec-rails (2.14.2)

    PLATFORMS
      ruby

    DEPENDENCIES
      rails (= 4.0.0.rc1)
      rspec-rails (~> 2.14.0)
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
    def bundle_env(machine:) = { "BUNDLE_PATH" => File.join(@home, "bundles", "fixture", machine.era.to_s) }

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

    # The recall reads: empty, because these tests are about the machine and the brief has its own
    # suite. Present so the double is the interface rather than the part of it these tests use.
    def reports_upgrade(**) = { "changes" => [] }

    def search(**) = { "items" => [], "total" => 0 }

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

  # A plan that does not carry the change and a scan that locates its call site — the shape the 5.1
  # rung had for `assigns`/`assert_template`, whose bridge the rung that arrived at 5.0 had already
  # declared into the application's Gemfile.
  # A scan that locates `belongs_to` at two lines: one this tool's own rule has already answered with
  # `optional: true`, and one — a migration's column definition — the change never applied to.
  class BelongsToCorpus < FakeCorpus
    def scan(from:, to:, files:)
      { "edits" => [],
        "manual" => [
          { "subject" => "belongs_to", "path" => "app/models/item.rb", "line" => 2,
            "note" => "belongs_to validates presence by default from 5.0.", "kind" => "default_changed" },
          { "subject" => "belongs_to", "path" => "db/migrate/1_create_items.rb", "line" => 3,
            "note" => "belongs_to validates presence by default from 5.0.", "kind" => "default_changed" }
        ],
        "counts" => { "automatic" => 0, "manual" => 2 }, "next_step" => "two call sites" }
    end
  end

  class EarlierRungCorpus < FakeCorpus
    def scan(from:, to:, files:)
      { "edits" => [],
        "manual" => [{ "subject" => "assigns / assert_template", "path" => "spec/x_spec.rb", "line" => 3,
                       "note" => "`assigns` moved out of the framework", "kind" => "moved" }],
        "counts" => { "automatic" => 0, "manual" => 1 }, "next_step" => "one call site" }
    end
  end

  # A scan whose entries carry the rung that named them — which is what tells a call site this rung owns
  # from one an earlier rung left, and whether the application has since crossed that rung.
  class TwoRungCorpus < FakeCorpus
    def scan(from:, to:, files:)
      { "edits" => [],
        "manual" => [
          { "subject" => "render :text", "path" => "app/controllers/x.rb", "line" => 2, "step" => "3.2.0",
            "note" => "the deprecation from 4.1 has run out", "kind" => "removed" },
          { "subject" => "render :nothing", "path" => "app/controllers/x.rb", "line" => 3, "step" => "4.2.0",
            "note" => "the deprecation from 4.1 has run out", "kind" => "removed" }
        ],
        "counts" => { "automatic" => 0, "manual" => 2 }, "next_step" => "two call sites" }
    end
  end

  # A plan that carries a change whose fix is a bridge with a floor — the rung's own gem that cannot be
  # left unversioned.
  class BootsnapCorpus < FakeCorpus
    def upgrade(from:, to:)
      { "steps" => [{ "from_version" => from, "to_version" => to, "name" => "Rails #{to}",
                      "requires_ruby" => @requires_ruby, "note" => "",
                      "changes" => [{ "subject" => "bootsnap", "automatic" => false, "kind" => "moved",
                                      "note" => "this rung's app:update requires it in config/boot.rb" }] }],
        "next_step" => "one step" }
    end
  end

  # A scan that locates the change's own scaffold — the file its rule writes and deliberately does not
  # rewrite — beside a model line the same change is about.
  class ScaffoldCorpus < FakeCorpus
    def scan(from:, to:, files:)
      { "edits" => [],
        "manual" => [
          { "subject" => "ActiveRecord::Base as a model's superclass",
            "path" => "app/models/application_record.rb", "line" => 1,
            "note" => "the definition itself is the one `ActiveRecord::Base` that stays", "kind" => "moved" }
        ],
        "counts" => { "automatic" => 0, "manual" => 1 }, "next_step" => "one call site" }
    end
  end

  class FakeTests
    attr_reader :machines

    def initialize(results: nil)
      @results = results
      @machines = []
    end

    def detect(_root, declared: nil, stack: nil) = AgentsFyi::Upgrader::Tests::Suite.new(kind: :rspec, command: "bundle exec rspec")
    def no_suite_reason(_root, _stack = nil) = "no suite"

    def run(root, _suite, timeout:, env:, machine: nil, stack: nil)
      @machines << machine
      (@results&.shift || @results&.last) || green
    end

    def green
      AgentsFyi::Upgrader::Tests::Result.new(command: "bundle exec rspec", ran: true, passed: true,
        exit_code: 0, seconds: 0.1, output_tail: "3 examples", timed_out: false)
    end

    def machine_test_env(_stack = nil) = { "RAILS_ENV" => "test" }
  end

  # The shell, answering by substring. Every command a fake machine carries is prefixed with
  # its era, so "this era's bundle install fails" is one line of setup.
  class FakeRunner
    attr_reader :calls, :excerpts

    def initialize(answers: {})
      @answers = answers
      @calls = []
      @excerpts = []
    end

    def run(argv, stage:, chdir:, env: {}, stdin: nil, timeout: nil, excerpt_bytes: nil, display: nil)
      line = argv.join(" ")
      @calls << line
      @excerpts << [line, excerpt_bytes]
      exit_code, output = @answers.find { |needle, _| line.include?(needle) }&.last || [0, ""]
      Command.new(stage: stage, command: line, display: (display || argv).join(" "),
        ran: true, exit_code: exit_code, seconds: 0.0, output_tail: output.to_s)
    end
  end

  # A runner whose first `bundle install` cannot find the bundler the lock names, and whose second
  # succeeds — the only difference between the two calls is that a bundler was installed in between. The
  # answers cannot express that, because they match by substring, so the count is the state.
  class BundlerNamingRunner < FakeRunner
    def initialize
      super(answers: {})
      @installs = 0
    end

    def run(argv, stage:, chdir: nil, env: {}, stdin: nil, timeout: nil, excerpt_bytes: nil, display: nil)
      line = argv.join(" ")
      @calls << line
      if line.include?("bundle install")
        @installs += 1
        if @installs == 1
          return Command.new(stage: stage, command: line, display: (display || argv).join(" "),
            ran: true, exit_code: 1, seconds: 0.0,
            output_tail: "Could not find 'bundler' (1.17.3) required by your Gemfile.lock. " \
                         "To install the missing version, run `gem install bundler:1.17.3`")
        end
      end
      Command.new(stage: stage, command: line, display: (display || argv).join(" "),
        ran: true, exit_code: 0, seconds: 0.0, output_tail: "Bundle complete!")
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

    def run(argv, stage:, chdir: nil, env: {}, stdin: nil, timeout: nil, excerpt_bytes: nil, display: nil)
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

  # A digest entry the preflight leaves as a decision, for a line the application has already moved:
  # the shape the 5.0 rung's residue had, where `simple_form` was recorded as owing a move its Gemfile
  # already made.
  class SettledMoveCorpus < FakeCorpus
    ENTRY = {
      "gem" => "simple_form", "kind" => "replaced", "replacement" => "simple_form",
      "requirement" => "~> 3.1", "mechanical" => false,
      "note" => "the move belongs to the rung that takes Rails past 4.0.0",
      "source" => "index.rubygems.org", "when" => nil
    }.freeze

    def initialize
      super(migrations: [ENTRY])
    end

    def route(ruby:, rails:, lockfile:)
      super.merge(
        "gems" => [
          { "name" => "simple_form", "version" => "3.0.0.rc", "verdict" => "replace",
            "replacement" => "simple_form", "requirement" => "~> 3.1", "mechanical" => false,
            "note" => ENTRY["note"] }
        ],
        "counts" => { "keep" => 0, "move" => 0, "replace" => 1, "remove" => 0, "blocked" => 0,
                      "unknown" => 0 }
      )
    end
  end

  # A routing that answers `move` for a gem the Gemfile does not declare — the shape the 5.0 rung's
  # `rails-dom-testing 1.0.9` had, where the pin itself is what moved it.
  class UndeclaredMoveCorpus < FakeCorpus
    def route(ruby:, rails:, lockfile:)
      super.merge(
        "gems" => [
          { "name" => "rails-dom-testing", "version" => "1.0.9", "verdict" => "move", "to" => "2.1.1",
            "reason" => "requires activesupport < 5.0, which Rails 5.0.0 does not meet" }
        ],
        "counts" => { "keep" => 0, "move" => 1, "replace" => 0, "remove" => 0, "blocked" => 0,
                      "unknown" => 0 }
      )
    end
  end

  # A routing that answers for a gem whose own upgrade needs edits to the application's code — the
  # shape the 5.0 rung's rspec-rails move has.
  class CompanionCorpus < FakeCorpus
    def route(ruby:, rails:, lockfile:)
      super.merge(
        "gems" => [
          { "name" => "rspec-rails", "version" => "2.14.2", "verdict" => "replace",
            "replacement" => "rspec-rails", "requirement" => "~> 3.5.0", "mechanical" => false,
            "note" => "the gem's own code calls what Rails 5 removed" }
        ],
        "counts" => { "keep" => 0, "move" => 0, "replace" => 1, "remove" => 0, "blocked" => 0,
                      "unknown" => 0 }
      )
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

  # **A machine whose router answers from the fixture.** The real read runs `bin/rails runner`
  # inside the step's container; this answers the same JSON from this process, so the repair loop's
  # rounds are driven without a Rails application. Every other command stays the ordinary fake.
  class RouteMachine < FakeMachine
    def initialize(era, rows)
      super(era)
      @rows = rows
    end

    def command(argv, chdir:, env: {})
      return super unless argv.include?("runner")

      [[RbConfig.ruby, "-e", "print #{JSON.generate(@rows).inspect}"], {}]
    end
  end

  # A machine that can install a package, which is the container's one privilege: `apt` writes
  # outside the working copy, so it runs as root and everything else does not.
  class RootMachine < FakeMachine
    def root_command(argv, chdir:, env: {}) = [["fake-root", era, *argv], {}]
    def browser_cache = "/agents-fyi/home/browser/#{era}/webdrivers"
  end

  # **A machine that carries the environment the way a container does.** `Machine::Container#command`
  # hands the runner an empty env and puts each pair on `docker exec`'s command line as `-e`; a
  # double that dropped them would let the step stop passing the browser's cache without a red test.
  class EnvCarryingMachine < RootMachine
    def command(argv, chdir:, env: {})
      flags = env.flat_map { |name, value| ["-e", "#{name}=#{value}"] }
      [["fake", era, *argv, *flags], {}]
    end
  end

  # A queue that asks for a later release than the next rung: the plan still starts at the
  # rung, and the record must say so rather than the destination.
  class TwoStepCorpus < FakeCorpus
    def upgrade(from:, to:)
      { "steps" => [
        { "from_version" => from, "to_version" => "4.1.0", "name" => "Rails 4.1",
          "requires_ruby" => @requires_ruby, "changes" => [], "note" => "" },
        { "from_version" => "4.1.0", "to_version" => to, "name" => "Rails #{to}",
          "requires_ruby" => @requires_ruby, "changes" => [], "note" => "" }
      ], "next_step" => "two steps" }
    end
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

  def root_machines
    ERAS.to_h { |era| [era, RootMachine.new(era)] }
  end

  # The two view lines the 6.0 rung's real tree has, and the controller that says which instance
  # variable each route part arrives in.
  def write_bids(dir)
    FileUtils.mkdir_p(File.join(dir, "app", "views", "bids"))
    FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
    File.write(File.join(dir, "app", "views", "bids", "edit.html.erb"), <<~ERB)
      <h1>Editing bid</h1>

      <%= render 'form' %>

      <%= link_to 'Show', @bid %> |
      <%= link_to 'Back', bids_path %>
    ERB
    File.write(File.join(dir, "app", "controllers", "bids_controller.rb"), <<~RUBY)
      class BidsController < ApplicationController
        private

        def set_category = @category = Category.find_by_url(params[:category_id])
        def set_item = @item = Item.find(params[:item_id])
        def set_bid = @bid = Bid.find(params[:id])
      end
    RUBY
  end

  # A red suite in the formatter's own shape: the wrapper, the application frame, and the cause the
  # repair reads. This is the fixture's real block with the name and line the round is about.
  def failed_suite(line, source, message)
    text = <<~TEXT
      Failures:

        1) BidsController GET #edit responds with HTTP 200 status
           Failure/Error: #{source}

           ActionView::Template::Error:
             #{message}
           # ./app/views/bids/edit.html.erb:#{line}:in `_app_views_bids_edit_html_erb'
           # ------------------
           # --- Caused by: ---
           # NoMethodError:
           #   #{message}
           #   ./app/views/bids/edit.html.erb:#{line}:in `_app_views_bids_edit_html_erb'

    TEXT
    AgentsFyi::Upgrader::Tests::Result.new(command: "bundle exec rspec", ran: true, passed: false,
      exit_code: 1, seconds: 0.1, output_tail: text, timed_out: false)
  end

  def green_suite
    AgentsFyi::Upgrader::Tests::Result.new(command: "bundle exec rspec", ran: true, passed: true,
      exit_code: 0, seconds: 0.1, output_tail: "3 examples, 0 failures", timed_out: false)
  end

  def step(dir, machines:, runner: nil, tests: nil, corpus: nil, ledger: nil, runtime: "docker",
           to: "4.1.0", out: nil, project: nil)
    Step.new(
      repository: "acme/old", to: to, home: dir, out: out,
      source: FakeSource.new(dir), corpus: corpus || FakeCorpus.new,
      tests: tests || FakeTests.new, runner: runner || FakeRunner.new, ledger: ledger,
      runtime: runtime, machine_factory: ->(entry) { machines.fetch(entry.name) },
      project: project
    )
  end

  # **The repair repeats, because a template raises at its first bad line.** `bids/edit` has two
  # undeclared helpers: the first red suite names line 5, the repair writes it, and the next run
  # names line 6 — which a single-round version never saw, leaving the rung red with a repair it had
  # already derived. Both rounds are stages in the record and travel as one repair outcome, so the
  # corpus receives one report with both edits rather than two half-answers.
  def test_the_mechanical_repair_repeats_until_the_suite_is_green_and_reports_one_outcome
    dir = app
    write_bids(dir)
    rows = [
      { "name" => "category_item_bids", "controller" => "bids", "action" => "index",
        "parts" => %w[category_id item_id] },
      { "name" => "category_item_bid", "controller" => "bids", "action" => "show",
        "parts" => %w[category_id item_id id] }
    ]
    tests = FakeTests.new(results: [
      green_suite,
      failed_suite(5, "<%= link_to 'Show', @bid %> |", "undefined method `bid_path'"),
      failed_suite(6, "<%= link_to 'Back', bids_path %>", "undefined method `bids_path'"),
      green_suite
    ])
    record = step(dir, machines: ERAS.to_h { |era| [era, RouteMachine.new(era, rows)] },
      tests: tests).run

    assert_equal "passed", record.verdict, record.why
    assert_equal 2, record.stages.count { |stage| stage.stage == "repair" },
      "each round is a stage, or the record cannot say how the rung was reached"
    assert_equal 1, record.repairs.size
    assert_equal ["app/views/bids/edit.html.erb"], record.repairs.first.files
    edited = File.read(File.join(dir, "app", "views", "bids", "edit.html.erb"))
    assert_includes edited, "category_item_bid_path(@category, @item, @bid)"
    assert_includes edited, "category_item_bids_path(@category, @item)"
  end

  # **A 3.2 walk pins the 7.0 line, not its first release.** Rails 7.0.0's activesupport
  # cannot boot on Ruby 3.2; the 7.0 line's patches can, and a patch is the same rung.
  def test_the_7_0_rung_on_3_2_pins_the_line_rather_than_the_first_release
    dir = app
    runner = FakeRunner.new(answers: %w[2.1 2.2 2.5 2.7 3.1].to_h do |era|
      ["fake #{era} bundle install", [1, "not this era"]]
    end)
    record = step(dir, machines: machines, runner: runner, to: "7.0.0",
      corpus: FakeCorpus.new(requires_ruby: "2.7.0")).run

    assert_equal "passed", record.verdict, record.why
    assert_includes File.read(File.join(dir, "Gemfile")), %(gem "rails", "~> 7.0.0"),
      "the 7.0.0 pin on the 3.2 era is the release that cannot boot there"
  end

  # **The record is about the rung, not the walk's destination.** A queue target of 4.2 with
  # the plan's first step at 4.1 must record 4.1; naming the destination claims a skip.
  def test_a_walk_to_a_later_release_records_the_rung_it_ran
    corpus = TwoStepCorpus.new(requires_ruby: "1.9.3")
    record = step(app, machines: machines, to: "4.2.0", corpus: corpus).run

    assert_equal "4.1.0", record.to_version,
      "the record named the walk's destination rather than the rung it executed"
    assert_equal "passed", record.verdict, record.why
  end

  # The first era that installs the bundle is the one the step runs on: 2.1's attempt fails,
  # 2.2's succeeds, nothing after 2.2 is started — and both attempts are in the record, because
  # "which interpreter was tried and why it was rejected" is the answer to the question a
  # failed walk asks.
  # The declaration's `eras` reaches the selection and is the only list tried: a project that
  # names 3.2 must not start 2.1 because the rung's floor happens to allow it.
  def test_a_project_s_declared_eras_are_the_only_ones_started
    fleet = machines
    project = AgentsFyi::Upgrader::Project.new({
      "slug" => "p", "repo" => "acme/old", "from" => "4.0.0", "to" => "4.1.0",
      "eras" => ["3.2"], "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" }
    })
    record = step(app, machines: fleet, project: project).run

    assert_equal "passed", record.verdict, record.why
    assert_equal "3.2", record.era
    refute fleet["2.1"].started, "an era outside the declaration was started"
  end

  # A named era that cannot meet the rung's floor is refused by name rather than silently
  # walked on an era the operator did not choose.
  def test_a_declared_era_that_cannot_meet_the_floor_is_refused_by_name
    project = AgentsFyi::Upgrader::Project.new({
      "slug" => "p", "repo" => "acme/old", "from" => "4.2.0", "to" => "5.0.0",
      "eras" => ["2.1"], "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" }
    })
    lockfile = LOCKFILE.sub("4.0.0.rc1", "4.2.0")
    gemfile = GEMFILE.sub("4.0.0.rc1", "4.2.0")
    record = step(app(lockfile: lockfile, gemfile: gemfile), machines: machines, to: "5.0.0",
      project: project, corpus: FakeCorpus.new(requires_ruby: "2.2.2")).run

    assert_equal "unverified", record.verdict
    assert_includes record.why, "2.1"
  end

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
  # **A move the line already makes is not a decision.** The preflight records a non-mechanical digest
  # entry as a decision because it must not rewrite a line that can only move once Rails has; at the
  # rung where the move is made the line may already say it, and then the residue is asking a person
  # to make a move the tree has made. Measured on the lighthouse's 5.0 record, where `decide:
  # simple_form` sat beside `gem "simple_form", "~> 3.1"`.
  def test_a_move_the_line_already_makes_stops_being_a_decision
    gemfile = %(source "https://rubygems.org"\ngem "rails", "4.0.0.rc1"\ngem "simple_form", "~> 3.1"\n)
    dir = app(lockfile: LOCKFILE, gemfile: gemfile)

    record = step(dir, machines: machines, corpus: SettledMoveCorpus.new).run

    refute record.decisions.any? { |decision| decision.subject.to_s == "simple_form" },
      "the line already reads the move the routing asked for: " \
      "#{record.decisions.map(&:subject).inspect}"
  end

  # **The pin's first resolve names the gems this step has already moved.** Its rounds *are* the
  # widening, and a widening spends a round per conflict — so a gem the step has already decided to move
  # has to be named from the first round. Measured at the 5.0 rung: `guard-rspec 3.1.0` declares
  # `rspec ~> 2.13`, rspec-rails 3.5 needs `rspec-core ~> 3.5.0`, and the resolve named `rspec-core`,
  # `rspec` and `rspec-rails` over two rounds and never named `guard-rspec` — the line the routing had
  # already moved at that rung — so the pin failed with the move made. The bundle stage's fallback
  # already names exactly this set, and the two naming the same gems is the point.
  def test_the_pins_first_resolve_names_a_gem_this_step_moved
    gemfile = %(source "https://rubygems.org"\ngem "rails", "4.0.0.rc1"\ngem "rspec-rails", "~> 2.14.0"\n)
    dir = app(lockfile: RSPEC_LOCK, gemfile: gemfile)
    runner = FakeRunner.new

    step(dir, machines: machines, runner: runner, corpus: CompanionCorpus.new).run

    first = runner.calls.find { |call| call.include?("bundle update rails ") }
    assert first, "the pin's own resolve is not among the commands: #{runner.calls.grep(/bundle update/).inspect}"
    assert_includes first.split, "rspec-rails",
      "the first resolve did not name the line this step moved, so its rounds are spent on a conflict " \
      "this step already answered: #{first}"
  end

  # **A residue line the lock this step ended with already answers is not work.** The routing is asked
  # before the pin, against the lockfile the step starts with, so a gem the Rails move carries forward is
  # a `move` verdict this tool cannot apply — it is not declared, so the pin's own update is what moves
  # it — and it reaches the record as a decision at `Gemfile.lock`. Measured at the 5.0 rung:
  # `rails-dom-testing 1.0.9` was the record's one *located* decision beside a lock that ended at 2.1.1.
  def test_a_gem_the_lock_moved_is_not_a_decision
    lock = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          activesupport (4.0.0.rc1)
          rails (4.0.0.rc1)
          rails-dom-testing (1.0.9)
            activesupport (= 4.0.0.rc1)

      PLATFORMS
        ruby

      DEPENDENCIES
        rails (= 4.0.0.rc1)
    LOCK
    dir = app(lockfile: lock)
    runner = ResolvingRunner.new(bump: { "activesupport" => %w[4.0.0.rc1 5.0.0],
      "rails-dom-testing" => %w[1.0.9 2.1.1] })

    record = step(dir, machines: machines, runner: runner, corpus: UndeclaredMoveCorpus.new).run

    refute record.decisions.any? { |decision| decision.subject.to_s.start_with?("rails-dom-testing") },
      "the lock moved it and the residue still asks for it: " \
      "#{record.decisions.map(&:subject).inspect}"
  end

  # **A located line inside a rule's own scaffold is the change's own artifact, not work.** The
  # `ActiveRecord::Base` change writes `app/models/application_record.rb`, the definition has to keep
  # naming the base class, and the rule excludes that line by name — so the scan locates it on every rung
  # and both the 5.1 and the 5.2 residues carried it as a decision. The scaffold is what says the line is
  # not a person's work.
  def test_the_changes_own_scaffold_is_not_a_decision
    record = step(app, machines: machines, corpus: ScaffoldCorpus.new).run

    assert_empty record.decisions.select { |decision| decision.path.to_s.include?("application_record") },
      "the scaffold line came back as work: #{record.decisions.map(&:path).inspect}"
  end

  # **A lock names the bundler that wrote it, and an era may not ship it.** RubyGems activates the version
  # in `BUNDLED WITH`, so an era whose image pins a newer bundler cannot install the application at all —
  # measured on the 2.7 era at the 6.0 rung: `Could not find 'bundler' (1.17.3) required by your
  # Gemfile.lock. … To install the missing version, run gem install bundler:1.17.3`, while the same tree
  # installs on 2.5, whose image's *default* bundler is 1.17.3. The lock is the application's statement
  # about its toolchain, so the mechanism installs what it names — into the walker's home
  # (`--user-install`), because the container runs as the walker's uid — and retries once.
  def test_a_lock_naming_a_bundler_the_era_lacks_installs_it_and_retries
    runner = BundlerNamingRunner.new
    record = step(app, machines: machines, runner: runner).run

    installed = record.stages.find { |stage| stage.command.include?("gem install") }
    refute_nil installed, "the lock's bundler was not installed: #{record.stages.map(&:command).inspect}"
    assert_includes installed.command, "--user-install"
    assert_includes installed.command, "1.17.3"
    assert_equal 2, runner.calls.count { |call| call.include?("bundle install") },
      "the install is retried once, and only after the bundler was installed"
    assert_empty record.stages.select { |stage| stage.command.include?("gem install") && stage.exit_code != 0 },
      "the bundler arrives before the second attempt"
  end

  # **A resolver's output is evidence, and the record must not be a place its cause can hide.** Measured
  # twice at the 6.0 rung: every block a reader could see in the recorded output was satisfiable on its
  # own, and the block that failed the resolve had been dropped from the middle. So the commands that run
  # the resolver ask for `Shell::RESOLVER_BYTES` rather than the payload-sized default, and this says so.
  def test_the_resolver_commands_keep_the_whole_message
    runner = FakeRunner.new
    step(app, machines: machines, runner: runner, corpus: FakeCorpus.new).run

    resolvers = runner.excerpts.select do |call, _bytes|
      call.include?("bundle install") || call.include?("bundle update")
    end

    refute_empty resolvers, "the step ran no resolver: #{runner.calls.inspect}"
    assert(resolvers.all? { |_call, bytes| bytes == AgentsFyi::Upgrader::Shell::RESOLVER_BYTES },
      "a resolver's output was bound to the payload size: #{resolvers.inspect}")
  end

  # **A bridge that inserts a line writes the requirement it declares with onto it.** Measured at the 5.2
  # rung: the bootsnap bridge inserted `gem 'bootsnap'` with no requirement, the resolver took 1.10.3,
  # whose own `ruby (>= 2.3.0)` cannot sit on the 2.2 era, and the pin failed on `bootsnap was resolved to
  # 1.10.3, which depends on ruby (>= 2.3.0)`. A *floor* is a different thing and keeps its rule — nothing
  # is owed for a gem the application does not have (`require "spring"`'s floor is not an instruction to
  # install Spring) — which is why the insert reads `requirement` and not `floor`.
  def test_a_bridge_that_inserts_a_line_writes_its_requirement_onto_it
    record = step(app, machines: machines, corpus: BootsnapCorpus.new).run

    inserted = record.applied.find { |edit| edit.path.to_s == "Gemfile" }
    refute_nil inserted, "the bridge inserted nothing: #{record.applied.map(&:path).inspect}"
    assert_includes inserted.after.to_s, %(gem 'bootsnap', "= 1.4.5"),
      "the requirement did not reach the inserted line: #{inserted.after.inspect}"
  end

  # **A call site from a rung the application has crossed is not the same sentence as one it has not
  # reached.** Measured at the 5.1 rung, whose `protect_from_forgery` decision said "has not crossed"
  # about the rung that arrives at 5.0.0 — the version the tree *is* — so a call site carried unfixed
  # since read as one the application had never been asked about.
  def test_a_carried_call_site_says_whether_the_application_has_crossed_its_rung
    record = step(app, machines: machines, corpus: TwoRungCorpus.new).run

    reasons = record.decisions.to_h { |decision| [decision.subject.to_s, decision.reason.to_s] }
    assert_includes reasons["render :text"].to_s, "already crossed",
      "3.2.0 is below the application's own 4.0.0.rc1: #{reasons["render :text"].inspect}"
    assert_includes reasons["render :nothing"].to_s, "has not crossed",
      "4.2.0 is above it: #{reasons["render :nothing"].inspect}"
  end

  # **A line that already reads the new way is not work, and the *line* is what says so.** The 5.1
  # record's `belongs_to` residue is four model lines the 5.0 rung's own rule answered with
  # `optional: true` and four migration columns the change never applied to — one subject, two answers,
  # which is why the question is asked per located line rather than per subject.
  def test_a_located_line_that_already_reads_the_new_way_is_not_a_decision
    dir = app
    FileUtils.mkdir_p(File.join(dir, "app", "models"))
    File.write(File.join(dir, "app", "models", "item.rb"),
      "class Item < ApplicationRecord\n  belongs_to :user, optional: true\nend\n")
    FileUtils.mkdir_p(File.join(dir, "db", "migrate"))
    File.write(File.join(dir, "db", "migrate", "1_create_items.rb"),
      "class CreateItems < ActiveRecord::Migration\n  def change\n    t.belongs_to :user\n  end\nend\n")

    record = step(dir, machines: machines, corpus: BelongsToCorpus.new).run

    belongs_to = record.decisions.select { |decision| decision.subject.to_s == "belongs_to" }
    assert_equal ["db/migrate/1_create_items.rb"], belongs_to.map { |decision| decision.path },
      "the answered model line is not work and the migration column still is"
  end

  # **A bridge the Gemfile already carries answers its change, whatever rung the scan found the call
  # site at.** Measured at the 5.1 rung: the plan no longer names `assigns`/`assert_template` — the
  # rung that arrived at 5.0 declared `rails-controller-testing` for it — but the scan starts at the
  # ladder's `earliest`, so its 19 call sites came back as located decisions whose reason said they
  # were "still in its old form". Nothing about the line can say otherwise: the call site is
  # *supposed* to still read `assigns`, which is what the declaration is for.
  def test_a_bridge_the_gemfile_already_carries_answers_an_earlier_rungs_call_site
    gemfile = <<~GEMFILE
      source "https://rubygems.org"
      gem "rails", "4.0.0.rc1"

      group :test do
        gem "rails-controller-testing"
      end
    GEMFILE
    dir = app(gemfile: gemfile)

    record = step(dir, machines: machines, corpus: EarlierRungCorpus.new).run

    refute record.decisions.any? { |decision| decision.subject.to_s == "assigns / assert_template" },
      "the Gemfile declares the gem and the residue still asks: " \
      "#{record.decisions.map(&:subject).inspect}"
  end

  # The boundary, in the other direction: the same call site and the same plan, with a Gemfile that
  # does not declare the gem, is work — and it stays a decision.
  def test_a_bridge_the_gemfile_does_not_carry_is_still_a_decision
    dir = app

    record = step(dir, machines: machines, corpus: EarlierRungCorpus.new).run

    assert(record.decisions.any? { |decision| decision.subject.to_s == "assigns / assert_template" },
      "the gem is absent and the call site was dropped: #{record.decisions.map(&:subject).inspect}")
  end

  # **A gem's own upgrade is not finished when its Gemfile line is.** Measured at the 5.0 rung: the
  # rspec-rails 3 move alone took the lighthouse's suite from 47 failures to 133, because the gem
  # stopped inferring an example group's type and rspec 3 refuses a negated change matcher with a
  # delta. The move and the edits its own upgrade needs are one action, so the step makes both.
  def test_a_gem_move_applies_the_edits_its_own_upgrade_requires
    gemfile = %(source "https://rubygems.org"\ngem "rails", "4.0.0.rc1"\ngem "rspec-rails", "~> 2.14.0"\n)
    dir = app(lockfile: LOCKFILE, gemfile: gemfile)
    File.write(File.join(dir, "spec", "spec_helper.rb"), "RSpec.configure do |config|\nend\n")
    File.write(File.join(dir, "spec", "items_spec.rb"),
      "describe 'items' do\n  it 'adds' do\n    lambda { 1 }.should_not change(Item, :count).by(1)\n  end\nend\n")

    step(dir, machines: machines, corpus: CompanionCorpus.new).run

    assert_includes File.read(File.join(dir, "spec", "spec_helper.rb")),
      "config.infer_spec_type_from_file_location!",
      "the rung's failure is the gem's, and the move left the type inference unasked-for"
    refute_includes File.read(File.join(dir, "spec", "items_spec.rb")), ".by(1)",
      "rspec 3 refuses a negated change matcher with a delta"
  end

  # **A failed step prints the evidence, not only the command.** The summary quotes the command of the
  # stage that decided the verdict; the reason is in that stage's own output, and an operator who has to
  # re-run with `--record` to read it has been told a walk failed and not why — measured on the 5.1
  # rung, whose `bin/rails app:update` exit 1 was visible only as that command and an exit code.
  # Stages that are *expected* to fail (`bundle install` refusing a changed line, the pin's widening
  # rounds) are not printed: the stage is chosen by the verdict's own sentence, not by the first
  # non-zero exit.
  # **A verdict about the suite names no command, and the suite's output is the evidence.** Every
  # other failure sentence quotes the stage's own argv, which is how the stage is found; "the suite was
  # green before this step and failed after it" quotes none, so the reason a rung stopped was never
  # printed — measured at the 5.1 rung, whose suite exit 1 arrived as that sentence alone.
  def test_a_failed_suite_prints_its_own_output
    out = StringIO.new
    green = AgentsFyi::Upgrader::Tests::Result.new(command: "bundle exec rspec", ran: true, passed: true,
      exit_code: 0, seconds: 0.1, output_tail: "201 examples, 0 failures", timed_out: false)
    failed = AgentsFyi::Upgrader::Tests::Result.new(command: "bundle exec rspec", ran: true, passed: false,
      exit_code: 1, seconds: 0.2, output_tail: "Failure/Error: assigns(:item)\n  undefined method `assigns'",
      timed_out: false)
    tests = FakeTests.new(results: [green, failed])

    step(app, machines: machines, tests: tests, out: out).run

    assert_includes out.string, "undefined method `assigns'",
      "the suite's own output was not printed: #{out.string.lines.last(6).inspect}"
  end

  def test_a_failed_stage_prints_its_own_output
    out = StringIO.new
    runner = FakeRunner.new(answers: {
      "rails:update" => [1, "NoMethodError: undefined method `last_comment' for #<Rake::Application>"]
    })

    step(app, machines: machines, runner: runner, out: out).run

    assert_includes out.string, "undefined method `last_comment'",
      "the failure's own output was not printed: #{out.string.lines.last(6).inspect}"
  end

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

  # **A browser suite is answered by the machine, not by the application's tree.** The connect
  # wizard declares `chrome` for a suite that drives a browser, and the era container cannot run
  # Chromium's sandbox — its setuid helper builds a network and a PID namespace, which needs
  # `CAP_SYS_ADMIN`, a capability this walk will not grant a container that executes an untrusted
  # repository's bundle. The driver gem beside it asks an endpoint that retired the image's browser.
  # Both answers are the machine's: Debian's launcher reads `/etc/chromium.d`, and `webdrivers`
  # reads its cache from `WD_INSTALL_DIR`. Measured on `ohana-api` at the 5.2 rung: without them
  # every `:js` example died in `DevToolsActivePort`.
  def test_a_browser_application_gets_the_container_browser_without_an_edit_to_its_tree
    dir = app
    project = AgentsFyi::Upgrader::Project.new({
      "slug" => "p", "repo" => "acme/old", "from" => "4.0.0.rc1", "to" => "4.1.0",
      "toolchain" => { "chrome" => "pinned" }
    })
    runner = FakeRunner.new
    machines = ERAS.to_h { |era| [era, EnvCarryingMachine.new(era)] }

    record = step(dir, machines: machines, runner: runner, project: project).run

    browser = record.stages.select { |stage| stage.stage == AgentsFyi::Upgrader::Record::BROWSER }
    assert_equal 4, browser.length, "one command per browser fact: #{browser.map(&:command)}"
    # **The browser the image has is used, and one it has not is installed from the era's archive.**
    # A live release ships both pairs; an archived one ships none, and its frozen archive still
    # carries the package. The guard is a `test`, so the stage costs a command where nothing is due.
    install = browser.find { |stage| stage.command.include?("apt-get install") }
    refute_nil install, "a machine without a browser never offered to install the era's package"
    assert_includes install.command, "[ ! -x /usr/bin/chromium ]",
      "the install runs whether or not the image already has the browser"
    assert_includes install.command, "chromium chromium-driver"
    flags = browser.find { |stage| stage.command.include?("/etc/chromium.d/") }
    refute_nil flags, "the launcher was never told how to start in a container"
    assert_includes flags.command, "fake-root 2.1", "the drop-in was not written as root"
    assert_includes flags.command, "--no-sandbox"
    # The declaration says `pinned`, so the two names the suite and the driver gem read are
    # pointed at the image's verified build, and the versions are read back into the record.
    pin = browser.find { |stage| stage.command.include?("agents-fyi-browser") }
    refute_nil pin, "the pinned browser was never linked into the names the suite reads"
    assert_includes pin.command, "ln -sf /usr/local/bin/agents-fyi-browser /usr/bin/chromium",
      "the link does not point the browser name at the image's launcher"
    assert_includes pin.command, "[ -x /opt/agents-fyi-browser/chrome-linux64/chrome ]",
      "a machine without the pinned pair would be linked to nothing"
    assert_includes pin.command, "chromium --version"
    seed = browser.find { |stage| stage.command.include?("chromedriver.version") }
    refute_nil seed, "the driver the image installs was never offered to the gem"
    assert_includes seed.command, "/agents-fyi/home/browser/2.1/webdrivers"
    assert_includes seed.command, "chromedriver --version"

    # The cache is where the gem reads it, the era is part of its name, and the application's
    # own tree holds nothing.
    assert_includes runner.calls.join("\n"),
      "-e WD_INSTALL_DIR=/agents-fyi/home/browser/2.1/webdrivers",
      "no application command was told where the seeded driver is"
    assert_empty Dir.glob(File.join(dir, "**", "*agents_fyi*")),
      "the browser answer was written into the application's checkout"
  end

  # **A project whose test stack was written for the release's own browser says so.** The
  # declaration's `distro` keeps Debian's package and drops the pin, because the browser a suite can
  # drive is a fact about that suite — a machine-wide choice would measure every project on one.
  def test_a_project_that_declares_the_distribution_browser_is_not_pinned
    project = AgentsFyi::Upgrader::Project.new({
      "slug" => "p", "repo" => "acme/new", "from" => "7.1.6", "to" => "7.2.4",
      "toolchain" => { "chrome" => "distro" }
    })

    record = step(app, machines: root_machines, runner: FakeRunner.new, project: project).run

    browser = record.stages.select { |stage| stage.stage == AgentsFyi::Upgrader::Record::BROWSER }
    assert_equal 3, browser.length, "a distro project paid for a pin it refused: #{browser.map(&:command)}"
    refute(browser.any? { |stage| stage.command.include?("agents-fyi-browser") },
      "the distribution's browser was replaced for a project that asked for it")
  end

  # The browser stage is about the application's test stack, not about every walk: a project that
  # declares a header and nothing else must not pay for a browser it never asked for.
  def test_a_project_without_a_browser_gets_no_browser_stage
    project = AgentsFyi::Upgrader::Project.new({
      "slug" => "p", "repo" => "acme/old", "from" => "4.0.0.rc1", "to" => "4.1.0",
      "toolchain" => { "apt" => ["libidn11-dev"] }
    })

    record = step(app, machines: root_machines, runner: FakeRunner.new, project: project).run

    assert_empty record.stages.select { |stage| stage.stage == AgentsFyi::Upgrader::Record::BROWSER }
  end

  # **The application's own build declares its system packages, and the walk installs them before
  # the bundle.** Measured on diaspora at the 6.1→7.0 rung: its workflow installs `libidn11-dev`,
  # the era image had no `idn.h`, and `bundle install` died in `idn-ruby` — a rung reported
  # unverified for a header the repository had asked for all along.
  def test_the_declared_system_packages_are_installed_before_the_bundle
    project = AgentsFyi::Upgrader::Project.new({
      "slug" => "p", "repo" => "acme/old", "from" => "4.0.0.rc1", "to" => "4.1.0",
      "toolchain" => { "apt" => %w[libidn11-dev cmake] }
    })
    runner = FakeRunner.new

    record = step(app, machines: root_machines, runner: runner, project: project).run

    packages = record.stages.select { |stage| stage.stage == AgentsFyi::Upgrader::Record::PACKAGES }
    assert_equal 1, packages.length, "the packages stage ran once per started era: #{packages.length}"
    install = packages.first
    assert install.ok?, install.output_tail
    assert_includes install.command, "fake-root 2.1 sh -lc apt-get update"
    assert_includes install.command, "--no-install-recommends libidn11-dev cmake"
    before = record.stages.index(install)
    bundle = record.stages.index { |stage| stage.command.include?("bundle install") }
    assert_operator before, :<, bundle, "the bundle was tried before the packages it needs"
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
    write_database_config(dir)
    write_schema(dir, "db/schema.rb")
    runner = FakeRunner.new
    record = step(dir, machines: machines, runner: runner).run

    stages = record.stages.map(&:stage)
    assert_operator stages.index("database"), :<, stages.index("baseline")
    assert(runner.calls.any? { |call| call.include?("db:create db:test:prepare") })
  end

  # **A tree with no dump is built from its migrations.** `db:test:prepare` *loads* the schema
  # file, so an application that gitignores `db/schema.rb` answers "db/schema.rb doesn't exist yet.
  # Run `bin/rails db:migrate`" — which is what diaspora's `.gitignore` does, because one dump
  # cannot serve both MySQL and PostgreSQL. Its baseline then measured a database that was never
  # built, and the failure was filed against the move.
  def test_a_tree_that_keeps_its_schema_out_of_git_is_built_from_its_migrations
    dir = app
    write_database_config(dir)
    runner = FakeRunner.new
    step(dir, machines: machines, runner: runner).run

    calls = runner.calls.map { |call| Array(call).join(" ") }
    assert(calls.any? { |call| call.include?("db:create db:migrate") },
      "a tree with no schema dump was not migrated")
    refute(calls.any? { |call| call.include?("db:test:prepare") },
      "a tree with no schema dump was asked to load one")
  end

  # **A dump the working copy carries but git does not know is a previous attempt's.** A kept tree
  # is reset to its base commit between attempts and `git reset` leaves ignored files in place, so
  # the first attempt's `db:migrate` (under the pinned Rails) left a 7.0 `db/schema.rb` in a 6.1
  # tree — and the retry then failed to load it. The preparation asks the repository, not the debris.
  def test_a_schema_dump_a_previous_attempt_left_behind_is_not_the_repository_s
    dir = app
    write_database_config(dir)
    # Ignored, which is the whole of the case: a dump the repository ignores is one `git add --all`
    # (the preflight's checkpoint) will not stage, so it stays untracked while the tree is reused.
    File.write(File.join(dir, ".gitignore"), "db/schema.rb\n")
    FileUtils.mkdir_p(File.join(dir, "db"))
    File.write(File.join(dir, "db", "schema.rb"), "ActiveRecord::Schema[7.0].define\n")
    runner = FakeRunner.new
    step(dir, machines: machines, runner: runner).run

    calls = runner.calls.map { |call| Array(call).join(" ") }
    assert(calls.any? { |call| call.include?("db:create db:migrate") },
      "an untracked schema dump was taken for the repository's")
  end

  def write_database_config(dir)
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "database.yml"), "test:\n  adapter: postgresql\n")
  end

  # Committed, because the rule reads the *repository's* schema: a dump the working copy carries
  # but git does not know is what a previous attempt's `db:migrate` left behind.
  def write_schema(dir, path)
    FileUtils.mkdir_p(File.join(dir, File.dirname(path)))
    File.write(File.join(dir, path), "ActiveRecord::Schema.define\n")
    system("git", "-C", dir, "add", "--all", out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "-c", "user.email=t@example.com", "-c", "user.name=t",
      "commit", "--quiet", "-m", "schema", out: File::NULL, err: File::NULL)
  end

  # **The other half of the version rule, and the reason it is a rule rather than a file
  # check.** `rails db:create` and `rails app:update` arrived in Rails 5.0; on 4.x both are
  # rake tasks. The first real walk's application carries a `bin/rails` binstub *and* runs
  # 4.0.0.rc1, so "does bin/rails exist" answers the wrong question — and the wrong answer
  # leaves the suite with no database and the record with a command-not-found.
  def test_a_rails_five_application_runs_both_moved_commands_through_bin_rails
    dir = app(lockfile: LOCKFILE.sub("4.0.0.rc1", "5.2.8"), gemfile: GEMFILE.sub("4.0.0.rc1", "5.2.8"))
    write_database_config(dir)
    write_schema(dir, "db/schema.rb")
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
  # **A move settled on an era this rung would no longer get is re-opened, because the era is the
  # oldest the floor allows and the ledger is not a starting point.** The ledger is keyed per
  # repository, so a walk re-entered from below inherits the era of the rungs above it — measured, the
  # 6.0 rung (floor 2.5) came to run on 2.7 and was `unverified` on a red baseline, because the
  # entries scoped `ruby_at_least 2.7` are read against the rung's floor and so did not apply. This is
  # the assertion that separates the two rules: with the ledger's era preferred, the stamp matches and
  # the move stays settled; with the floor's era, it does not and the move is walked again.
  def test_a_settled_move_on_an_era_the_rung_would_not_get_is_re_opened
    dir = app
    ledger = AgentsFyi::Upgrader::Ledger.new(path: File.join(dir, "ledger.json"), machine: "ruby 3.3.12")
    ledger.record(repo: "acme/old", commit: "abc12345", from_version: "4.0.0.rc1",
      to_version: "4.1.0", verdict: "passed",
      machine: "ruby 2.2 (era-2.2@sha256:#{"f" * 64})", era: "2.2")

    fleet = machines
    record = step(dir, machines: fleet, ledger: ledger).run

    assert_equal "passed", record.verdict,
      "a move settled on 2.2 was not walked again on the era its floor actually allows"
  end

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
