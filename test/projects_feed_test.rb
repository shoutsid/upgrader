# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "agents/upgrader"

# **The site admin cannot read the walker's built-in declarations, so the walker writes the catalogue.**
# What is pinned here is that every declaration is listed, including the built-in lighthouse, and
# that each says where it came from — the page offers "save a copy" only for the built-ins.
class ProjectsFeedTest < Minitest::Test
  Feed = Agents::Upgrader::ProjectsFeed

  def test_the_feed_lists_the_built_ins_and_the_site_admin_copies_with_their_source
    Dir.mktmpdir do |home|
      dir = File.join(home, "projects")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "site_admin.json"), JSON.generate(
        "slug" => "site_admin", "repo" => "acme/site-admin", "from" => "7.0.0", "to" => "7.1.0",
        "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" }
      ))
      saved = ENV["UPGRADER_PROJECTS_DIR"]
      ENV["UPGRADER_PROJECTS_DIR"] = dir

      entries = Feed.new(home: home).write

      assert_equal %w[lighthouse site_admin], entries.map { |entry| entry["slug"] }.sort
      lighthouse = entries.find { |entry| entry["slug"] == "lighthouse" }
      site_admin = entries.find { |entry| entry["slug"] == "site_admin" }
      assert_equal "built-in", lighthouse["source"]
      assert_equal "site_admin", site_admin["source"]
      assert_equal "shoutsid/biddingapp", lighthouse["fields"]["repo"]
      assert File.file?(Feed.path(home))
      assert_equal 2, JSON.parse(File.read(Feed.path(home))).fetch("projects").length
    ensure
      ENV["UPGRADER_PROJECTS_DIR"] = saved
    end
  end
end
