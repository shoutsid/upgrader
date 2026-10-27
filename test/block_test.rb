# frozen_string_literal: true

require "minitest/autorun"
require "agents/upgrader"

# **A stop, as a question.** The extractor is pure, so these drive the shapes that matter: one
# question for the earliest stop rather than one per symptom, a `checked` change omitted, a
# documented key kept and a synthetic one labelled project-scoped, and the same stop after an
# edit keeping its identity. What the service does with the row is `decisions_test.rb`'s subject.
class BlockTest < Minitest::Test
  def record(decisions: [], stages: [], checks: [], app_update: nil, baseline: nil,
    verdict: "failed")
    Agents::Upgrader::Record.new(
      repository: "acme/storefront", from_version: "7.0.0", to_version: "7.1.0",
      verdict: verdict, why: "the suite failed", decisions: decisions, stages: stages,
      checks: checks, app_update: app_update, baseline: baseline
    )
  end

  def decision(**attributes)
    defaults = {
      path: "app/views/layouts/application.html.erb", line: 12,
      subject: "render @category", reason: "the argument moved", kind: "argument",
      replacement: "render category: @category", source: "rails guide",
      change_key: nil, checked: false
    }
    Agents::Upgrader::Record::Decision.new(**defaults.merge(attributes))
  end

  def command(stage:, exit_code: 1, output: "boom", ran: true)
    Agents::Upgrader::Record::Command.new(
      stage: stage, command: "bundle exec rspec", ran: ran, exit_code: exit_code,
      seconds: 1.0, output_tail: output
    )
  end

  def test_a_manual_change_becomes_one_scan_manual_question_with_its_documented_key
    record = record(decisions: [
      decision(change_key: "ruby|rails|render-argument"),
      decision(path: "app/views/other.html.erb", subject: "unused", checked: true)
    ])

    blocks = Agents::Upgrader::Block.from_record(record, project: "storefront", run_id: "run-1")

    assert_equal 1, blocks.length, "a checked change is a review row, not a question"
    block = blocks.first
    assert_equal "scan_manual", block["block_kind"]
    assert_equal "ruby|rails|render-argument", block["change_key"]
    assert_equal "documented", block["change_key_source"]
    assert_equal "walker", block["source"]
    assert_equal "run-1", block["run_id"]
    assert_equal "storefront", block["project"]
    assert_equal "7.0.0", block["rung_from"]
    assert_equal "7.1.0", block["rung_to"]
    assert_includes block["question"], "the argument moved"
  end

  def test_a_routing_verdict_gets_a_project_scoped_key_and_no_documented_one_is_guessed
    record = record(decisions: [
      decision(path: "Gemfile.lock", line: nil, subject: "rack 2.2.0",
        reason: "no recorded release fits", kind: "blocked")
    ])

    block = Agents::Upgrader::Block.from_record(record, project: "storefront").first

    assert_equal "route", block["block_kind"]
    assert_equal "ruby|rack|rack", block["change_key"]
    assert_equal "project", block["change_key_source"]
  end

  def test_the_identity_is_the_subject_and_key_rather_than_the_line
    first = Agents::Upgrader::Block.from_record(
      record(decisions: [decision(line: 12)]), project: "storefront"
    ).first
    second = Agents::Upgrader::Block.from_record(
      record(decisions: [decision(line: 40)]), project: "storefront"
    ).first

    assert_equal first["subject"], second["subject"]
    assert_equal first["change_key"], second["change_key"]
    assert_equal first["block_kind"], second["block_kind"]
  end

  def test_a_failed_suite_is_a_suite_block_with_the_failing_tail_as_evidence
    record = record(stages: [command(stage: Agents::Upgrader::Record::SUITE,
      output: "1 example, 1 failure")])

    block = Agents::Upgrader::Block.from_record(record, project: "storefront").first

    assert_equal "suite", block["block_kind"]
    assert_equal "1 example, 1 failure", block["evidence"]["failure"]
    assert_equal "suite at 7.1.0", block["subject"]
    assert_nil block["change_key"], "a suite failure names no library"
  end

  # **A conflict is the walker's own policy outcome, not a question.** `app:update` asks to
  # overwrite every file the application owns and the walker answers no, so a conflict list is
  # the expected result of keeping the application's version; the files are in the record for a
  # reviewer. RMM's rung carried fifty-seven of these beside a green suite, and each one became a
  # question a person was asked to answer.
  def test_an_app_update_conflict_is_recorded_but_is_not_a_question
    record = record(app_update: { "conflicts" => ["config/application.rb"] })

    assert_empty Agents::Upgrader::Block.from_record(record, project: "storefront"),
      "a conflict is a policy outcome, not a stop"
  end

  # A generator that refused is recorded on the run; it is not the cause of a failed rung since
  # `Record::REQUIRED` no longer gates on it. If nothing else failed, there is nothing to ask.
  def test_an_app_update_failure_is_not_a_question_when_nothing_else_failed
    record = record(stages: [
      command(stage: Agents::Upgrader::Record::RAILS_UPDATE, output: "active_storage:update failed")
    ])

    assert_empty Agents::Upgrader::Block.from_record(record, project: "storefront")
  end

  # **A red baseline is a fact about the environment, not about the move.** Ohana's missing
  # browser made the baseline red and parked the target behind a suite question until somebody
  # dismissed and requeued it; the walk should retry instead.
  def test_a_red_baseline_is_not_a_question
    record = record(
      baseline: command(stage: Agents::Upgrader::Record::BASELINE, exit_code: 1,
        output: "Chrome could not be found"),
      stages: [command(stage: Agents::Upgrader::Record::SUITE)]
    )

    assert_empty Agents::Upgrader::Block.from_record(record, project: "storefront")
  end

  def test_a_blocking_check_is_a_check_question
    check = Agents::Upgrader::Checks::Result.new(
      id: "lint", name: "RuboCop", kind: "lint", command: "bundle exec rubocop",
      required: true, external: false, status: "failed", ran: true, exit_code: 1,
      output_tail: "3 offenses"
    )

    block = Agents::Upgrader::Block.from_record(record(checks: [check]),
      project: "storefront").first

    assert_equal "check", block["block_kind"]
    assert_includes block["subject"], "RuboCop"
    assert_equal "3 offenses", block["evidence"]["failure"]
  end

  # **The earliest failure is the one to answer; the rest are its consequences.** A scan's
  # manual change was not reached, and a pin failure means nothing after it ran at all. Posting
  # each true row is what turned one unresolvable gem into twenty questions on diaspora.
  def test_the_earliest_failed_stage_is_the_only_question
    record = record(
      decisions: [decision(change_key: "ruby|rails|x")],
      stages: [
        command(stage: Agents::Upgrader::Record::PIN, output: "version solving has failed"),
        command(stage: Agents::Upgrader::Record::SUITE)
      ]
    )

    blocks = Agents::Upgrader::Block.from_record(record, project: "storefront")

    assert_equal ["pin"], blocks.map { |block| block["block_kind"] }
    assert_includes blocks.first["evidence"]["failure"], "version solving"
  end

  def test_a_suite_failure_drops_the_manual_change_it_did_not_reach
    record = record(
      decisions: [decision(change_key: "ruby|rails|x")],
      stages: [command(stage: Agents::Upgrader::Record::SUITE)]
    )

    blocks = Agents::Upgrader::Block.from_record(record, project: "storefront")

    assert_equal ["suite"], blocks.map { |block| block["block_kind"] }
  end
end
