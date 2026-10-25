# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "agents_fyi/upgrader"

# The command, driven without a network, a git repository or a real service: the
# three exit codes are a contract a caller reads, so they are asserted rather than
# assumed.
class CliTest < Minitest::Test
  # A record that says one thing: nothing was established.
  class UnverifiedRecord
    def refused? = false
    def failed? = false
    def unverified? = true
  end

  LOCK = <<~LOCK
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

  PAYLOAD = {
    "from_version" => "4.2.11",
    "to_version" => "5.0.0",
    "documented" => 1,
    "observed" => 0,
    "unplaced" => 0,
    "truncated" => false,
    "guide" => "https://guides.rubyonrails.org/upgrading_ruby_on_rails.html",
    "next_step" => "1 step(s) from 4.2.0 to 5.0.0.",
    "steps" => [
      {
        "from_version" => "4.2.0",
        "to_version" => "5.0.0",
        "name" => "Rails 5.0",
        "requires_ruby" => "2.2.2",
        "guidance" => "Change the Rails version to 5.0.0 in the Gemfile and run `bundle update rails`.",
        "note" => "",
        "counts" => { "documented" => 1 },
        "observed" => [],
        "observed_unclassified" => 0,
        "changes" => [
          {
            "subject" => "before_filter", "kind" => "renamed", "replacement" => "before_action",
            "removed_in" => "5.1.0", "automatic" => true, "findable" => true,
            "enforced_in_your_move" => false, "note" => "", "source" => "5.0, controller filters"
          }
        ]
      }
    ]
  }.freeze

  # A corpus client that answers from a value or raises a given error, so a test can
  # drive a refusal and an outage through the same path a real response takes.
  class StubCorpus
    attr_reader :upgrades, :ladder_reads

    def initialize(payload: nil, error: nil, migrations: [], top: "8.1.0")
      @payload = payload
      @error = error
      @migrations = migrations
      @top = top
      @upgrades = []
      @ladder_reads = 0
    end

    def upgrade(from:, to:)
      raise @error if @error

      @upgrades << [from, to]
      @payload
    end

    def ladder
      raise @error if @error

      @ladder_reads += 1
      @top.nil? ? {} : { "top" => @top }
    end

    def route(ruby:, rails:, lockfile:)
      { "ruby" => ruby, "rails" => rails, "gems_read" => 0,
        "counts" => { "keep" => 0, "move" => 0, "replace" => 0, "remove" => 0, "blocked" => 0,
                      "unknown" => 0 },
        "gems" => [], "stored" => false, "next_step" => "every pin is recorded" }
    end

    def gem_migrations(gems:)
      { "migrations" => @migrations.select { |migration| gems.include?(migration["gem"]) },
        "counts" => { "selected" => 0, "total" => @migrations.size }, "stored" => false,
        "next_step" => "the digest's own sentence" }
    end

    # The decision surface, as a fake: the CLI test is about dispatch and exit status,
    # and `corpus_test.rb` owns the route and body of each call.
    attr_reader :decision_queries

    def decisions(**params)
      @decision_queries = params
      { "decisions" => [{ "id" => "q-1", "subject" => "a stop" }], "count" => 1 }
    end

    def decision(id) = { "id" => id, "answers" => [] }

    def propose_decision(id, payload)
      { "id" => id, "proposed_answer" => "a-1", "payload" => payload }
    end

    def withdraw_decision(id, answer_id)
      { "id" => id, "withdrawn_answer" => answer_id }
    end

    def resolution(project_id, from: nil, to: nil)
      { "project" => project_id, "from_version" => from, "to_version" => to, "changes" => [] }
    end
  end

  def run_cli(argv, corpus: nil, inspector: nil)
    out = StringIO.new
    err = StringIO.new
    code = AgentsFyi::Upgrader::CLI.new(argv, out: out, err: err, env: {}, corpus: corpus,
      inspector: inspector || Open3).run
    [code, out.string, err.string]
  end

  # What `docker ps` answers a reaping, so the suite never asks a real daemon.
  class StubInspector
    attr_reader :calls

    def initialize(listing: "")
      @listing = listing
      @calls = []
    end

    def capture2e(*argv)
      @calls << argv.join(" ")
      [@listing, nil]
    end
  end

  def repository
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), LOCK)
      yield dir
    end
  end

  # **A stored record is enough to review a rung.** `preview` renders the same body a pull request
  # would carry, with no service, no checkout and no token — the dry-run seam over the record.
  def test_preview_renders_a_stored_record_without_a_service_or_a_repository
    Dir.mktmpdir do |dir|
      path = File.join(dir, "run.json")
      File.write(path, JSON.generate(
        "repository" => "https://github.com/acme/storefront", "commit" => "abc12345",
        "from_version" => "5.2.0", "to_version" => "6.0.0", "verdict" => "passed",
        "why" => "the suite was green before this step and green after it",
        "interpreter" => "ruby 3.3.12",
        "stages" => [
          { "stage" => "baseline", "command" => "bundle exec rspec", "ran" => true,
            "exit_code" => 0, "seconds" => 1.0, "output_tail" => "ok" },
          { "stage" => "suite", "command" => "bundle exec rspec", "ran" => true,
            "exit_code" => 0, "seconds" => 1.0, "output_tail" => "ok" }
        ],
        "checks" => [{ "id" => "lint", "kind" => "lint", "command" => "bundle exec rubocop",
                       "required" => true, "external" => false, "status" => "passed",
                       "ran" => true, "exit_code" => 0, "seconds" => 0.5 }]
      ))

      code, out, err = run_cli(["preview", "--from", path, "--base-ref", "main"])

      assert_equal 0, code, err
      assert_includes out, "## What moved"
      assert_includes out, "5.2.0 → 6.0.0"
      assert_includes out, "## Checks"
      assert_includes out, "bundle exec rubocop"
      assert_includes out, "## Review and merge"
    end
  end

  def test_preview_refuses_a_record_it_cannot_read
    code, _out, err = run_cli(["preview", "--from", "/no/such/record.json"])
    assert_equal 1, code
    assert_includes err, "could not be read"

    code, _out, err = run_cli(["preview", "--from", "/tmp"])
    assert_equal 1, code
    assert_includes err, "could not be read"
  end

  # **A killed run leaves its container running, and `prune` is the look that removes it.**
  # `--rm` ends a container whose own process exits; this one never does, so the owner's pid
  # travels on the container and this pass removes only the ones whose owner is gone.
  def test_prune_reaps_the_containers_a_killed_run_left_running
    gone = Process.spawn("true")
    Process.wait(gone)
    listing = "eee555\tagentsfyi-step-20261017193851-#{gone}-2-1\t\n"
    inspector = StubInspector.new(listing: listing)

    Dir.mktmpdir do |home|
      code, out, err = run_cli(["prune", "--home", home], inspector: inspector)

      assert_equal AgentsFyi::Upgrader::CLI::EXIT_OK, code, err
      assert_includes inspector.calls, "docker rm --force eee555"
      assert_includes out, "reaped 1 step container"
    end
  end

  # The bundle half of the same pass: a run that is over left a gemset nothing will ask for
  # again, and it is the bind mount every step's container is given.
  def test_prune_also_removes_the_bundle_a_finished_run_left
    gone = Process.spawn("true")
    Process.wait(gone)
    Dir.mktmpdir do |home|
      root = File.join(home, "work", "abc123", "run-20261017203314-#{gone}")
      FileUtils.mkdir_p(root)
      bundle = File.join(home, "bundles", Digest::SHA256.hexdigest(root)[0, 16])
      FileUtils.mkdir_p(bundle)

      code, out, err = run_cli(["prune", "--home", home], inspector: StubInspector.new)

      assert_equal AgentsFyi::Upgrader::CLI::EXIT_OK, code, err
      refute File.exist?(bundle)
      assert_includes out, "pruned 1 bundle"
    end
  end

  def test_prune_with_nothing_to_do_says_so_rather_than_printing_an_empty_list
    Dir.mktmpdir do |home|
      code, out, _err = run_cli(["prune", "--home", home], inspector: StubInspector.new)

      assert_equal AgentsFyi::Upgrader::CLI::EXIT_OK, code
      assert_includes out, "nothing to prune"
    end
  end

  # The tool keeps no copy of the ladder, so a caller that did not name a target is given
  # the service's own top rather than a guess about Rails' release order. Two reads, and
  # the second is the one that matters: the plan was asked for *to the top the ladder
  # published*, which is the only way "to what?" can be answered without a second copy of
  # the ladder living in this tool.
  def test_a_missing_target_asks_the_service_where_its_ladder_tops_out
    repository do |dir|
      corpus = StubCorpus.new(payload: PAYLOAD, top: "8.1.0")
      code, out, err = run_cli(["plan", "--repo", dir, "--api", "https://example.test"],
        corpus: corpus)

      assert_equal AgentsFyi::Upgrader::CLI::EXIT_OK, code, err
      assert_equal 1, corpus.ladder_reads
      assert_equal [["4.2.11", "8.1.0"]], corpus.upgrades
      assert_includes out, "on Rails 4.2.11, read from `rails` in Gemfile.lock"
    end
  end

  # A ladder read that cannot be made is an outage, not a licence to guess — the tool has
  # nothing to plan to and says so with the service's own sentence.
  def test_a_ladder_that_cannot_be_read_is_an_outage_rather_than_a_guess
    repository do |dir|
      outage = AgentsFyi::Upgrader::Corpus::Unreachable.new("could not reach https://example.test: reset")
      code, _out, err = run_cli(["plan", "--repo", dir, "--api", "https://example.test"],
        corpus: StubCorpus.new(error: outage))

      assert_equal AgentsFyi::Upgrader::CLI::EXIT_FAILED, code
      assert_includes err, "could not reach"
    end
  end

  # A ladder read that answers without a top is answered as the outage it is: planning to
  # an empty target would ask the service for a move to nowhere and report whatever came
  # back as the answer.
  def test_a_ladder_read_without_a_top_is_refused_rather_than_planned_to_nowhere
    repository do |dir|
      code, _out, err = run_cli(["plan", "--repo", dir, "--api", "https://example.test"],
        corpus: StubCorpus.new(payload: PAYLOAD, top: nil))

      assert_equal AgentsFyi::Upgrader::CLI::EXIT_FAILED, code
      assert_includes err, "carried no `top`"
    end
  end

  def test_a_move_the_service_refuses_exits_two_carrying_its_own_sentence
    repository do |dir|
      refusal = AgentsFyi::Upgrader::Corpus::Refused.new(
        "This reads forward upgrades: `5.1.0` is ahead of `4.2.11`."
      )
      code, _out, err = run_cli(
        ["plan", "--repo", dir, "--to", "4.2.11", "--api", "https://example.test"],
        corpus: StubCorpus.new(error: refusal)
      )

      assert_equal AgentsFyi::Upgrader::CLI::EXIT_REFUSED, code
      assert_includes err, "reads forward upgrades"
    end
  end

  def test_a_service_that_cannot_be_reached_exits_one
    repository do |dir|
      outage = AgentsFyi::Upgrader::Corpus::Unreachable.new("could not reach https://example.test: reset")
      code, _out, err = run_cli(
        ["plan", "--repo", dir, "--to", "5.0.0", "--api", "https://example.test"],
        corpus: StubCorpus.new(error: outage)
      )

      assert_equal AgentsFyi::Upgrader::CLI::EXIT_FAILED, code
      assert_includes err, "failed:"
    end
  end

  def test_a_repository_with_no_lockfile_cannot_be_planned
    Dir.mktmpdir do |dir|
      code, _out, err = run_cli(["plan", "--repo", dir, "--to", "5.0.0", "--api", "https://example.test"])

      assert_equal AgentsFyi::Upgrader::CLI::EXIT_FAILED, code
      assert_includes err, "no Gemfile.lock"
    end
  end

  def test_a_path_that_is_neither_a_directory_nor_a_url_is_a_failure_not_a_clone_attempt
    code, _out, err = run_cli(
      ["plan", "--repo", "/nonexistent/application", "--to", "5.0.0", "--api", "https://example.test"]
    )

    assert_equal AgentsFyi::Upgrader::CLI::EXIT_FAILED, code
    assert_includes err, "no such directory"
  end

  def test_a_plan_is_printed_and_the_source_is_left_alone
    repository do |dir|
      code, out, err = run_cli(
        ["plan", "--repo", dir, "--to", "5.0.0", "--api", "https://example.test"],
        corpus: StubCorpus.new(payload: PAYLOAD)
      )

      assert_equal AgentsFyi::Upgrader::CLI::EXIT_OK, code, err
      assert_includes out, "on Rails 4.2.11, read from `rails` in Gemfile.lock"
      assert_includes out, "1 documented change(s): 1 a machine can apply, 0 need a decision"
      assert_includes out, "nothing was written to"
    end
  end

  # The first argument is shifted as the command before OptionParser can see it, so a
  # bare `--help` was refused as a mode named `--help` — while `plan --help` printed the
  # usage, which is why only the form CI invokes was the one that broke.
  def test_a_bare_help_flag_prints_the_usage_rather_than_naming_an_unknown_mode
    code, out, err = run_cli(["--help"])

    assert_equal AgentsFyi::Upgrader::CLI::EXIT_OK, code, err
    assert_includes out, "Usage:"
    assert_includes out, "agents-fyi-upgrader plan"
    assert_empty err
  end

  def test_a_bare_version_flag_prints_the_client_version
    code, out, err = run_cli(["--version"])

    assert_equal AgentsFyi::Upgrader::CLI::EXIT_OK, code, err
    assert_equal "#{AgentsFyi::Upgrader::VERSION}\n", out
    assert_empty err
  end

  # The preflight mode: a mode of its own because it is the half of a walk that cannot be
  # established by installing anything. Two assertions carry it — the caller's tree is
  # still byte-for-byte what it was (the repair happens in a copy this tool owns), and the
  # record written beside it names both repairs: the protocol, which needs no digest, and
  # the digest's own move for the dead fork.
  def test_preflight_repairs_a_copy_and_says_what_it_did_without_touching_the_source
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      repo = File.join(dir, "app")
      FileUtils.mkdir_p(repo)
      File.write(File.join(repo, "Gemfile"), <<~GEM)
        source "https://rubygems.org"
        gem "rails", "4.0.0.rc1"
        gem "cancan", git: "git://github.com/moriz/cancan.git"
      GEM
      File.write(File.join(repo, "Gemfile.lock"),
        "GEM\n  remote: git://github.com/moriz/cancan.git\n  specs:\n    cancan (1.6.10)\n")
      system("git", "init", "--quiet", repo, out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "add", "--all", out: File::NULL, err: File::NULL)
      system("git", "-C", repo, "-c", "user.email=t@example.com", "-c", "user.name=t",
        "commit", "--quiet", "-m", "fixture", out: File::NULL, err: File::NULL)
      original = File.read(File.join(repo, "Gemfile"))
      corpus = StubCorpus.new(migrations: [
        { "gem" => "cancan", "kind" => "replaced", "replacement" => "cancancan",
          "requirement" => "~> 1.9", "mechanical" => true,
          "note" => "the fork is gone", "source" => "the index" }
      ])
      record = File.join(dir, "record")

      code, out, err = run_cli(["preflight", "--repo", repo, "--home", home, "--record", record],
        corpus: corpus)

      assert_equal 0, code, err
      assert_includes out, "preflight: 3 repair(s)"
      assert_equal original, File.read(File.join(repo, "Gemfile")), "the caller's tree was written to"
      written = JSON.parse(File.read(File.join(record, "preflight.json")))
      assert_equal %w[Gemfile Gemfile Gemfile.lock], written["repairs"].map { |repair| repair["path"] }.sort
      assert_includes written["repairs"].map { |repair| repair["after"] }.join,
        %(gem "cancancan", "~> 1.9")
    end
  end

  # **Every flag the usage text names is a flag the parser has.** `--walk`, `--rungs`,
  # `--cycles` and `--force` were documented — and two of them are passed by the deployment's
  # own entrypoint — while `parse` had no option for any of them, so `serve --walk` silently
  # meant "no walk" and a bounded run never bounded. The deploy test compares the entrypoint
  # against the *text*, which is exactly how the two agreed while the parser did not; this is
  # the direction that catches a flag written and never read.
  def test_every_flag_the_usage_text_names_parses
    flags = AgentsFyi::Upgrader::CLI::USAGE.scan(/--[a-z-]+/).uniq
    assert_operator flags.length, :>, 5, "the usage text names no flags"

    valued = %w[--repo --ref --to --api --project --record --from --base-ref --report-base
                --work --home --heartbeat --interval --step-timeout --cycles --rungs --repos
                --suite-env --id --state --block-kind --change-key --limit --effects --choice
                --proposed-by --answer-id]
    flags.each do |flag|
      argv = ["serve", flag]
      argv << "1" if valued.include?(flag)
      cli = AgentsFyi::Upgrader::CLI.new(argv, out: StringIO.new, err: StringIO.new, env: {})
      options = cli.send(:parse)

      assert_nil options[:error], "#{flag} is in the usage text and not in the parser: " \
                                  "#{options[:error]}"
    end
  end

  # And the flag an operator reaches for when the ledger says no. The ledger is a memory
  # rather than a lock: `--force` sets a settled move aside, and the record says so.
  def test_force_is_the_operators_override_of_the_ledger
    options = AgentsFyi::Upgrader::CLI.new(["step", "--repo", ".", "--force"],
      out: StringIO.new, err: StringIO.new, env: {}).send(:parse)

    assert_equal true, options[:force]
  end

  # **A decision read is a mode, not a second binary.** The subcommand and its id are taken
  # from the leftover arguments, and `--state` reaches the queue read; a proposal is the only
  # write here, because acceptance stays a person's act.
  def test_decisions_list_reads_the_operator_surface_with_its_filters
    corpus = StubCorpus.new
    code, out, err = run_cli(["decisions", "list", "--api", "https://example.test",
      "--project", "storefront", "--state", "open", "--limit", "5"], corpus: corpus)

    assert_equal 0, code, err
    assert_equal({ project: "storefront", state: "open", block_kind: nil,
                   change_key: nil, limit: 5 }, corpus.decision_queries)
    assert_includes out, "q-1"
  end

  def test_decisions_withdraw_names_the_proposal_rather_than_accepting_it
    corpus = StubCorpus.new
    code, out, err = run_cli(["decisions", "withdraw", "q-1", "--api", "https://example.test",
      "--answer-id", "a-1"], corpus: corpus)

    assert_equal 0, code, err
    assert_includes out, "withdrawn_answer"
  end

  def test_an_unknown_command_says_which_modes_exist
    code, _out, err = run_cli(["upgrade", "--repo", "."])

    assert_equal AgentsFyi::Upgrader::CLI::EXIT_REFUSED, code
    assert_includes err, "unknown command `upgrade`"
    assert_includes err, "`step`"
  end

  # **The process environment reaches the step**, and this is a fix rather than a detail. A `step` built
  # without it read every knob the step owns as *absent* — so `UPGRADER_COMMAND_TIMEOUT=120` gave the
  # fifteen-minute default, which is how it was found: a walk asked for two minutes and sat in
  # `bundle update` for ten. The seam is a class rather than the real one, so the suite asserts what
  # *would* be built rather than walking anything.
  def test_the_cli_gives_the_step_the_environment_it_was_started_with
    built = nil
    fake = Class.new do
      define_method(:initialize) { |**kwargs| built = kwargs }
      define_method(:run) { nil }
    end

    status = AgentsFyi::Upgrader::CLI.new(["step", "--repo", "https://example.invalid/app", "--to", "5.0.0",
      "--api", "https://example.invalid"], out: StringIO.new,
      env: { "UPGRADER_COMMAND_TIMEOUT" => "120" }, step_class: fake).run

    assert_equal 0, status
    refute_nil built, "the step was built"
    assert_equal({ "UPGRADER_COMMAND_TIMEOUT" => "120" }, built[:env])
  end

  # **A declaration supplies the defaults, and a flag still wins.** The repository, the ref the walk
  # starts from and the release it moves to are properties of the application, so an operator naming
  # a project should not have to repeat them — and "walk this project from *this* ref" is said by
  # naming one flag beside it.
  def test_a_named_project_supplies_the_repository_the_ref_and_the_target
    cli = AgentsFyi::Upgrader::CLI.new(["serve"], out: StringIO.new, err: StringIO.new, env: {})
    cli.instance_variable_set(:@project, AgentsFyi::Upgrader::Project.find("lighthouse"))

    options = { repo: nil, ref: nil, to: nil }
    cli.send(:apply_project, options)

    assert_equal "https://github.com/shoutsid/biddingapp.git", options[:repo],
      "a declaration's owner/name is the clone URL every command uses"
    assert_equal "agents-fyi/baseline", options[:ref]
    assert_equal "8.1.0", options[:to]
  end

  def test_a_flag_beside_a_project_overrides_what_the_declaration_says
    cli = AgentsFyi::Upgrader::CLI.new(["serve"], out: StringIO.new, err: StringIO.new, env: {})
    cli.instance_variable_set(:@project, AgentsFyi::Upgrader::Project.find("lighthouse"))

    options = { repo: "https://github.com/acme/other.git", ref: "main", to: "7.1.0" }
    cli.send(:apply_project, options)

    assert_equal "https://github.com/acme/other.git", options[:repo]
    assert_equal "main", options[:ref]
    assert_equal "7.1.0", options[:to]
  end

  # A declaration that cannot be read is a refusal at the door rather than a walk measured against
  # half a project: the operator named a declaration and there is no application behind it.
  def test_an_unusable_declaration_is_refused_before_any_mode_runs
    err = StringIO.new
    status = AgentsFyi::Upgrader::CLI.new(["prune", "--project", "no-such-project"],
      out: StringIO.new, err: err, env: {}).run

    assert_equal AgentsFyi::Upgrader::CLI::EXIT_REFUSED, status
    assert_includes err.string, "the project declaration is not usable"
    assert_includes err.string, "no-such-project"
  end

  # **There is no default service.** A walker pointed at no service must say so rather than talk to
  # whatever deployment its author happened to run: the answers a step records are only meaningful
  # against the corpus the caller chose. This was measured — the engine carried the author's host as
  # `DEFAULT_API`, so `test/engine_facts_test.rb` read one application's fact out of the engine.
  def test_a_mode_that_needs_the_service_refuses_when_none_is_named
    err = StringIO.new
    status = AgentsFyi::Upgrader::CLI.new(["plan", "--repo", "https://example.invalid/app"],
      out: StringIO.new, err: err, env: {}).run

    assert_equal AgentsFyi::Upgrader::CLI::EXIT_REFUSED, status
    assert_includes err.string, "needs the service"
    assert_includes err.string, "--api"
    assert_includes err.string, "AGENTS_FYI_URL"
  end

  # **An unverified step is not a plan.** Nothing was established — no interpreter installed the bundle, say —
  # and a caller that reads that as success has been told the wrong thing. A real walk found it: an
  # interpreter that could not reach github failed for every era and the step exited 0.
  def test_an_unverified_step_exits_as_a_failure_rather_than_as_a_plan
    fake = Class.new do
      define_method(:initialize) { |**| }
      define_method(:run) { UnverifiedRecord.new }
    end

    status = AgentsFyi::Upgrader::CLI.new(["step", "--repo", "https://example.invalid/app", "--to", "5.0.0",
      "--api", "https://example.invalid"], out: StringIO.new, env: {}, step_class: fake).run

    assert_equal AgentsFyi::Upgrader::CLI::EXIT_FAILED, status
  end
end
