# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "agents_fyi/upgrader"

# **A delivered pull request's body can be rewritten from its record without walking again.** The
# record the step wrote carries the brief, the stages, the applied edits and the decisions the body
# is composed from; this test drives the reconstruction and the publish call.
class RepublishTest < Minitest::Test
  Republish = AgentsFyi::Upgrader::Republish
  Record = AgentsFyi::Upgrader::Record
  Ledger = AgentsFyi::Upgrader::Ledger
  Brief = AgentsFyi::Upgrader::Brief

  class FakePublish
    attr_reader :calls

    def initialize(**kwargs)
      @kwargs = kwargs
      (@calls ||= [])
    end

    def call
      self.class.calls << @kwargs
      AgentsFyi::Upgrader::Publish::Result.new(pushed: true, branch: "b",
        base: "main", commit: @kwargs[:commit], pull_request: "https://github.com/acme/app/pull/1",
        reason: "")
    end

    def self.calls = @calls ||= []
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
                 "commit" => "produced1", "branch_pattern" => "agents-fyi/upgrade-<release>",
                 "base_ref" => "agents-fyi/baseline",
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
        applied: [AgentsFyi::Upgrader::Applier::Applied.new(path: "app/x.rb", line: 1,
          text: "old", after: "new", origin: "companion")],
        decisions: [Record::Decision.new(path: "app/y.rb", line: 2, subject: "button_to",
          reason: "the call site")],
        patch: "diff")
      stem = Record.stem(REPO, "4.0.0", "4.1.0")
      FileUtils.mkdir_p(File.join(home, "records"))
      File.write(File.join(home, "records", "#{stem}.json"), JSON.generate(record.to_h))

      results = Republish.new(home: home, token: "t", ledger: ledger,
        publish_class: FakePublish).call

      assert_equal 1, results.length
      call = FakePublish.calls.first
      assert_equal "produced1", call[:commit]
      assert_equal "agents-fyi/baseline", call[:base_ref]
      assert_equal "bundle exec rspec", call[:record].stages.first.readable
      assert_equal "companion", call[:record].applied.first.origin
      assert_equal "app/y.rb", call[:record].decisions.first.path
      assert_includes call[:record].brief.to_markdown, "a known failure"
      refute_includes call[:record].stages.first.readable, "SECRET"
    end
  end
end
