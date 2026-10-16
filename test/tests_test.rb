# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
# The file rather than the library, so this suite runs on its own as well as inside
# `test/all_test.rb` — the runner's own tests should not depend on the library's
# require list being in the order they need.
require "agents_fyi/upgrader/tests"

# Detecting a suite, and running one. What is asserted here is the distinction the
# whole record rests on: a suite that failed, a suite that never ran, and a suite that
# had to be killed are three different facts, and only the first one is a finding about
# a release.
class TestsTest < Minitest::Test
  Tests = AgentsFyi::Upgrader::Tests

  # The interpreter running this test, by absolute path. A suite under test must not
  # depend on `ruby` being on `PATH`: on a machine that installed Ruby through a
  # version manager it usually is not, and a test that only passes there is a test that
  # has not been run.
  RUBY = RbConfig.ruby

  def with_app(files)
    Dir.mktmpdir do |dir|
      files.each do |path, body|
        full = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      yield dir
    end
  end

  def detect(dir)
    Tests.detect(dir)
  end

  def command(script)
    %("#{RUBY}" -e '#{script}')
  end

  def suite(kind:, script:)
    Tests::Suite.new(kind: kind, command: command(script), reason: "a fixture, not a detected suite")
  end

  def run_suite(kind:, script:, timeout: 60, env: {}, tail_bytes: 4000)
    with_app({}) do |dir|
      Tests.run(dir, suite(kind: kind, script: script), timeout: timeout, env: env,
        tail_bytes: tail_bytes)
    end
  end

  # The order in the table is the decision, and this is the case it decides: a Rails 5
  # application has a Rakefile as well, and `rake test` is the deprecated entry.
  def test_a_rails_five_application_runs_its_suite_through_bin_rails_rather_than_rake
    with_app("bin/rails" => "", "test/test_helper.rb" => "", "Rakefile" => "") do |dir|
      assert_equal :rails, detect(dir).kind
      assert_equal "bin/rails test", detect(dir).command
    end
  end

  def test_an_application_whose_suite_is_specs_runs_rspec
    with_app("spec/spec_helper.rb" => "", "Rakefile" => "") do |dir|
      assert_equal :rspec, detect(dir).kind
      assert_equal "bundle exec rspec", detect(dir).command
    end
  end

  def test_a_rails_four_application_runs_its_suite_through_the_rake_task
    with_app("Rakefile" => "", "test/test_helper.rb" => "") do |dir|
      assert_equal :rake, detect(dir).kind
      assert_equal "bundle exec rake test", detect(dir).command
    end
  end

  # A deliberate refusal rather than an absence. There is a suite here and nothing
  # that says how to run it, so it is not run — and the sentence for the record says
  # where the tool looked, because "no suite" without that is indistinguishable from
  # having looked in the wrong place.
  def test_an_application_the_table_does_not_match_is_refused_rather_than_guessed_at
    with_app("test/whatever_test.rb" => "") do |dir|
      assert_nil detect(dir)
      reason = Tests.no_suite_reason(dir)
      assert_includes reason, "test/test_helper.rb"
      assert_includes reason, "unverified"
    end
  end

  def test_a_suite_that_exits_non_zero_ran_and_failed
    result = run_suite(kind: :rspec, script: "exit 3")

    assert result.ran
    refute result.passed
    assert_equal 3, result.exit_code
    refute result.timed_out
  end

  def test_a_suite_that_never_ran_is_not_a_failure_and_not_a_pass
    with_app({}) do |dir|
      missing = Tests::Suite.new(kind: :rspec, command: "definitely-not-installed-#{Process.pid}")
      result = Tests.run(dir, missing)

      refute result.ran
      refute result.passed
      assert_equal Tests::NOT_FOUND, result.exit_code
      refute result.timed_out
      # The sentence has to carry the distinction, because it is the whole of what a
      # reader of the record sees.
      assert_includes Tests.summary(result), "unverified"
      assert_includes Tests.summary(result), Tests::NOT_FOUND.to_s
    end
  end

  # A suite that traps the signal is exactly the case a naive timeout leaves behind:
  # the shell dies, the workers keep running, and the step never returns.
  def test_a_suite_that_ignores_its_termination_signal_is_still_killed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = run_suite(kind: :rspec, script: 'Signal.trap("TERM") {}; sleep 60', timeout: 1)
    seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert result.timed_out
    refute result.ran
    refute result.passed
    assert_operator seconds, :<, 15, "the run should have been killed, not waited out"
    assert_includes Tests.summary(result), "unverified"
  end

  def test_only_the_tail_of_a_long_output_is_kept
    result = run_suite(
      kind: :rspec,
      script: 'print("x" * 50_000); print("END-MARKER")',
      tail_bytes: 1000
    )

    assert result.passed
    assert_operator result.output_tail.bytesize, :<=, 1000
    assert_includes result.output_tail, "END-MARKER"
  end

  # A Rails suite that runs without `RAILS_ENV` boots in development, against the
  # development database, in a working copy somebody is upgrading — so the environment
  # is part of running it, and a caller's own variables survive alongside it.
  def test_a_rails_suite_runs_in_the_test_environment_with_the_callers_variables_beside_it
    result = run_suite(
      kind: :rails,
      env: { "UPGRADER_TEST_MARK" => "1" },
      # `\#{…}` is escaped because the interpolation belongs to the *child* process: this
      # script is handed to `ruby -e`, so the braces have to arrive as text. Written as a
      # `%()` literal rather than a single-quoted one because a single-quoted string holding
      # `#{…}` reads as a mistake to `Lint/InterpolationCheck`, and a suppression for a false
      # positive outlives the reason for it.
      script: %(puts "ENV=\#{ENV["RAILS_ENV"]} MARK=\#{ENV["UPGRADER_TEST_MARK"]}")
    )

    assert result.passed
    assert_includes result.output_tail, "ENV=test"
    assert_includes result.output_tail, "MARK=1"
  end
end
