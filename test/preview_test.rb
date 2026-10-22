# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "agents_fyi/upgrader"

# A dry run of the review brief: a stored record is rendered as the pull request body it would
# have produced, with no checkout, token or push. This is the replay seam the next walk is
# reviewed through.
class PreviewTest < Minitest::Test
  Record = AgentsFyi::Upgrader::Record
  Command = AgentsFyi::Upgrader::Record::Command
  Checks = AgentsFyi::Upgrader::Checks
  Preview = AgentsFyi::Upgrader::Preview

  def record
    Record.new(
      repository: "https://github.com/acme/storefront", commit: "abc12345",
      from_version: "5.2.0", to_version: "6.0.0", verdict: "passed",
      why: "the suite was green before this step and green after it",
      interpreter: "ruby 3.3.12", image: "agentsfyi-upgrader:dev",
      machine: "ruby 3.3.12 (agentsfyi-upgrader:dev@sha256:#{"a" * 64})", era: "3.3",
      stages: [
        Command.new(stage: "baseline", command: "bundle exec rspec", ran: true, exit_code: 0,
          seconds: 20.0, output_tail: "10 examples, 0 failures"),
        Command.new(stage: "suite", command: "bundle exec rspec", ran: true, exit_code: 0,
          seconds: 21.0, output_tail: "10 examples, 0 failures")
      ],
      checks: [
        Checks::Result.new(id: "lint", kind: "lint", command: "bundle exec rubocop",
          required: true, external: false, status: "passed", ran: true, exit_code: 0,
          seconds: 3.0),
        Checks::Result.new(id: "ci", name: "GitHub Actions: test", kind: "external",
          required: true, external: true, status: "external", ran: false,
          reason: "the application's CI runs it")
      ],
      commits: [{ "concern" => "pin Rails and move gems", "commit" => "b" * 40,
                  "message" => "agents-fyi upgrader: the 5.2.0 -> 6.0.0 step — pin Rails and move gems" }],
      app_update: { "adopt" => "added_only", "adopted" => ["config/initializers/new.rb"],
                    "conflicts" => ["config/application.rb"], "skipped" => [],
                    "framework_defaults" => "off", "load_defaults" => "5.2" },
      accepted_decisions: [{ "id" => "d1", "question" => "Remove the Show link?",
                             "answer" => "remove it", "accepted_by" => "operator:9f2c",
                             "effects" => [{ "kind" => "patch" }] }],
      toolchain: { "ruby" => "3.3.12", "postgres" => "pgvector/pgvector:pg16" },
      project: { "slug" => "storefront", "source_roots" => ["app", "lib"] }
    )
  end

  def test_a_stored_record_renders_the_review_brief_without_a_push
    body = Preview.render(record, base_ref: "agents-fyi/upgrade-5.2.0",
      report_base: "https://agents.example")

    assert_includes body, "## What moved"
    assert_includes body, "5.2.0 → 6.0.0"
    assert_includes body, "## Checks"
    assert_includes body, "external — not run here"
    assert_includes body, "## Decisions in force"
    assert_includes body, "Remove the Show link?"
    assert_includes body, "## app:update"
    assert_includes body, "config/initializers/new.rb"
    assert_includes body, "## Review and merge"
    assert_includes body, "agents-fyi/upgrade-5.2.0"
    assert_includes body, "<details>"
    assert_includes body, "Full run record"
  end

  # **The pin line is the attempt that succeeded.** The 4.1 rung's first two pin stages exited
  # 6 and the sixth exited 0, but the body used `find` and quoted the first failure as *the*
  # pin. A reviewer read a failed command under a `passed` verdict.
  def test_the_pin_line_quotes_the_attempt_that_succeeded
    data = record
    data.stages << Command.new(stage: "pin", command: "bundle update rails",
      ran: true, exit_code: 6, seconds: 1.0, output_tail: "conflict")
    data.stages << Command.new(stage: "pin",
      command: "bundle update rails actionpack activesupport --conservative",
      ran: true, exit_code: 0, seconds: 2.0, output_tail: "Bundle updated!")

    body = Preview.render(data, base_ref: "master")

    assert_includes body, "Rails pin: `bundle update rails actionpack activesupport --conservative` — exit 0"
    refute_includes body, "Rails pin: `bundle update rails` — exit 6"
  end

  def test_the_preview_reads_the_json_the_step_writes
    body = Preview.from_json(record.to_json, base_ref: "main")

    assert_includes body, "## What moved"
    assert_includes body, "bundle exec rubocop"
    assert_includes body, "pin Rails and move gems"
  end

  # **The service's run shape is a record too.** It names `repo_url` and `commands`, not
  # `repository` and `stages`; treating it as an empty local record would render "suite not
  # declared" and "risk: low" over a run whose verdict is `failed`.
  def test_a_service_run_envelope_is_normalised_rather_than_read_as_an_empty_record
    service = {
      "run" => { "repo_url" => "https://github.com/acme/storefront",
                 "commit" => "abc12345", "from_version" => "5.2.0", "to_version" => "6.0.0",
                 "verdict" => "failed", "note" => "the suite failed after a green baseline" },
      "commands" => [
        { "stage" => "baseline", "argv" => "bundle exec rspec", "exit_code" => 0,
          "stdout_tail" => "10 examples, 0 failures", "duration_ms" => 1000 },
        { "stage" => "suite", "argv" => "bundle exec rspec", "exit_code" => 1,
          "stdout_tail" => "1 example failed", "duration_ms" => 2000 }
      ],
      "refusals" => [{ "subject" => "button_to", "note" => "a person's change" }]
    }

    body = Preview.from_json(JSON.generate(service))

    assert_includes body, "5.2.0 → 6.0.0"
    assert_includes body, "| suite | failed |"
    assert_includes body, "the suite failed after a green baseline"
    assert_includes body, "a person's change"
    refute_includes body, "Risk:** low",
      "a failed service run was previewed as a low-risk pass"
  end

  # A record with a stage but no duration is still renderable; the missing field is zero seconds,
  # not a crash in the evidence line.
  def test_a_stage_with_no_seconds_still_renders
    hash = record.to_h
    hash["stages"] = [{ "stage" => "baseline", "command" => "bundle exec rspec",
                        "ran" => true, "exit_code" => 0 }]
    hash["baseline"] = nil
    hash["suite"] = nil

    body = Preview.from_json(JSON.generate(hash))

    assert_includes body, "0.0s"
  end

  def test_a_malformed_record_is_refused_with_a_sentence
    error = assert_raises(ArgumentError) do
      Preview.from_json(JSON.generate(
        "repository" => "https://github.com/acme/storefront", "from_version" => "5.2.0",
        "to_version" => "6.0.0", "verdict" => "passed", "stages" => "oops"
      ))
    end

    assert_includes error.message, "stages"

    error = assert_raises(ArgumentError) do
      Preview.from_json(JSON.generate(
        "repository" => "https://github.com/acme/storefront", "from_version" => "5.2.0",
        "to_version" => "6.0.0", "verdict" => "passed", "stages" => [nil]
      ))
    end
    assert_includes error.message, "stages"
  end
end
