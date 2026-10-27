# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "agents/upgrader"

# **The feed of host facts the service cannot query.** What is pinned here is the shape the site admin
# reads and the rule that a refusal is recorded as a reason: "no disk figure" and "plenty of disk"
# must not look the same.
class EnvironmentTest < Minitest::Test
  Environment = Agents::Upgrader::Environment

  def test_the_reading_carries_the_matrix_the_images_and_the_disk
    Dir.mktmpdir do |home|
      feed = Environment.new(home: home,
        matrix: -> { [{ "name" => "2.1", "ruby" => "2.1.10", "image" => "era:2.1" }] },
        images: ->(refs) { [refs.to_h { |ref| [ref, true] }, nil] },
        df: ->(path) { [{ "path" => path, "total_bytes" => 4_000, "free_bytes" => 1_000 }, nil] })

      feed.write

      read = JSON.parse(File.read(Environment.path(home)))
      assert_equal "2.1", read["eras"].first["name"]
      assert_equal true, read["images"]["era:2.1"]
      assert_equal 1_000, read["disk"]["free_bytes"]
      assert_nil read["disk_problem"]
      refute_empty read["read_at"]
    end
  end

  def test_a_refused_reading_is_a_reason_rather_than_an_absence
    Dir.mktmpdir do |home|
      feed = Environment.new(home: home,
        matrix: -> { [] },
        images: ->(_refs) { [{}, "no era image is declared"] },
        df: ->(_path) { [nil, "df exited 1: not found"] })

      feed.write

      read = JSON.parse(File.read(Environment.path(home)))
      assert_nil read["disk"]
      assert_equal "df exited 1: not found", read["disk_problem"]
      assert_equal "no era image is declared", read["images_problem"]
    end
  end
end
