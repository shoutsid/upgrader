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

  # **An application may carry all three shapes, and the first real walk's did**: a
  # `spec/spec_helper.rb`, a `test/test_helper.rb` from Rails' generators and a `Rakefile`.
  # A helper file is a deliberate statement that a suite exists and a `test/` directory of
  # generated files is not, so specs win — and the suites that were passed over are named in
  # the reason, which travels into the record's baseline stage. A tool that silently chose one
  # of three suites would make its own choice invisible in the evidence.
  def test_an_application_with_three_suites_is_measured_by_the_one_it_states
    with_app("spec/spec_helper.rb" => "", "test/test_helper.rb" => "", "bin/rails" => "",
      "Rakefile" => "") do |dir|
      suite = detect(dir)

      assert_equal :rspec, suite.kind
      assert_includes suite.reason, "this application's suite is rspec"
      assert_includes suite.reason, "bin/rails test", "the suites passed over are not named"
      assert_includes suite.reason, "bundle exec rake test"
      assert_includes suite.reason, "the one the repository states for itself"
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

  # **A declared suite wins over what the repository would have matched.** The declaration is the
  # operator's statement about their own application, and an engine that guessed a different suite
  # from the tree would be measuring the rung with something other than what the project says it
  # measures itself with — silently, because both suites are green.
  def test_a_declared_suite_wins_over_what_the_repository_would_have_matched
    with_app("spec/spec_helper.rb" => "", "test/test_helper.rb" => "", "bin/rails" => "") do |dir|
      assert_equal :rspec, detect(dir).kind

      # The duck type `Tests.detect` asks of a declaration: a kind, a command, and whether the
      # project says it has no suite at all. `Project::Suite` is one; this test names the shape so
      # the runner does not depend on the declaration class.
      declared = Struct.new(:kind, :command) do
        def none? = kind.to_s == "none"
      end.new("minitest", "bin/rails test")
      assert_equal :minitest, Tests.detect(dir, declared: declared).kind
      assert_equal "bin/rails test", Tests.detect(dir, declared: declared).command
      assert_includes Tests.detect(dir, declared: declared).reason, "the project declares"
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

  # **Both ends of a long output, and the middle counted.** A Ruby failure's first lines carry
  # the exception's message and its last lines carry the frames nearest the failure — the first
  # real walk's records showed frames and no error, because a tail-only bound had dropped the
  # half that said what went wrong. This drives the *streaming* form (`Tests.drain`), which is
  # the one a suite uses, and asserts the marker that says how much was not kept.
  def test_a_long_output_keeps_its_head_and_its_tail_and_says_what_it_dropped
    result = run_suite(
      kind: :rspec,
      script: 'print("BEGIN-MARKER"); print("x" * 50_000); print("END-MARKER")',
      tail_bytes: 1000
    )

    assert result.passed
    assert_operator result.output_tail.bytesize, :<=, 1100
    assert_includes result.output_tail, "BEGIN-MARKER", "the head of the output was dropped"
    assert_includes result.output_tail, "END-MARKER"
    assert_match(/\[\.\.\.\d+ byte\(s\) dropped from the middle\.\.\.\]/, result.output_tail,
      "the record does not say how much it did not keep")
  end

  # And the excerpt keeps the head even when the *first* thing printed is enormous: the middle
  # is dropped as it flows, so a suite that prints a gigabyte of dots still records the error
  # that came before them.
  def test_an_excerpt_keeps_the_first_bytes_when_the_output_starts_with_them
    excerpt = AgentsFyi::Upgrader::Shell::Excerpt.new(bytes: 100)
    excerpt << "MESSAGE-AT-THE-START\n" << ("x" * 10_000)

    text = excerpt.to_s
    kept = text.sub(/\[\.\.\.\d+ byte\(s\) dropped from the middle\.\.\.\]/, "").strip

    assert_includes text, "MESSAGE-AT-THE-START"
    # The two ends are within the budget; the separators that join them and the marker are the
    # record's own punctuation, not content.
    assert_operator kept.bytesize, :<=, 104,
      "the budget bounds the content; the marker is the record's own annotation"
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
