# frozen_string_literal: true

require "minitest/autorun"
require "agents_fyi/upgrader"

# The one place a child process is spawned.
#
# `Tests` grew this mechanism first — a suite needs a deadline, a kill that reaches the workers it forks, and
# both ends of its output — and `Shell.run` had none of it, so a pipeline command whose container could not
# reach rubygems hung until somebody noticed: one walk sat in `bundle update` for nine minutes and would have
# sat there for the hour a hand-run step allows. What is asserted here is the half that was missing.
class ShellTest < Minitest::Test
  Shell = AgentsFyi::Upgrader::Shell

  def test_a_command_that_finishes_is_recorded_with_its_output_and_its_exit_code
    record = Shell.run(["sh", "-c", "echo hello; exit 0"], stage: "probe", chdir: Dir.pwd)

    assert record.ran
    assert_equal 0, record.exit_code
    assert_includes record.output_tail, "hello"
    refute_includes record.output_tail, "killed at its"
  end

  # **A command killed at its bound established nothing**, which is the same third answer a missing program
  # is — and the record has to say which of the two happened, because a reader acts differently on each.
  def test_a_command_that_exceeds_its_bound_is_killed_and_says_which_bound_it_hit
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    record = Shell.run(["sh", "-c", "echo working; sleep 30"], stage: "probe", chdir: Dir.pwd, timeout: 0.3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    refute record.ran, "a command killed at its bound established nothing about the application"
    assert_nil record.exit_code
    assert_operator elapsed, :<, 10, "the bound is what ends it, not the command's own length"
    assert_includes record.output_tail, "killed at its 0.3-second bound"
    assert_includes record.output_tail, "unverified rather than failed"
    assert_includes record.output_tail, "working", "what it printed before the bound is still evidence"
  end

  def test_a_command_that_fails_is_not_the_same_as_one_that_was_killed
    record = Shell.run(["sh", "-c", "echo bad; exit 3"], stage: "probe", chdir: Dir.pwd, timeout: 5)

    assert record.ran
    assert_equal 3, record.exit_code
    refute_includes record.output_tail, "killed at its"
  end

  # The bound's own numbers, so a change to either is a decision rather than an edit: a cold
  # `bundle install` is minutes and a resolve that reaches rubygems is slower, so the default is generous —
  # what it exists to stop is the *unbounded* case.
  def test_the_bound_has_a_generous_default_and_a_knob
    assert_operator Shell::DEFAULT_COMMAND_TIMEOUT, :>=, 300
    assert_equal "UPGRADER_COMMAND_TIMEOUT", Shell::ENV_TIMEOUT
  end
end
