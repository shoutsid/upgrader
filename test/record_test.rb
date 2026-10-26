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

  # A record name is what an operator types into `preview`. A raw URL sanitized into
  # `https---github.com-...` is technically unique and practically unusable.
  def test_a_record_name_is_readable_for_a_url_a_declaration_and_a_local_path
    assert_equal "owner-application-7.0.0-7.1.0",
      AgentsFyi::Upgrader::Record.stem("https://github.com/owner/application.git", "7.0.0", "7.1.0")
    assert_equal "acme-storefront-7.0.0-7.1.0",
      AgentsFyi::Upgrader::Record.stem("acme/storefront", "7.0.0", "7.1.0")
    assert_equal "application-7.0.0-7.1.0",
      AgentsFyi::Upgrader::Record.stem("/srv/application", "7.0.0", "7.1.0")
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

  # **`app:update` is a generator, and its refusal does not fail a rung the application's own
  # gate passed.** Rails 8's `active_storage:update` refused on an application with no Active
  # Storage tables while the same rung booted and its suite was green; the stage is recorded and
  # named beside the pass, and only boot/suite decide the move.
  def test_a_failed_app_update_is_recorded_beside_a_green_suite_rather_than_gating_it
    word, why = AgentsFyi::Upgrader::Record.verdict(
      baseline: suite, suite: suite,
      stages: stages(command(stage: AgentsFyi::Upgrader::Record::RAILS_UPDATE, exit_code: 1))
    )

    assert_equal "passed", word
    assert_includes why, "green before this step and green after it"
    assert_includes why, "`app:update` exited 1"
    assert_includes why, "rather than gating it"
  end

  # A step whose pipeline could not get to the suite is failed, and the sentence names
  # the stage — "the step failed" is not something an operator can act on.
  def test_a_required_stage_that_failed_decides_the_verdict_before_the_suite_is_read
    word, why = AgentsFyi::Upgrader::Record.verdict(
      baseline: suite, suite: suite,
      stages: stages(command(stage: AgentsFyi::Upgrader::Record::BOOT, exit_code: 1))
    )

    assert_equal "failed", word
    assert_includes why, "boot did not succeed"
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

  # **The applied list holds two kinds of edit, and only one of them has an origin.** A preflight
  # repair is a Gemfile line this step rewrote on the digest's authority and has no other side to be
  # told apart from; a scanned or rule-written edit does. `to_s` read `origin` without asking, so
  # every run whose preflight repaired a Gemfile raised while printing its summary — and no test
  # caught it, because every test built the applied list out of `Applier::Applied`. This is that run.
  def test_a_record_with_a_preflight_repair_renders
    repair = AgentsFyi::Upgrader::Preflight::Repair.new(
      path: "Gemfile", line: 3, text: %(gem "simple_form", git: "git://github.com/x/y"),
      after: %(gem "simple_form", github: "x/y"), subject: "simple_form",
      note: "the dead protocol (routed for Rails 5.0)"
    )
    record = AgentsFyi::Upgrader::Record.new(
      repository: "acme/storefront", from_version: "4.2.11", to_version: "5.0.0",
      verdict: "passed", why: "the suite was green", applied: [repair]
    )

    assert_includes record.to_s, "applied 1 edit(s)"
    refute_includes record.to_s, "by this tool's own rules",
      "a preflight repair is not one of this tool's own rules"
    assert_equal "simple_form", JSON.parse(record.to_json)["applied"].first["subject"]
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
    assert_includes record.to_s, "1 change(s) this rung carries (1 located, 0 carried, 0 not used here)"
  end

  # **A decision with a line to look at, one with nothing to look at, and one a survey has read are
  # three different things.** The first is a call site this application has; the second is a change
  # this rung carried that the application does not use; the third is the same fact with a survey's
  # finding behind it — no call site at all, and nothing a person or a rule could edit. Counting all
  # three as "need a decision" is how "16 need a decision" reads as sixteen edits when it is three.
  def test_the_summary_counts_located_carried_and_checked_decisions_apart
    decision = lambda do |path, line, subject, checked|
      AgentsFyi::Upgrader::Record::Decision.new(path: path, line: line, subject: subject,
        reason: "the reason", checked: checked)
    end
    record = AgentsFyi::Upgrader::Record.new(
      repository: "acme/storefront", from_version: "4.2.11", to_version: "5.0.0",
      verdict: "unverified", why: "no suite",
      decisions: [decision.call("app/models/user.rb", 12, "find_by_email", false),
                  decision.call(nil, nil, "alias_attribute", true),
                  decision.call(nil, nil, "schema.rb column order", false)]
    )

    assert_includes record.to_s,
      "3 change(s) this rung carries (1 located, 1 carried, 1 not used here)"
    # **The flag is in the JSON, so a page or a reader does not have to parse the reason.**
    checked = JSON.parse(record.to_json)["decisions"].to_h { |item| [item["subject"], item["checked"]] }
    assert_equal({ "find_by_email" => false, "alias_attribute" => true,
      "schema.rb column order" => false }, checked)
  end

  # **A run can be replayed from its JSON.** The record is the durable artifact; a dry-run review
  # reads it back into the same objects the PR renderer uses, without a checkout or a second walk.
  def test_a_record_round_trips_through_its_json_for_replay
    record = AgentsFyi::Upgrader::Record.new(
      repository: "acme/storefront", commit: "abc12345", from_version: "4.2.11",
      to_version: "5.0.0", verdict: "passed", why: "green before and after",
      stages: [command(stage: "pin")],
      applied: [AgentsFyi::Upgrader::Applier::Applied.new(
        path: "Gemfile", line: 2, text: %(gem "rails", "4.2.11"), after: %(gem "rails", "5.0.0"),
        subject: "pin", origin: "rule", note: nil
      )],
      refused: [AgentsFyi::Upgrader::Applier::Refused.new(
        path: "app/models/item.rb", line: 3, text: "old", found: "new",
        reason: "the line moved", subject: "serialize", kind: "changed",
        replacement: "new", source: "7.2", note: "why"
      )],
      decisions: [AgentsFyi::Upgrader::Record::Decision.new(
        path: "app/models/item.rb", line: 4, subject: "button_to", reason: "needs a person"
      )],
      checks: [AgentsFyi::Upgrader::Checks::Result.new(
        id: "lint", name: "lint", kind: "lint", command: "bundle exec rubocop",
        required: true, external: false, environment: nil, status: "passed", ran: true,
        exit_code: 0, seconds: 1.0, output_tail: "no offenses"
      )],
      commits: [{ "concern" => "pin Rails and move gems", "commit" => "b" * 40,
                  "message" => "the pin" }],
      accepted_decisions: [{ "id" => "d1", "question" => "Remove it?", "answer" => "yes",
                             "accepted_by" => "operator:9f2c", "effects" => [] }],
      app_update: { "adopt" => "added_only", "adopted" => [], "conflicts" => [],
                    "skipped" => [], "framework_defaults" => "off", "load_defaults" => nil },
      toolchain: { "ruby" => "3.3.12" },
      project: { "slug" => "storefront", "source_roots" => ["app"] }
    )

    again = AgentsFyi::Upgrader::Record.from_h(JSON.parse(record.to_json))

    assert_equal record.to_h, again.to_h
    assert_equal "lint", again.checks.first.id
    assert_equal "pin Rails and move gems", again.commits.first["concern"]
  end

  # **A formatter that ran and failed is a failed rung; one that did not run is unverified.** The
  # formatter is a command like any other, and the third answer is the one that must not be read as
  # a finding about the application.
  def test_a_failed_formatter_fails_the_rung_and_a_missing_one_leaves_it_unverified
    failed = command(stage: "style", exit_code: 2)
    word, why = AgentsFyi::Upgrader::Record.verdict(baseline: suite, suite: suite,
      stages: stages(failed))
    assert_equal "failed", word
    assert_includes why, "formatter"

    absent = command(stage: "style", ran: false, exit_code: nil)
    word, why = AgentsFyi::Upgrader::Record.verdict(baseline: suite, suite: suite,
      stages: stages(absent))
    assert_equal "unverified", word
    assert_includes why, "did not run"
  end

  # **The suite is one check, not the gate.** A green suite with a red lint check has not
  # established the rung, and the sentence names the check that failed rather than a generic stage.
  def test_a_required_check_that_failed_turns_a_green_suite_into_a_failed_rung
    result = AgentsFyi::Upgrader::Checks::Result.new(id: "lint", kind: "lint",
      command: "bundle exec rubocop", required: true, external: false, status: "failed",
      ran: true, exit_code: 8, seconds: 1.0, reason: "exited 8")
    word, why = AgentsFyi::Upgrader::Record.verdict(baseline: suite, suite: suite,
      stages: stages, checks: [result])

    assert_equal "failed", word
    assert_includes why, "lint"
    assert_includes why, "8"
  end

  # A check that did not run is the third answer: the gate was not measured, and the rung is
  # unverified rather than failed.
  def test_a_required_check_that_did_not_run_leaves_the_rung_unverified
    result = AgentsFyi::Upgrader::Checks::Result.new(id: "packwerk", kind: "static",
      command: "bundle exec packwerk check", required: true, external: false,
      status: "not_run", ran: false, reason: "did not run (exit 127)")
    word, why = AgentsFyi::Upgrader::Record.verdict(baseline: suite, suite: suite,
      stages: stages, checks: [result])

    assert_equal "unverified", word
    assert_includes why, "packwerk"
    assert_includes why, "did not run"
  end

  # **An external check never decides the verdict.** The walk did not run it; the application's CI
  # owns that answer, and the record says where it runs rather than calling it green.
  def test_an_external_check_is_carried_without_a_vote
    result = AgentsFyi::Upgrader::Checks::Result.new(id: "ci", kind: "external",
      required: true, external: true, status: "external", ran: false,
      reason: "the application's GitHub Actions test job")
    word, why = AgentsFyi::Upgrader::Record.verdict(baseline: suite, suite: suite,
      stages: stages, checks: [result])

    assert_equal "passed", word, why
  end

  # An edit this tool's own rules made is legible as one: a reviewer reading the patch can tell the
  # service's mechanical rewrites from the walker's own (`Rewrites`), which the service deliberately
  # does not make.
  def test_edits_made_by_this_tool_s_own_rules_are_counted_apart
    record = AgentsFyi::Upgrader::Record.new(
      repository: "acme/storefront", from_version: "4.2.11", to_version: "5.0.0",
      verdict: "passed", why: "green before and after",
      applied: [AgentsFyi::Upgrader::Applier::Applied.new(
        path: "app/models/user.rb", line: 12,
        text: "  x = HashWithIndifferentAccess.new",
        after: "  x = ActiveSupport::HashWithIndifferentAccess.new",
        subject: "HashWithIndifferentAccess", origin: "rule"
      )]
    )

    assert_includes record.to_s, "1 of those edit(s) were made by this tool's own rules"
  end
end
