# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "agents_fyi/upgrader"

# The delivery feed is a list, replaced one move at a time, and it is read by another process. What
# is pinned here is what a reader relies on: one entry per move, a later attempt replacing its own
# row, and a corrupt file reading as empty rather than as a site admin error.
class DeliveriesTest < Minitest::Test
  Deliveries = AgentsFyi::Upgrader::Deliveries

  REPO = "https://github.com/shoutsid/biddingapp"

  def feed(home) = Deliveries.new(home: home)

  def test_one_entry_per_move_and_a_later_attempt_replaces_its_own
    Dir.mktmpdir do |home|
      feed(home).record(repo: REPO, from_version: "5.2.0", to_version: "6.0.0",
        delivery: { "delivered" => false, "reason" => "no route to host" })
      feed(home).record(repo: REPO, from_version: "6.0.0", to_version: "6.1.0",
        delivery: { "delivered" => true, "pull_request" => "https://github.com/x/y/pull/9" })
      feed(home).record(repo: REPO, from_version: "5.2.0", to_version: "6.0.0",
        delivery: { "delivered" => true, "pull_request" => "https://github.com/x/y/pull/8" })

      entries = feed(home).entries
      assert_equal 2, entries.length
      replaced = entries.find { |entry| entry["to_version"] == "6.0.0" }
      assert_equal true, replaced["delivered"]
      assert_equal "https://github.com/x/y/pull/8", replaced["pull_request"]
      refute_empty replaced["updated_at"]
    end
  end

  # The reader is the site admin, on another container, at any moment: a partially written file is a
  # stale line, not an exception.
  def test_a_corrupt_file_reads_as_empty
    Dir.mktmpdir do |home|
      FileUtils.mkdir_p(File.join(home, "state"))
      File.write(File.join(home, "state", "deliveries.json"), "{not json")

      assert_empty feed(home).entries
      assert_equal [], feed(home).entries
    end
  end
end
