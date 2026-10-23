# frozen_string_literal: true

require "minitest/autorun"
require "agents_fyi/upgrader"
require "agents_fyi/upgrader/filing"

# A failed step as a report. Two things are asserted here and they are different
# questions: what the body says, which is a pure function of the record, and what the
# client does with the corpus's answer — file it, or read the report the corpus named.
#
# Nothing here reaches a network: the body is built from a record and dispatched to a
# double, so the claim under test is what the upgrader says about somebody's application
# rather than whether a service is up.
class FilingTest < Minitest::Test
  Failed = AgentsFyi::Upgrader::Record::FAILED
  Refused = AgentsFyi::Upgrader::Record::REFUSED
  Unverified = AgentsFyi::Upgrader::Record::UNVERIFIED

  class FakeCorpus
    attr_reader :prechecked, :submitted

    def initialize(verdict: "new", candidates: [], report: nil)
      @verdict = verdict
      @candidates = candidates
      @report = report
    end

    def precheck(payload)
      @prechecked = payload
      { "verdict" => @verdict, "advice" => "Verify the report it names instead.",
        "candidates" => @candidates }
    end

    def create_report(payload)
      @submitted = payload
      @report || { "id" => "report-1" }
    end
  end

  def command(stage:, command:, ran: true, exit_code: 0, output_tail: "")
    AgentsFyi::Upgrader::Record::Command.new(
      stage: stage, command: command, ran: ran, exit_code: exit_code, seconds: 1.0,
      output_tail: output_tail
    )
  end

  def record_for(verdict:, stages: [], baseline: nil, suite: nil, worktree: nil, repairs: [],
    checks: [], changes: [], expected: [], fired_rules: [])
    AgentsFyi::Upgrader::Record.new(
      repository: "https://github.com/acme/storefront.git", commit: "9f2c1ab8",
      worktree: worktree, from_version: "6.0.4.4", to_version: "7.1.0", verdict: verdict,
      why: "the suite failed after a green baseline", name: "Rails 7.1",
      interpreter: "ruby 3.3.12", image: "agents-fyi-upgrader:latest",
      stages: stages, baseline: baseline, suite: suite, applied: [1, 2], refused: [], decisions: [],
      repairs: repairs, checks: checks, changes: changes, expected: expected, fired_rules: fired_rules
    )
  end

  def change(subject: "before_filter", kind: "renamed", component: "actionpack",
    replacement: "before_action", change_key: nil)
    { "component" => component, "subject" => subject, "kind" => kind,
      "replacement" => replacement,
      "change_key" => change_key || "ruby|#{component}|#{subject.downcase}" }
  end

  # **A check that failed with a green suite is the failure, not the green suite.** The report used
  # to quote the baseline's exit 0 as the problem, which is a report about a command that passed;
  # the decisive check is turned into the command-shaped stage the report already quotes.
  def test_a_failed_check_is_the_problem_and_the_green_suite_is_not
    green = command(stage: "suite", command: "bundle exec rspec", exit_code: 0,
      output_tail: "10 examples, 0 failures")
    lint = AgentsFyi::Upgrader::Checks::Result.new(id: "lint", kind: "lint",
      command: "bundle exec rubocop", required: true, external: false, status: "failed",
      ran: true, exit_code: 8, seconds: 1.0, output_tail: "8 offenses detected")
    record = record_for(verdict: Failed, stages: [], baseline: green, suite: green, checks: [lint])

    stage = AgentsFyi::Upgrader::Filing.failing_stage(record: record)
    payload = AgentsFyi::Upgrader::Filing.report_for(record: record)

    assert_equal "bundle exec rubocop", stage.command
    assert_includes payload["problem"], "bundle exec rubocop"
    assert_includes payload["problem"], "exited 8"
    assert_includes payload["trace"], "8 offenses detected"
    refute_includes payload["problem"], "10 examples, 0 failures",
      "the green suite was filed as the problem"
  end

  # **A check that did not run is not more decisive than one that failed.** A required prepare
  # check that could not run appears before the lint that failed, and a `find` with an OR picked
  # the first in list order — which quoted a command that never ran.
  def test_a_failed_check_is_chosen_before_a_check_that_did_not_run
    green = command(stage: "suite", command: "bundle exec rspec", exit_code: 0)
    absent = AgentsFyi::Upgrader::Checks::Result.new(id: "prepare", kind: "prepare",
      command: "yarn install", required: true, external: false, status: "not_run", ran: false,
      reason: "did not run (exit 127)")
    failed = AgentsFyi::Upgrader::Checks::Result.new(id: "lint", kind: "lint",
      command: "bundle exec rubocop", required: true, external: false, status: "failed",
      ran: true, exit_code: 8, seconds: 1.0, output_tail: "8 offenses")
    record = record_for(verdict: Failed, baseline: green, suite: green,
      checks: [absent, failed])

    stage = AgentsFyi::Upgrader::Filing.failing_stage(record: record)

    assert_equal "bundle exec rubocop", stage.command
  end

  # **A repair is a report whose fix is the repair.** The failure is measured before the repair — it
  # is the failure an application really had — and the repair's own diff is the resolution, so the
  # next application that meets it can be given the change rather than a sentence about it.
  def test_a_repair_becomes_a_report_with_the_failure_as_the_problem_and_the_diff_as_the_fix
    outcome = AgentsFyi::Upgrader::Repair::Outcome.new(
      failure: "  1) Layout renders the footer\n     Failure/Error: undefined method `x'\n",
      suite: "bundle exec rspec", attempts: 2,
      files: ["app/views/layouts/application.html.erb"],
      diff: "diff --git a/app/views/layouts/application.html.erb b/app/views/layouts/application.html.erb\n-<%= x %>\n+<%= y %>",
      before_the_move: false
    )
    record = record_for(verdict: AgentsFyi::Upgrader::Record::PASSED, repairs: [outcome])

    payload = AgentsFyi::Upgrader::Filing.repair_report_for(record: record, outcome: outcome)

    assert_includes payload["title"], "rails 7.1.0"
    assert_includes payload["title"], "bounded repair made it green"
    assert_includes payload["problem"], "was red before the repair"
    assert_includes payload["problem"], "undefined method `x'"
    assert_includes payload["resolution"], "app/views/layouts/application.html.erb"
    assert_includes payload["resolution"], "+<%= y %>", "the repair's own diff is not in the fix"
    assert_includes payload["attempted"], "2 repair attempt(s)"
    assert_equal "ruby", payload["ecosystem"]
    assert_equal "7.1.0", payload["version"]
  end

  # A repair with nothing to say about what failed is not filed: a report whose problem is empty is
  # a claim the corpus cannot compare with anything.
  def test_a_repair_with_no_recorded_failure_is_not_a_report
    outcome = AgentsFyi::Upgrader::Repair::Outcome.new(failure: "  \n", suite: "rspec", attempts: 1,
      files: [], diff: "", before_the_move: false)

    assert_nil AgentsFyi::Upgrader::Filing.repair_report_for(
      record: record_for(verdict: AgentsFyi::Upgrader::Record::PASSED, repairs: [outcome]),
      outcome: outcome
    )
  end

  # And it takes the same door as a failure: precheck first, and the corpus's verdict decides whether
  # the write happens. A repair the corpus says it already holds is answered, not written twice.
  def test_repairs_are_filed_through_precheck_and_a_duplicate_is_not_written_again
    corpus = FakeCorpus.new(verdict: "duplicate")
    outcome = AgentsFyi::Upgrader::Repair::Outcome.new(failure: "boom", suite: "rspec", attempts: 1,
      files: ["app/models/user.rb"], diff: "", before_the_move: true)
    record = record_for(verdict: AgentsFyi::Upgrader::Record::PASSED, repairs: [outcome])

    results = AgentsFyi::Upgrader::Filing.file_repairs(corpus: corpus, record: record)

    assert_equal 1, results.length
    assert_equal "not_filed", results.first.action
    assert_equal "duplicate", results.first.verdict
    refute_nil corpus.prechecked, "the repair skipped the precheck"
    assert_nil corpus.submitted, "a duplicate precheck still wrote a report"
  end

  # The shape the pipeline produces when the suite fails and nothing before it did: every
  # required stage exited zero, the baseline was green, and the run's last command was not.
  def suite_failed_record(worktree: nil, changes: [], tail: nil, expected: [], fired_rules: [])
    # A real runner prints where the failure is, so the working copy's path is in the
    # output whenever one is being described. It has to be in the fixture for the test
    # below to be about anything.
    where = worktree ? "#{worktree}/app/models/store.rb:12:in `valid?'\n" : ""
    tail ||= "#{where}Failure/Error: expect(Store.new).to be_valid\n" \
             "NameError: uninitialized constant Store::TAX\n  " \
             "0 examples, 1 failure"
    record_for(
      verdict: Failed, worktree: worktree, changes: changes, expected: expected,
      fired_rules: fired_rules,
      baseline: command(stage: "baseline", command: "bundle exec rspec"),
      suite: command(stage: "suite", command: "bundle exec rspec", exit_code: 1, output_tail: tail),
      stages: [command(stage: "pin", command: "bundle update rails"),
               command(stage: "rails:update", command: "bin/rails app:update"),
               command(stage: "boot", command: "bin/rails runner puts Rails.version"),
               command(stage: "suite", command: "bundle exec rspec", exit_code: 1, output_tail: tail)]
    )
  end

  def test_a_passed_step_files_nothing
    result = AgentsFyi::Upgrader::Filing.file(
      corpus: FakeCorpus.new,
      record: record_for(verdict: AgentsFyi::Upgrader::Record::PASSED)
    )

    assert_equal "skipped", result.action
    refute result.filed?
    assert_includes result.reason, "passed"
  end

  # A refusal is a fact about the ladder's coverage, and its home is the run record's
  # refusal list — which is what the coverage figure is measured from. Filing it here
  # would file this tool's own gaps as somebody's breakage.
  def test_a_refused_step_files_nothing
    result = AgentsFyi::Upgrader::Filing.file(corpus: FakeCorpus.new, record: record_for(verdict: Refused))

    assert_equal "skipped", result.action
    assert_includes result.reason, "refused"
  end

  def test_an_unverified_step_files_nothing
    corpus = FakeCorpus.new

    result = AgentsFyi::Upgrader::Filing.file(corpus: corpus, record: record_for(verdict: Unverified))

    assert_equal "skipped", result.action
    assert_nil corpus.submitted, "an unverified step was filed"
  end

  def test_no_record_files_nothing
    assert_equal "skipped", AgentsFyi::Upgrader::Filing.file(corpus: FakeCorpus.new, record: nil).action
  end

  # What the report is about, and the choice is stated rather than inferred: the library
  # is the subject the step was moving, and the version is the release it was moving to.
  # Reading a gem out of the traceback would be this tool deciding which of an
  # application's dependencies is at fault, which is the decision it does not make.
  def test_a_failed_step_becomes_a_report_that_names_the_move_it_failed_in
    payload = AgentsFyi::Upgrader::Filing.report_for(record: suite_failed_record)

    assert_equal "rails", payload["library"]
    assert_equal "7.1.0", payload["version"]
    assert_equal "6.0.4.4", payload["from_version"]
    assert_equal "ruby", payload["ecosystem"], "a gem filed as PyPI's is compared against the Python corpus"
    assert_equal "platform", payload["subject_kind"],
      "a framework failure filed as a package lands in the gem half of the corpus"
    assert_nil payload["subject"], "a rung with no documented change has no subject to claim"
    assert_nil payload["change_kind"]
    assert_nil payload["replacement"]
    assert_includes payload["title"], "rails 7.1.0"
    assert_includes payload["title"], "6.0.4.4 -> 7.1.0"
    assert_includes payload["problem"], "NameError: uninitialized constant Store::TAX"
    assert_includes payload["problem"], "`bundle exec rspec` exited 1"
    # The raw output as well as the summary, because every symptom in a trace is indexed
    # and the next caller holding the same traceback is who the report is for.
    assert_includes payload["trace"], "Failure/Error"
    assert_includes payload["trace"], "0 examples, 1 failure"
    # And what a reader is entitled to know before trusting it: the machine that made the
    # change is the machine that checked it.
    assert_includes payload["environment"], "not an independent reproduction"
    assert_includes payload["environment"], "ruby 3.3.12"
    assert_includes payload["environment"], "9f2c1ab8"
  end

  # **A suite that opens with warnings is titled by its first failing example.** A suite's
  # excerpt keeps both ends, and a Rails 5 run prints deprecation warnings before anything
  # fails — measured on the first real walk, where a 4.2.0 -> 5.0.7.2 rung's eleven controller
  # failures were filed as "… upgrade failed: DEPRECATION WARNING: Accessing mime types via
  # constants is deprecated", the title every 5.0 rung in every application would get, and the
  # one the corpus then compares a new finding against. The `problem` still says the output
  # *began* with the warning, because it did; only the title names what broke.
  def test_a_suite_that_opens_with_warnings_is_titled_by_its_first_failing_example
    tail = [
      "DEPRECATION WARNING: Accessing mime types via constants is deprecated",
      "DEPRECATION WARNING: `config.static_cache_control` is deprecated",
      "",
      "  1) BidsController POST #create redirects to the correct url",
      "     Failure/Error: expect(response).to redirect_to(bid_path(id))",
      "",
      "201 examples, 11 failures",
      "",
      "Failed examples:",
      "",
      "rspec ./spec/controllers/bids_controller_spec.rb:82 # BidsController POST #create"
    ].join("\n")

    payload = AgentsFyi::Upgrader::Filing.report_for(record: suite_failed_record(tail: tail))

    assert_includes payload["title"], "rspec ./spec/controllers/bids_controller_spec.rb:82"
    refute_includes payload["title"], "DEPRECATION WARNING"
    assert_includes payload["problem"], "DEPRECATION WARNING"
    assert_includes payload["trace"], "201 examples, 11 failures"
  end

  # **A rung that carried one change names it, even when the failure's text does not.**
  # There is only one documented change the step could have been about, and the report's
  # library, subject, kind and replacement are the plan's facts rather than a traceback guess.
  def test_a_failed_step_files_the_change_the_rung_names
    payload = AgentsFyi::Upgrader::Filing.report_for(
      record: suite_failed_record(changes: [change])
    )

    assert_equal "actionpack", payload["library"], "the report names the meta-gem, not the change's component"
    assert_equal "before_filter", payload["subject"]
    assert_equal "symbol_renamed", payload["change_kind"]
    assert_equal "before_action", payload["replacement"]
    assert_equal "platform", payload["subject_kind"]
  end

  # **A failure's own output is the first place to look.** With several changes on the rung, the
  # one the output names is the one the report is about; the others are not evidence for it.
  def test_a_failure_that_names_its_change_picks_that_change_from_several
    record = suite_failed_record(
      changes: [change(subject: "before_filter", component: "actionpack"),
                change(subject: "update_attributes", component: "activerecord",
                  replacement: "update", change_key: "ruby|activerecord|update_attributes")],
      tail: "NoMethodError: undefined method `update_attributes` for Item\n"
    )

    payload = AgentsFyi::Upgrader::Filing.report_for(record: record)

    assert_equal "activerecord", payload["library"]
    assert_equal "update_attributes", payload["subject"]
    assert_equal "symbol_renamed", payload["change_kind"]
    assert_equal "update", payload["replacement"]
  end

  # **`default_changed` has no `change_kind` in the corpus's enum, and that is not a reason to
  # drop the subject.** The key does not include the kind, so the report still joins the change;
  # a guessed kind would put a default flip in the rename family.
  def test_a_default_change_files_its_subject_with_no_change_kind
    payload = AgentsFyi::Upgrader::Filing.report_for(
      record: suite_failed_record(changes: [change(subject: "belongs_to", kind: "default_changed",
        component: "activerecord", replacement: nil,
        change_key: "ruby|activerecord|belongs_to")])
    )

    assert_equal "belongs_to", payload["subject"]
    assert_nil payload["change_kind"]
    assert_nil payload["replacement"]
    assert_equal "activerecord", payload["library"]
  end

  # **A scan decision can name the change even when the plan did not.** The scan starts below the
  # rung, so an earlier rung's call site is located here; one distinct subject is the change the
  # failure is about, and its library falls back to `rails` because no component was declared.
  def test_a_decision_names_the_change_when_the_plan_did_not
    decision = AgentsFyi::Upgrader::Record::Decision.new(
      subject: "find_all_by_name", reason: "located here", kind: "removed",
      replacement: "where", source: "4.0", path: "app/models/item.rb", line: 3
    )
    record = suite_failed_record(changes: []).tap { |value| value.decisions << decision }

    payload = AgentsFyi::Upgrader::Filing.report_for(record: record)

    assert_equal "find_all_by_name", payload["subject"]
    assert_equal "symbol_removed", payload["change_kind"]
    assert_equal "where", payload["replacement"]
    assert_equal "rails", payload["library"], "a change with no component was attributed to one"
  end

  # The working copy's path is different on every run, so a failure met in two checkouts
  # has to read as the same failure — otherwise the corpus files it twice and the title
  # carries a string nobody can search for.
  def test_the_evidence_filed_carries_no_working_copy_path
    worktree = "/tmp/upgrader-2f8c1a/worktrees/storefront-9f2c1ab8"
    payload = AgentsFyi::Upgrader::Filing.report_for(record: suite_failed_record(worktree: worktree))

    assert_includes payload["trace"], "store.rb:12:in `valid?'",
      "the fixture no longer carries a path, so this test is about nothing"
    [payload["title"], payload["problem"], payload["trace"]].each do |field|
      refute_includes field, worktree, "the per-run working copy path was filed"
      refute_includes field, "/tmp/upgrader-2f8c1a"
    end
    assert_includes payload["trace"], "<worktree>/app/models/store.rb:12"
  end

  # When a command the step cannot continue past fails, that command is the evidence — and
  # the order this is chosen in is the order `Record.verdict` names it in, so the sentence
  # a reader gets from the verdict and the text filed here are about the same command.
  def test_a_failed_command_is_what_gets_filed_when_a_required_stage_failed
    tail = "Bundler could not find compatible versions for gem \"rails\":\n  " \
           "In Gemfile:\n    rails (= 7.1.0)"
    record = record_for(
      verdict: Failed,
      stages: [command(stage: "pin", command: "bundle update rails", exit_code: 6, output_tail: tail),
               command(stage: "suite", command: "bundle exec rspec", ran: false, exit_code: nil,
                 output_tail: "the bundle never resolved")]
    )

    payload = AgentsFyi::Upgrader::Filing.report_for(record: record)

    assert_includes payload["problem"], "`bundle update rails` exited 6"
    assert_includes payload["trace"], "could not find compatible versions"
    assert_equal record.stages.first, AgentsFyi::Upgrader::Filing.failing_stage(record: record)
  end

  # **A report names the command the application was asked to run, not the machine that ran it.**
  # Measured on the deployment's first filed report, whose `problem` opened with `docker exec
  # --interactive --user 10003:999 --workdir /agents-fyi/targets/d474c93c65cbf4bb/tree -e
  # BUNDLE_PATH=… <container> bundle update rails … --conservative` — a reader wading through a uid, a
  # container id and a bundle path to reach "the pin exited 7", which is the fact the report exists to
  # carry. The machine's own argv is *not* lost: it is the record's `command`, which the run's page and
  # the API's `argv` still read, and this asserts that too.
  def test_a_report_names_the_command_the_application_ran_rather_than_the_machine_that_ran_it
    wrapper = "docker exec --interactive --user 10003:999 --workdir /agents-fyi/targets/deadbeef/tree " \
              "-e BUNDLE_PATH=/agents-fyi/bundles/deadbeef/2.1 " \
              "-e BUNDLE_GEMFILE=/agents-fyi/targets/deadbeef/tree/Gemfile " \
              "9c0ffee bundle update rails --conservative"
    record = record_for(
      verdict: Failed,
      stages: [AgentsFyi::Upgrader::Record::Command.new(
        stage: "pin", command: wrapper, display: "bundle update rails --conservative",
        ran: true, exit_code: 7, seconds: 1.0, output_tail: "Could not find gem 'cancan'."
      )]
    )

    payload = AgentsFyi::Upgrader::Filing.report_for(record: record)

    assert_includes payload["problem"], "`bundle update rails --conservative` exited 7"
    refute_includes payload["problem"], "docker exec",
      "the report named the machine's wrapper rather than the command: #{payload["problem"]}"
    assert_includes payload["attempted"], "`bundle update rails --conservative` exited 7"
    refute_includes payload["attempted"], "docker exec",
      "the report's own account of what it did named the wrapper: #{payload["attempted"]}"
    assert_equal wrapper, record.stages.first.command,
      "the machine's own argv was dropped from the record, which is the half a machine reads"
  end

  # The draft is derived from the submission rather than written a second time, so the two
  # cannot disagree about what happened — and it carries none of the fields the comparison
  # would refuse.
  def test_the_precheck_draft_is_the_submission_minus_what_the_comparison_does_not_read
    payload = AgentsFyi::Upgrader::Filing.report_for(record: suite_failed_record)
    draft = AgentsFyi::Upgrader::Filing.precheck_payload(payload)

    assert_equal payload["title"], draft["title"]
    assert_equal payload["trace"], draft["trace"]
    refute draft.key?("attempted")
    refute draft.key?("environment")
    assert_empty draft.keys - AgentsFyi::Upgrader::Filing::PRECHECK_FIELDS
  end

  # **The structured fields are in the draft as well as the write.** They do not move the
  # comparison — the service reads title, library, version, problem, resolution and trace — but a
  # draft that omitted them would describe the report by different fields than the write does.
  def test_the_precheck_draft_carries_the_structured_change_fields_without_moving_the_verdict
    payload = AgentsFyi::Upgrader::Filing.report_for(
      record: suite_failed_record(changes: [change])
    )
    draft = AgentsFyi::Upgrader::Filing.precheck_payload(payload)

    assert_equal "before_filter", draft["subject"]
    assert_equal "symbol_renamed", draft["change_kind"]
    assert_equal "before_action", draft["replacement"]
    assert_equal "actionpack", draft["library"]
    assert_equal "platform", draft["subject_kind"]
  end

  # **A failure an accepted `expect` rule named is not new evidence.** It is skipped rather than
  # filed, and the reason names the rule's decision so the run's own record can be read against it.
  def test_a_failure_a_rule_expected_is_not_filed_as_a_new_report
    rule = { "decision_id" => "d-expect", "change_key" => "ruby|actionpack|before_filter",
             "kind" => "expect", "payload" => { "failure" => "NameError: uninitialized constant Store::TAX" } }
    record = suite_failed_record(changes: [change], fired_rules: [rule])
    corpus = FakeCorpus.new

    result = AgentsFyi::Upgrader::Filing.file(corpus: corpus, record: record)

    assert_equal "skipped", result.action
    assert_includes result.reason, "expected"
    assert_includes result.reason, "d-expect"
    assert_nil corpus.prechecked, "an expected failure was compared as if it were new"
    assert_nil corpus.submitted
  end

  # A rule that names a different failure is still in force and has not fired; the report is filed.
  def test_an_expect_rule_for_another_failure_does_not_suppress_this_one
    rule = { "decision_id" => "d-expect", "change_key" => "ruby|actionpack|before_filter",
             "kind" => "expect", "payload" => { "failure" => "a failure this run did not meet" } }
    record = suite_failed_record(changes: [change], fired_rules: [rule])
    corpus = FakeCorpus.new

    result = AgentsFyi::Upgrader::Filing.file(corpus: corpus, record: record)

    assert_equal "filed", result.action
    refute_nil corpus.prechecked
  end

  def test_a_new_verdict_files_it
    corpus = FakeCorpus.new(verdict: "new")

    result = AgentsFyi::Upgrader::Filing.file(corpus: corpus, record: suite_failed_record)

    assert_equal "filed", result.action
    assert result.filed?
    assert_equal "report-1", result.report_id
    assert_equal "rails", corpus.submitted["library"]
  end

  # `similar` is filed, and that is the whole reason this is a list rather than a single
  # value: it is the verdict for a finding close to something recorded without being close
  # enough to refuse, and a client that stopped at `new` would decline exactly what the
  # duplicate rule has just said is distinct.
  def test_a_similar_verdict_is_still_filed
    corpus = FakeCorpus.new(verdict: "similar")

    assert_equal "filed", AgentsFyi::Upgrader::Filing.file(corpus: corpus, record: suite_failed_record).action
    refute_nil corpus.submitted
  end

  # The corpus already having this is the ordinary answer, not a failure — and the useful
  # thing to do next is verify the report it names, so the id is carried out in the result.
  def test_a_duplicate_verdict_files_nothing_and_names_the_report_to_read
    corpus = FakeCorpus.new(verdict: "duplicate", candidates: [{ "id" => "report-9" }])

    result = AgentsFyi::Upgrader::Filing.file(corpus: corpus, record: suite_failed_record)

    assert_equal "not_filed", result.action
    assert_equal "report-9", result.report_id
    assert_nil corpus.submitted, "a duplicate was submitted anyway"
    assert_includes result.reason, "duplicate"
  end

  # Two callers can pass the precheck together, and the corpus's answer at the write is the
  # one that counts. Nothing is retried: the report exists, which is all filing wanted.
  def test_a_collision_at_the_write_is_still_an_answer_rather_than_a_crash
    corpus = FakeCorpus.new(verdict: "new", report: { "duplicate" => true, "detail" => "already recorded" })

    result = AgentsFyi::Upgrader::Filing.file(corpus: corpus, record: suite_failed_record)

    assert_equal "duplicate", result.action
    assert_includes result.reason, "already recorded"
  end
end
