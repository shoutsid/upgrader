# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
require "agents_fyi/upgrader"

# **The walker's half of the site admin's switch.** A file the service writes, read before every
# command: the stop has to be a distinct exception so a step unwinds without recording a verdict,
# and an absent or corrupt file has to read as running — a switch that nobody can see must not
# silently halt a walk.
class ControlTest < Minitest::Test
  Control = AgentsFyi::Upgrader::Control

  def setup
    @saved = ENV["UPGRADER_PROJECTS_DIR"]
    @home = Dir.mktmpdir("walker-control")
    ENV.delete("UPGRADER_PROJECTS_DIR")
  end

  def teardown
    ENV["UPGRADER_PROJECTS_DIR"] = @saved unless @saved.nil?
    FileUtils.remove_entry(@home) if File.directory?(@home)
  end

  def control = Control.new(home: @home)

  def write(document)
    FileUtils.mkdir_p(File.join(@home, "projects"))
    File.write(File.join(@home, "projects", Control::FILE), JSON.generate(document))
  end

  def test_an_absent_switch_is_running
    refute control.stopped?
    assert_nil capture_check
  end

  def test_a_stop_request_is_read_with_its_reason
    write("state" => "stopped", "reason" => "clearing the queue")

    assert control.stopped?
    error = assert_raises(Control::Stopped) { control.check! }
    assert_includes error.message, "clearing the queue"
  end

  def test_a_resume_is_running_again
    write("state" => "stopped", "reason" => "clearing")
    assert control.stopped?

    write("state" => "running")
    refute Control.new(home: @home).stopped?
  end

  # The file is rewritten by the site admin between commands; a reader that cached by content
  # would be right, and one that cached for ever would never resume.
  def test_a_rewrite_is_picked_up_between_checks
    write("state" => "stopped")
    reader = control
    assert reader.stopped?

    write("state" => "running")
    refute reader.stopped?
  end

  def test_a_corrupt_file_reads_as_running_and_does_not_hide_the_walk
    FileUtils.mkdir_p(File.join(@home, "projects"))
    File.write(File.join(@home, "projects", Control::FILE), "{not json")

    refute control.stopped?
    assert_nil capture_check
  end

  def test_the_projects_directory_is_the_shared_one
    ENV["UPGRADER_PROJECTS_DIR"] = "/tmp/shared-projects"

    assert_equal "/tmp/shared-projects/#{Control::FILE}", Control.new(home: @home).path
  ensure
    ENV.delete("UPGRADER_PROJECTS_DIR")
  end

  # **A wake is a marker with a time, not a flag somebody has to clear.** The cycle in progress
  # compares it with its own start, so a write that lands after that cycle read its feed still
  # shortens the wait; a marker older than the cycle is already accounted for and must not keep
  # the loop awake.
  def test_a_wake_marker_only_wakes_a_cycle_that_started_before_it
    path = File.join(@home, "projects", Control::WAKE_FILE)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{}")
    File.utime(Time.at(1000), Time.at(2000), path)

    assert control.wake_since?(Time.at(1500))
    assert control.wake_since?(Time.at(2000)), "a coarse mtime at the cycle's start was lost"
    refute control.wake_since?(Time.at(2500))
  end

  def test_an_absent_wake_marker_is_no_wake
    refute control.wake_since?(Time.now)
  end

  def test_the_wake_marker_lives_beside_the_switch
    assert_equal File.join(@home, "projects", Control::WAKE_FILE), control.wake_path
  end

  private

  def capture_check
    control.check!
    nil
  rescue Control::Stopped => e
    e
  end
end
