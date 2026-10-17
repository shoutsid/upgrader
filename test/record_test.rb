# frozen_string_literal: true

require "minitest/autorun"
require "agents_fyi/upgrader"

# The one rule that decides what a step meant, driven from both sides.
#
# This is the file that has to be right rather than thorough: the verdict is what the ledger
# settles a move on, and's whole argument is that a verdict about the *suite* is only
# meaningful against a green baseline. Every branch here is a case somebody would otherwise
# reason about twice, in two places, and disagree with.
class RecordTest < Minitest::Test
  Command = AgentsFyi::Upgrader::Record::Command

  def command(stage:, ran: true, exit_code: 0)
    Command.new(stage: stage, command: "#{stage} cmd", ran: ran, exit_code: exit_code,
      seconds: 1.0, output_tail: "")
  end

  def stages(*args)
    args
  end

  def suite(ran: true, exit_code: 0)
    command(stage: "suite", ran: ran, exit_code: exit_code)
  end

  def verdict(baseline:, test:)
    AgentsFyi::Upgrader::Record.verdict(baseline: baseline, suite: test, stages: stages)
  end

  # The happy path, and it is the only one that may say `passed`.
  def test_a_green_suite_after_a_green_baseline_is_a_pass
    word, why = verdict(baseline: suite, test: suite)

    assert_equal "passed", word
    assert_includes why, "green before this step and green after it"
  end

  # **A stage that ran more than once is judged by its last attempt.** The pin retries with the
  # gems bundler named it could not leave alone, and a walk whose pin succeeded on the second
  # round is a walk whose pin succeeded — the first round's exit 6 is evidence, not a verdict.
  def test_a_stage_that_ran_more_than_once_is_judged_by_its_last_attempt
    pin = AgentsFyi::Upgrader::Record::PIN
    word, why = AgentsFyi::Upgrader::Record.verdict(
      baseline: suite, suite: suite,
      stages: [command(stage: pin, exit_code: 6), command(stage: pin, exit_code: 0)]
    )

    assert_equal "passed", word, why

    failed, failed_why = AgentsFyi::Upgrader::Record.verdict(
      baseline: suite, suite: suite, stages: [command(stage: pin, exit_code: 6)]
    )

    assert_equal "failed", failed
    assert_includes failed_why, "pin did not succeed"
  end

  # The finding this tool exists to produce.
  def test_a_failure_after_a_green_baseline_is_the_step_s_b_doing
    word, why = verdict(baseline: suite, test: suite(exit_code: 1))

    assert_equal "failed", word
    assert_includes why, "green before this step and failed after it"
  end

  # And the one that must not be a finding. Without the baseline these two are the same
  # sentence, and the second files a report blaming a release for a breakage that was
  # already there.
  def test_a_red_baseline_makes_the_suite_say_nothing_about_the_move
    word, why = verdict(baseline: suite(exit_code: 1), test: suite(exit_code: 1))

    assert_equal "unverified", word
    assert_includes why, "cannot be attributed"
  end

  def test_a_suite_that_never_ran_is_unverified_and_never_failed
    word, why = verdict(baseline: suite, test: suite(ran: false, exit_code: nil))

    assert_equal "unverified", word
    assert_includes why, "nothing is established"
  end

  # 's fourth rule, and the one a reader is most likely to get wrong: a step with no suite to
  # run is not a pass.
  def test_no_suite_at_all_is_unverified_rather_than_passed
    word, why = verdict(baseline: suite, test: nil)

    assert_equal "unverified", word
    assert_includes why, "no test suite was found"
  end

  # A step whose pipeline could not get to the suite is failed, and the sentence names
  # the stage — "the step failed" is not something an operator can act on.
  def test_a_required_stage_that_failed_decides_the_verdict_before_the_suite_is_read
    word, why = AgentsFyi::Upgrader::Record.verdict(
      baseline: suite, suite: suite,
      stages: stages(command(stage: AgentsFyi::Upgrader::Record::RAILS_UPDATE, exit_code: 1))
    )

    assert_equal "failed", word
    assert_includes why, "rails:update did not succeed"
    assert_includes why, "exited 1"
  end

  # `apply` is not required: an edit the applier refused is an output of this tool, and
  # a step whose suite is green afterwards is a pass whatever the applier refused.
  def test_a_refused_edit_does_not_fail_a_step_the_suite_passed
    word, _why = AgentsFyi::Upgrader::Record.verdict(
      baseline: suite, suite: suite,
      stages: stages(command(stage: AgentsFyi::Upgrader::Record::APPLY, exit_code: 1))
    )

    assert_equal "passed", word
  end

  # A command that never started established nothing, so a required stage that did not
  # run fails the move with a sentence that says so rather than naming an exit code.
  def test_a_required_stage_that_did_not_run_says_so_rather_than_naming_an_exit_code
    word, why = AgentsFyi::Upgrader::Record.verdict(
      baseline: suite, suite: suite,
      stages: stages(command(stage: AgentsFyi::Upgrader::Record::PIN, ran: false, exit_code: nil))
    )

    assert_equal "failed", word
    assert_includes why, "did not run"
  end

  def test_a_refusal_carries_its_sentence_and_no_stages
    record = AgentsFyi::Upgrader::Record.refused(
      repository: "acme/storefront", from_version: "7.1.0", to_version: "7.0.0",
      why: "this ladder reads forward upgrades only"
    )

    assert record.refused?
    assert_equal "this ladder reads forward upgrades only", record.why
    assert_empty record.stages
  end

  # The JSON is what a consumer reads, and three fields are the contract: the verdict,
  # the reason, and the fact that the caller's repository was not touched.
  def test_the_record_says_what_it_did_and_that_it_touched_nothing
    record = AgentsFyi::Upgrader::Record.new(
      repository: "acme/storefront", commit: "9f2c1ab8", worktree: "/tmp/run-1",
      from_version: "4.2.11", to_version: "5.0.0", name: "Rails 5.0",
      verdict: "passed", why: "the suite was green before this step and green after it",
      stages: [command(stage: "suite")]
    )

    body = JSON.parse(record.to_json)

    assert_equal "passed", body["verdict"]
    assert_equal "Rails 5.0", body["name"]
    assert_equal true, body["wrote_nothing_to_the_repository"]
    assert_equal "suite", body["stages"].first["stage"]
  end

  # A decision is not a refusal, and they travel in separate lists: one is a change that
  # needs a person, the other is a line that did not match what the service read.
  def test_a_decision_and_a_refusal_are_reported_apart
    record = AgentsFyi::Upgrader::Record.new(
      repository: "acme/storefront", from_version: "4.2.11", to_version: "5.0.0",
      verdict: "unverified", why: "no suite",
      decisions: [AgentsFyi::Upgrader::Record::Decision.new(
        path: "app/models/user.rb", line: 12, subject: "find_by_email", reason: "needs the argument"
      )]
    )

    body = JSON.parse(record.to_json)

    assert_empty body["refused"]
    assert_equal "find_by_email", body["decisions"].first["subject"]
    assert_includes record.to_s, "1 need(s) a decision"
  end
end
