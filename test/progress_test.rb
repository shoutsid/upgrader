# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
require "agents/upgrader"

# What the loop says about itself while it works, and the two properties a *reader* depends on.
#
# The reader is another process on another container, so the file has to be complete whenever it is
# seen and has to carry the instants rather than a duration — "3 minutes" would be wrong the moment
# it was read. Both are asserted here rather than left to the site admin: a half-written body would be
# an error on an operator's page, and a pre-computed duration would be a number that drifts.
class ProgressTest < Minitest::Test
  def home
    @home ||= Dir.mktmpdir("agents-progress")
  end

  def teardown
    FileUtils.remove_entry(home) if home && File.directory?(home)
  end

  def read
    JSON.parse(File.read(Agents::Upgrader::Progress.path(home)))
  end

  # The file is under `state/`, its own directory, because that is the directory the deployment
  # mounts into the site admin — the ledger and the working copies must not travel with it.
  def test_the_file_lives_under_the_state_directory
    assert_equal File.join(home, "state", "progress.json"),
      Agents::Upgrader::Progress.path(home)
  end

  def test_a_stage_carries_the_move_the_stage_and_what_it_was_asked_to_do
    Agents::Upgrader::Progress.new(home: home).stage(
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
    progress = Agents::Upgrader::Progress.new(home: home)
    3.times { |i| progress.stage(repo: "r", from: "a", to: "b", stage: "s#{i}", detail: "d") }

    assert_equal ["progress.json"], Dir.children(Agents::Upgrader::Progress.dir(home)).sort
  end

  # A loop between cycles is not a step, and saying so is the difference between "waiting" and
  # "stuck": the reader shows the note rather than the last stage that happened to finish.
  def test_a_cycle_says_the_loop_is_between_steps_and_names_no_move
    Agents::Upgrader::Progress.new(home: home).cycle(note: "between cycles — sleeping 600s")

    body = read
    assert_equal "cycle", body["stage"]
    assert_equal "between cycles — sleeping 600s", body["detail"]
    assert_nil body["to_version"], "a cycle named a move it is not making"
  end

  # **The timeline is the answer to "how far did it get".** One stage at a time could not tell a
  # step that had run four stages from one that had just started, so every command now starts and
  # finishes an event carrying its own exit code and duration.
  def test_a_finished_command_closes_its_event_with_its_exit_code_and_duration
    progress = Agents::Upgrader::Progress.new(home: home)
    progress.stage(repo: "r", from: "4.2.11", to: "4.2.12", stage: "pin",
      detail: "bundle update rails", kind: "patch")
    progress.finish(stage: "pin", status: "failed", exit_code: 6, duration_ms: 1250)

    body = read
    assert_equal 2, body["version"]
    assert_equal "patch", body["kind"]
    event = body["events"].last
    assert_equal "pin", event["stage"]
    assert_equal "failed", event["status"]
    assert_equal 6, event["exit_code"]
    assert_equal 1250, event["duration_ms"]
    refute_nil event["finished_at"]
  end

  # A writer that names a status this reader does not know has not established a pass.
  def test_an_unknown_status_is_recorded_as_skipped_not_passed
    progress = Agents::Upgrader::Progress.new(home: home)
    progress.stage(repo: "r", from: "a", to: "b", stage: "pin", detail: "unknown")
    progress.finish(stage: "pin", status: "mystery")

    assert_equal "skipped", read["events"].last["status"]
  end

  # **A retry is a second attempt, not a second stage.** The attempt number is what makes a sequence
  # readable, and a stage that starts again without its predecessor finishing is recorded as
  # `skipped` rather than as a pass nobody measured.
  def test_a_retry_is_a_new_attempt_and_an_unfinished_stage_is_not_a_pass
    progress = Agents::Upgrader::Progress.new(home: home)
    progress.stage(repo: "r", from: "a", to: "b", stage: "pin", detail: "attempt one")
    progress.stage(repo: "r", from: "a", to: "b", stage: "pin", detail: "attempt two")

    pin_events = read["events"].select { |event| event["stage"] == "pin" }
    assert_equal [1, 2], pin_events.map { |event| event["attempt"] }
    assert_equal "skipped", pin_events.first["status"]
    assert_nil pin_events.first["exit_code"], "an unfinished command was given an exit code"
  end

  # A bounded timeline, because a pathological step must not grow the operator's file without limit.
  def test_the_timeline_is_bounded
    progress = Agents::Upgrader::Progress.new(home: home)
    (Agents::Upgrader::Progress::MAX_EVENTS + 5).times do |index|
      progress.stage(repo: "r", from: "a", to: "b", stage: "s#{index}", detail: "d")
    end

    assert_equal Agents::Upgrader::Progress::MAX_EVENTS, read["events"].size
  end

  # **No output ever reaches this file.** It is a page a person reads, and a suite's output can
  # contain anything it printed; the run record carries the evidence.
  def test_the_timeline_carries_no_command_output
    progress = Agents::Upgrader::Progress.new(home: home)
    progress.stage(repo: "r", from: "a", to: "b", stage: "suite", detail: "bundle exec rspec")
    progress.finish(stage: "suite", status: "passed", exit_code: 0, duration_ms: 200)

    event = read["events"].last
    refute event.key?("stdout")
    refute event.key?("stderr")
    refute event.key?("argv")
  end

  def test_clearing_removes_the_view_rather_than_leaving_a_stale_one
    progress = Agents::Upgrader::Progress.new(home: home)
    progress.stage(repo: "r", from: "a", to: "b", stage: "s", detail: "d")
    progress.clear

    refute File.exist?(Agents::Upgrader::Progress.path(home)),
      "a cleared view still reads as work in flight"
    progress.clear # and clearing twice is not an error
  end
end
