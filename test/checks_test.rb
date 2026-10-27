# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "agents/upgrader"

# The application's gate, not one command.
#
# The three answers are the same three `Tests` keeps: passed, failed, and *nothing was established*.
# An external check is a fourth answer here and deliberately not a green one — this walk did not run
# the application's CI, and a local suite passing is not evidence that it did.
class ChecksTest < Minitest::Test
  Checks = Agents::Upgrader::Checks
  Check = Agents::Upgrader::Project::Check

  def check(id: "lint", command:, required: true)
    Check.new(id: id, name: nil, kind: "lint", command: command, required: required,
      external: false, environment: nil, reason: nil)
  end

  def external(id: "ci", reason: "the application's GitHub Actions test job")
    Check.new(id: id, name: "the application's CI", kind: "external", command: nil,
      required: true, external: true, environment: "ci", reason: reason)
  end

  def test_a_local_check_that_exits_zero_passes_and_carries_its_command
    Dir.mktmpdir do |root|
      result = Checks.run(root: root, checks: [check(command: "ruby -e 'exit 0'")]).first

      assert_equal "passed", result.status
      assert result.local?
      assert result.ran
      assert_equal 0, result.exit_code
      assert_equal "ruby -e 'exit 0'", result.command
    end
  end

  def test_a_local_check_that_exits_non_zero_fails_and_names_the_exit
    Dir.mktmpdir do |root|
      result = Checks.run(root: root, checks: [check(command: "ruby -e 'exit 7'")]).first

      assert_equal "failed", result.status
      assert result.blocking_failure?
      assert_equal 7, result.exit_code
      assert_includes result.reason, "7"
    end
  end

  # **A command that is not installed established nothing.** It is the third answer, not a failure:
  # a machine without the linter has not shown the application is unformatted.
  def test_a_command_that_did_not_run_is_not_a_failure
    Dir.mktmpdir do |root|
      result = Checks.run(root: root,
        checks: [check(command: "definitely-not-a-command-agents")]).first

      assert_equal "not_run", result.status
      refute result.blocking_failure?
      assert result.blocking_absence?
      assert_includes result.reason, "did not run"
    end
  end

  # **An external check is recorded, never reported green.** It has no command, no exit code and
  # no vote in the verdict; the reason is the whole of what this walk can say about it.
  def test_an_external_check_is_recorded_with_where_it_runs
    Dir.mktmpdir do |root|
      result = Checks.run(root: root, checks: [external]).first

      assert_equal "external", result.status
      assert result.external?
      refute result.local?
      refute result.blocking_failure?
      refute result.blocking_absence?
      assert_includes result.reason, "GitHub Actions"
    end
  end

  # The record's command list takes local checks only: an external one has no command, and a stage
  # that says "did not run" would read as a check this machine attempted.
  def test_the_command_list_carries_local_checks_and_not_external_ones
    Dir.mktmpdir do |root|
      local, far = Checks.run(root: root,
        checks: [check(command: "ruby -e 'exit 0'"), external])

      assert_equal "check", Checks.stage(local).stage
      assert_nil Checks.stage(far)
    end
  end
end
