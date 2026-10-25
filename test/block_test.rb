# frozen_string_literal: true

require "minitest/autorun"
require "agents_fyi/upgrader"

# **A stop, as a question.** The extractor is pure, so these drive the shapes that matter: one
# block per stop rather than one per rung, a `checked` change omitted, a documented key kept
# and a synthetic one labelled project-scoped, and the same stop after an edit keeping its
# identity. What the service does with the row is `decisions_test.rb`'s subject.
class BlockTest < Minitest::Test
  def record(decisions: [], stages: [], checks: [], app_update: nil, verdict: "failed")
    AgentsFyi::Upgrader::Record.new(
      repository: "acme/storefront", from_version: "7.0.0", to_version: "7.1.0",
      verdict: verdict, why: "the suite failed", decisions: decisions, stages: stages,
      checks: checks, app_update: app_update
    )
  end

  def decision(**attributes)
    defaults = {
      path: "app/views/layouts/application.html.erb", line: 12,
      subject: "render @category", reason: "the argument moved", kind: "argument",
      replacement: "render category: @category", source: "rails guide",
      change_key: nil, checked: false
    }
    AgentsFyi::Upgrader::Record::Decision.new(**defaults.merge(attributes))
  end

  def command(stage:, exit_code: 1, output: "boom", ran: true)
    AgentsFyi::Upgrader::Record::Command.new(
      stage: stage, command: "bundle exec rspec", ran: ran, exit_code: exit_code,
      seconds: 1.0, output_tail: output
    )
  end

  def test_a_manual_change_becomes_one_scan_manual_question_with_its_documented_key
    record = record(decisions: [
      decision(change_key: "ruby|rails|render-argument"),
      decision(path: "app/views/other.html.erb", subject: "unused", checked: true)
    ])

    blocks = AgentsFyi::Upgrader::Block.from_record(record, project: "storefront", run_id: "run-1")

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

    block = AgentsFyi::Upgrader::Block.from_record(record, project: "storefront").first

    assert_equal "route", block["block_kind"]
    assert_equal "ruby|rack|rack", block["change_key"]
    assert_equal "project", block["change_key_source"]
  end

  def test_the_identity_is_the_subject_and_key_rather_than_the_line
    first = AgentsFyi::Upgrader::Block.from_record(
      record(decisions: [decision(line: 12)]), project: "storefront"
    ).first
    second = AgentsFyi::Upgrader::Block.from_record(
      record(decisions: [decision(line: 40)]), project: "storefront"
    ).first

    assert_equal first["subject"], second["subject"]
    assert_equal first["change_key"], second["change_key"]
    assert_equal first["block_kind"], second["block_kind"]
  end

  def test_a_failed_suite_is_a_suite_block_with_the_failing_tail_as_evidence
    record = record(stages: [command(stage: AgentsFyi::Upgrader::Record::SUITE,
      output: "1 example, 1 failure")])

    block = AgentsFyi::Upgrader::Block.from_record(record, project: "storefront").first

    assert_equal "suite", block["block_kind"]
    assert_equal "1 example, 1 failure", block["evidence"]["failure"]
    assert_equal "suite at 7.1.0", block["subject"]
    assert_nil block["change_key"], "a suite failure names no library"
  end

  def test_an_app_update_conflict_is_its_own_question
    record = record(app_update: { "conflicts" => ["config/application.rb"] })

    block = AgentsFyi::Upgrader::Block.from_record(record, project: "storefront").first

    assert_equal "app_update", block["block_kind"]
    assert_includes block["subject"], "config/application.rb"
    assert_equal "config/application.rb", block["context"]["file"]
  end

  def test_a_blocking_check_is_a_check_question
    check = AgentsFyi::Upgrader::Checks::Result.new(
      id: "lint", name: "RuboCop", kind: "lint", command: "bundle exec rubocop",
      required: true, external: false, status: "failed", ran: true, exit_code: 1,
      output_tail: "3 offenses"
    )

    block = AgentsFyi::Upgrader::Block.from_record(record(checks: [check]),
      project: "storefront").first

    assert_equal "check", block["block_kind"]
    assert_includes block["subject"], "RuboCop"
    assert_equal "3 offenses", block["evidence"]["failure"]
  end

  def test_one_block_per_stop_and_a_stage_is_not_duplicated_by_its_own_decision
    record = record(
      decisions: [decision(change_key: "ruby|rails|x")],
      stages: [command(stage: AgentsFyi::Upgrader::Record::SUITE)]
    )

    blocks = AgentsFyi::Upgrader::Block.from_record(record, project: "storefront")

    assert_equal %w[scan_manual suite], blocks.map { |block| block["block_kind"] }.sort
  end
end
