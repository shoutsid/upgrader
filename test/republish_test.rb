# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "agents/upgrader"

# **A delivered pull request's body can be rewritten from its record without walking again.** The
# record the step wrote carries the brief, the stages, the applied edits and the decisions the body
# is composed from; this test drives the reconstruction and the publish call.
class RepublishTest < Minitest::Test
  Republish = Agents::Upgrader::Republish
  Record = Agents::Upgrader::Record
  Ledger = Agents::Upgrader::Ledger
  Brief = Agents::Upgrader::Brief

  class FakePublish
    attr_reader :calls

    def initialize(**kwargs)
      @kwargs = kwargs
      (@calls ||= [])
    end

    def call
      self.class.calls << @kwargs
      Agents::Upgrader::Publish::Result.new(pushed: true, branch: "b",
        base: "main", commit: @kwargs[:commit], pull_request: "https://github.com/acme/app/pull/1",
        reason: "")
    end

    def self.calls = @calls ||= []
  end

  # A publisher that only performs the body-only half, and the service half of the presentation
  # read. What the test needs to see is which editorial was passed and that the applied digest went
  # back to the service.
  class FakeUpdatePublish
    class << self
      attr_accessor :calls, :update_calls
    end

    def initialize(**kwargs)
      @kwargs = kwargs
      self.class.calls << kwargs
    end

    def update_only(current_base: nil, expected_body_digest: nil)
      self.class.update_calls << { current_base: current_base,
                                   expected_body_digest: expected_body_digest }
      Agents::Upgrader::Publish::Result.new(pushed: true, branch: "b", base: "main",
        commit: @kwargs[:commit], pull_request: "https://github.com/acme/app/pull/1",
        body_updated: true, reason: "")
    end

    def preview_body = "## Summary\n\nA lead from the consultant.\n\n## What moved"
  end

  class FakeCorpus
    attr_reader :applied

    def initialize(presentation)
      @presentation = presentation
      @applied = []
    end

    def presentation(_run_id) = @presentation

    def presentation_applied(run_id, applied_digest:)
      @applied << [run_id, applied_digest]
      { "state" => "applied" }
    end
  end

  REPO = "https://github.com/acme/app.git"

  def test_every_delivered_passed_entry_is_republished_from_its_record
    Dir.mktmpdir do |home|
      FakePublish.calls.clear
      ledger = Ledger.new(path: File.join(home, "ledger.json"), machine: "ruby 3.3")
      ledger.record(repo: REPO, commit: "base123", from_version: "4.0.0", to_version: "4.1.0",
        verdict: "passed")
      ledger.deliver(repo: REPO, commit: "base123", from_version: "4.0.0", to_version: "4.1.0",
        state: { "attempted" => true, "delivered" => true, "root" => home,
                 "commit" => "produced1", "branch_pattern" => "agents/upgrade-<release>",
                 "base_ref" => "agents/baseline",
                 "pull_request" => "https://github.com/acme/app/pull/1" })

      brief = Brief::Result.new(
        sections: [Brief::Section.new(key: "framework", title: "The framework move",
          question: "what moved", state: "answers", items: [Brief::Item.new(id: "r1",
            title: "a known failure", match: "signature")], total: 1)],
        asked: 1, truncated: false, unavailable: 0
      )
      record = Record.new(repository: REPO, commit: "base123", from_version: "4.0.0",
        to_version: "4.1.0", verdict: "passed", why: "the suite was green",
        machine: "ruby 3.3", interpreter: "ruby 3.3.12", brief: brief,
        stages: [Record::Command.new(stage: "suite", command: "docker exec -e SECRET=x bundle exec rspec",
          display: "bundle exec rspec", ran: true, exit_code: 0, seconds: 1.0)],
        applied: [Agents::Upgrader::Applier::Applied.new(path: "app/x.rb", line: 1,
          text: "old", after: "new", origin: "companion")],
        decisions: [Record::Decision.new(path: "app/y.rb", line: 2, subject: "button_to",
          reason: "the call site")],
        commits: [{ "concern" => "pin Rails", "commit" => "c" * 40, "message" => "the pin" }],
        accepted_decisions: [{ "id" => "d1", "question" => "Vendor the gem?",
          "answer" => "vendor it", "accepted_by" => "operator:1",
          "effects" => [{ "kind" => "patch" }] }],
        patch: "diff")
      stem = Record.stem(REPO, "4.0.0", "4.1.0")
      FileUtils.mkdir_p(File.join(home, "records"))
      File.write(File.join(home, "records", "#{stem}.json"), JSON.generate(record.to_h))

      results = Republish.new(home: home, token: "t", ledger: ledger,
        publish_class: FakePublish).call

      assert_equal 1, results.length
      call = FakePublish.calls.first
      assert_equal "produced1", call[:commit]
      assert_equal "agents/baseline", call[:base_ref]
      assert_equal "bundle exec rspec", call[:record].stages.first.readable
      assert_equal "companion", call[:record].applied.first.origin
      assert_equal "app/y.rb", call[:record].decisions.first.path
      assert_includes call[:record].brief.to_markdown, "a known failure"
      refute_includes call[:record].stages.first.readable, "SECRET"
      # **The reconstruction is the whole record, not the fields the body used to read.** A hand-
      # rebuilt record dropped these three, and the bodies it published said a record with a
      # concern-commit series had none and lost the accepted decision's question.
      assert_equal ["pin Rails"], call[:record].commits.map { |commit| commit["concern"] }
      assert_equal "Vendor the gem?", call[:record].accepted_decisions.first["question"]
      assert_equal "the suite was green", call[:record].why
    end
  end

  def test_a_drafted_presentation_updates_the_body_without_pushing
    Dir.mktmpdir do |home|
      FakeUpdatePublish.calls = []
      FakeUpdatePublish.update_calls = []
      ledger = Ledger.new(path: File.join(home, "ledger.json"), machine: "ruby 3.3")
      ledger.record(repo: REPO, commit: "base123", from_version: "4.0.0", to_version: "4.1.0",
        verdict: "passed")
      ledger.deliver(repo: REPO, commit: "base123", from_version: "4.0.0", to_version: "4.1.0",
        state: { "attempted" => true, "delivered" => true, "root" => home,
                 "commit" => "produced1", "branch_pattern" => "agents/upgrade-<release>",
                 "base" => "main", "base_ref" => "agents/baseline", "run_id" => "run-1",
                 "brief_digest" => Digest::SHA256.hexdigest("the body the walker wrote"),
                 "pull_request" => "https://github.com/acme/app/pull/1" })

      record = Record.new(repository: REPO, commit: "base123", from_version: "4.0.0",
        to_version: "4.1.0", verdict: "passed", why: "the suite was green",
        machine: "ruby 3.3", interpreter: "ruby 3.3.12", patch: "diff")
      stem = Record.stem(REPO, "4.0.0", "4.1.0")
      FileUtils.mkdir_p(File.join(home, "records"))
      File.write(File.join(home, "records", "#{stem}.json"), JSON.generate(record.to_h))

      corpus = FakeCorpus.new({ "state" => "drafted", "run_id" => "run-1",
        "editorial" => "## Summary\n\nA lead.",
        "body_override" => "## Summary\n\nA lead.\n\n## What moved\n\nThe narrative.",
        "task_id" => "t1", "model" => "provider/model",
        "prompt_version" => "presenter-prompt-2" })
      results = Republish.new(home: home, token: "t", ledger: ledger, corpus: corpus,
        publish_class: FakeUpdatePublish).apply_presentations(repository: REPO)

      assert_equal 1, results.length
      kwargs = FakeUpdatePublish.calls.first
      assert_equal "## Summary\n\nA lead.", kwargs[:editorial]
      assert_includes kwargs[:body_override], "The narrative."
      assert_equal Digest::SHA256.hexdigest("the body the walker wrote"),
        kwargs[:expected_body_digest]
      assert_equal "main", FakeUpdatePublish.update_calls.first[:current_base]
      entry = ledger.entries.first
      assert_equal "applied", entry.delivery.dig("presentation", "state")
      assert_includes entry.delivery["brief"], "A lead from the consultant"
      assert_equal 1, corpus.applied.length
      assert_equal "run-1", corpus.applied.first.first
    end
  end
end
