# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
require "agents_fyi/upgrader"

# What the loop says about itself while it works, and the two properties a *reader* depends on.
#
# The reader is another process on another container, so the file has to be complete whenever it is
# seen and has to carry the instants rather than a duration — "3 minutes" would be wrong the moment
# it was read. Both are asserted here rather than left to the site admin: a half-written body would be
# an error on an operator's page, and a pre-computed duration would be a number that drifts.
class ProgressTest < Minitest::Test
  def home
    @home ||= Dir.mktmpdir("agents-fyi-progress")
  end

  def teardown
    FileUtils.remove_entry(home) if home && File.directory?(home)
  end

  def read
    JSON.parse(File.read(AgentsFyi::Upgrader::Progress.path(home)))
  end

  # The file is under `state/`, its own directory, because that is the directory the deployment
  # mounts into the site admin — the ledger and the working copies must not travel with it.
  def test_the_file_lives_under_the_state_directory
    assert_equal File.join(home, "state", "progress.json"),
      AgentsFyi::Upgrader::Progress.path(home)
  end

  def test_a_stage_carries_the_move_the_stage_and_what_it_was_asked_to_do
    AgentsFyi::Upgrader::Progress.new(home: home).stage(
      repo: "https://github.com/acme/storefront", from: "4.0.0", to: "4.1.0",
      commit: "9f2c1ab8", era: "2.1", stage: "pin",
      detail: "bundle update rails --conservative", note: "resolving"
    )

    body = read
    assert_equal "pin", body["stage"]
    assert_equal "bundle update rails --conservative", body["detail"]
    assert_equal "4.0.0", body["from_version"]
    assert_equal "4.1.0", body["to_version"]
    assert_equal "2.1", body["era"]
    assert_equal "9f2c1ab8", body["commit"]
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, body["started_at"],
      "the stage's start is not an instant a reader can subtract its own clock from")
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, body["updated_at"])
  end

  # **No temporary file is ever left behind.** The write goes through `<pid>.tmp` and a rename, so a
  # reader sees a whole body or the previous one — and the temporary name must not accumulate in a
  # directory an operator is watching.
  def test_the_write_leaves_nothing_beside_the_file
    progress = AgentsFyi::Upgrader::Progress.new(home: home)
    3.times { |i| progress.stage(repo: "r", from: "a", to: "b", stage: "s#{i}", detail: "d") }

    assert_equal ["progress.json"], Dir.children(AgentsFyi::Upgrader::Progress.dir(home)).sort
  end

  # A loop between cycles is not a step, and saying so is the difference between "waiting" and
  # "stuck": the reader shows the note rather than the last stage that happened to finish.
  def test_a_cycle_says_the_loop_is_between_steps_and_names_no_move
    AgentsFyi::Upgrader::Progress.new(home: home).cycle(note: "between cycles — sleeping 600s")

    body = read
    assert_equal "cycle", body["stage"]
    assert_equal "between cycles — sleeping 600s", body["detail"]
    assert_nil body["to_version"], "a cycle named a move it is not making"
  end

  def test_clearing_removes_the_view_rather_than_leaving_a_stale_one
    progress = AgentsFyi::Upgrader::Progress.new(home: home)
    progress.stage(repo: "r", from: "a", to: "b", stage: "s", detail: "d")
    progress.clear

    refute File.exist?(AgentsFyi::Upgrader::Progress.path(home)),
      "a cleared view still reads as work in flight"
    progress.clear # and clearing twice is not an error
  end
end
