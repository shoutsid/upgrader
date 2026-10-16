# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "stringio"
require "tmpdir"
require "agents_fyi/upgrader"

# The two things that decide whether a walk can move: what a step leaves behind when it
# passed, and what it leaves behind when it did not.
#
# Written as tests of `git` on a real tree rather than against a double, because that is
# all this module is — and because the interesting rule is the one the reset must *not*
# do: `clean -fd` and not `clean -fdx`, so the installed bundle and the application's
# `tmp/` survive a step being thrown away. That distinction is invisible in a unit test
# that does not have ignored files in it.
class CheckpointTest < Minitest::Test
  Checkpoint = AgentsFyi::Upgrader::Checkpoint

  def setup
    @dir = Dir.mktmpdir
    File.write(File.join(@dir, ".gitignore"), "tmp/\nlog/\n.bundle/\n")
    File.write(File.join(@dir, "Gemfile"), %(gem "rails", "4.2.11"\n))
    FileUtils.mkdir_p(File.join(@dir, "tmp", "cache"))
    File.write(File.join(@dir, "tmp", "cache", "expensive"), "the installed bundle lives here\n")
    git("init", "--quiet")
    git("add", "--all")
    git("-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "--quiet", "-m", "base")
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def git(*argv)
    output, status = Open3.capture2e("git", "-C", @dir, *argv)
    assert status.success?, "git #{argv.join(' ')} failed: #{output}"
    output
  end

  def dirty?
    !git("status", "--porcelain").strip.empty?
  end

  def test_a_clean_tree_is_not_dirty_and_a_step_s_edits_are
    refute Checkpoint.dirty?(@dir)

    File.write(File.join(@dir, "Gemfile"), %(gem "rails", "5.0.0"\n))

    assert Checkpoint.dirty?(@dir)
  end

  # What a passing step leaves: one commit, whose message names the move rather than this
  # tool, because `git log` on a kept tree is how an operator reads what it has been
  # through.
  def test_a_passing_step_is_committed_as_the_move_it_made
    File.write(File.join(@dir, "Gemfile"), %(gem "rails", "5.0.0"\n))
    File.write(File.join(@dir, "config_moved.rb"), "# app:update's addition\n")

    commit = Checkpoint.commit(@dir, from: "4.2.11", to: "5.0.0", out: StringIO.new)

    refute_nil commit
    assert_equal commit, git("rev-parse", "HEAD").strip
    assert_includes git("log", "-1", "--format=%s"), "the 4.2.11 -> 5.0.0 step"
    refute Checkpoint.dirty?(@dir), "the step's files were not all committed"
  end

  # A step can pass without changing the tree — a scan with no edits, a pin already at the
  # target — and git refusing an empty commit is not a failure here: the current HEAD *is*
  # the base for the next step.
  def test_a_step_that_changed_nothing_keeps_the_commit_it_started_from
    before = git("rev-parse", "HEAD").strip

    commit = Checkpoint.commit(@dir, from: "4.2.11", to: "5.0.0", out: StringIO.new)

    assert_equal before, commit
  end

  # What a step that did not pass leaves: the base commit, with the application's files
  # restored and the step's additions gone — and the *ignored* half untouched, because
  # putting the bundle and `tmp/` back is the expensive thing this deliberately does not do.
  def test_a_step_that_did_not_pass_is_reset_without_touching_what_is_ignored
    File.write(File.join(@dir, "Gemfile"), %(gem "rails", "5.0.0"\n))
    File.write(File.join(@dir, "config_moved.rb"), "# app:update's addition\n")
    FileUtils.mkdir_p(File.join(@dir, "log"))
    File.write(File.join(@dir, "log", "development.log"), "not ignored by this fixture\n")

    Checkpoint.reset(@dir)

    assert_equal %(gem "rails", "4.2.11"\n), File.read(File.join(@dir, "Gemfile"))
    refute File.exist?(File.join(@dir, "config_moved.rb")), "the step's addition survived the reset"
    refute dirty?, "the tree is still dirty after a reset"
    assert File.file?(File.join(@dir, "tmp", "cache", "expensive")),
      "the reset deleted an ignored file, which is the installed bundle's shape"
    assert File.file?(File.join(@dir, "log", "development.log")),
      "the reset deleted an ignored log file"
  end

  def test_the_message_names_both_releases
    assert_equal "agents-fyi upgrader: the 7.1.0 -> 7.2.0 step, as this tool made it",
      Checkpoint.message(from: "7.1.0", to: "7.2.0")
  end
end
