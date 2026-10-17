# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "agents_fyi/upgrader"

# The command, driven without a network, a git repository or a real service: the
# three exit codes are a contract a caller reads, so they are asserted rather than
# assumed.
class CliTest < Minitest::Test
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
    def initialize(payload: nil, error: nil)
      @payload = payload
      @error = error
    end

    def upgrade(from:, to:)
      raise @error if @error

      @payload
    end
  end

  def run_cli(argv, corpus: nil)
    out = StringIO.new
    err = StringIO.new
    code = AgentsFyi::Upgrader::CLI.new(argv, out: out, err: err, env: {}, corpus: corpus).run
    [code, out.string, err.string]
  end

  def repository
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), LOCK)
      yield dir
    end
  end

  # The tool keeps no copy of the ladder, so it cannot know what follows 4.2 without
  # asking — and guessing is the one thing it must not do.
  def test_a_missing_target_is_refused_rather_than_guessed
    repository do |dir|
      code, _out, err = run_cli(["plan", "--repo", dir, "--api", "https://example.test"])

      assert_equal AgentsFyi::Upgrader::CLI::EXIT_REFUSED, code
      assert_includes err, "will not guess a target"
      assert_includes err, "ladder"
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

  def test_an_unknown_command_says_which_modes_exist
    code, _out, err = run_cli(["upgrade", "--repo", "."])

    assert_equal AgentsFyi::Upgrader::CLI::EXIT_REFUSED, code
    assert_includes err, "unknown command `upgrade`"
    assert_includes err, "`step`"
  end
end
