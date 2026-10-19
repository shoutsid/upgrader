# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "agents_fyi/upgrader"

# **The console cannot read the walker's built-in declarations, so the walker writes the catalogue.**
# What is pinned here is that every declaration is listed, including the built-in lighthouse, and
# that each says where it came from — the page offers "save a copy" only for the built-ins.
class ProjectsFeedTest < Minitest::Test
  Feed = AgentsFyi::Upgrader::ProjectsFeed

  def test_the_feed_lists_the_built_ins_and_the_console_s_copies_with_their_source
    Dir.mktmpdir do |home|
      dir = File.join(home, "projects")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "console.json"), JSON.generate(
        "slug" => "console", "repo" => "acme/console", "from" => "7.0.0", "to" => "7.1.0",
        "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" }
      ))
      saved = ENV["UPGRADER_PROJECTS_DIR"]
      ENV["UPGRADER_PROJECTS_DIR"] = dir

      entries = Feed.new(home: home).write

      assert_equal %w[console lighthouse], entries.map { |entry| entry["slug"] }.sort
      lighthouse = entries.find { |entry| entry["slug"] == "lighthouse" }
      console = entries.find { |entry| entry["slug"] == "console" }
      assert_equal "built-in", lighthouse["source"]
      assert_equal "console", console["source"]
      assert_equal "shoutsid/biddingapp", lighthouse["fields"]["repo"]
      assert File.file?(Feed.path(home))
      assert_equal 2, JSON.parse(File.read(Feed.path(home))).fetch("projects").length
    ensure
      ENV["UPGRADER_PROJECTS_DIR"] = saved
    end
  end
end
