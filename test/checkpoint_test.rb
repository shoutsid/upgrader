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

  # **The 4.1 rung's defect, held as a test.** `assets:precompile` runs before the first
  # checkpoint, and `git add --all` cannot tell its `public/assets` from the application's
  # source. The 29,758 generated lines in PR #55 were this exact shape: a pre-pin jQuery and
  # jQuery UI bundle, its gzip siblings, and a manifest whose CSS named images the commit did
  # not carry. A build output is not a step's change; it must stay on disk for the suite and
  # out of the commit, and the tree must still read clean.
  def test_generated_build_outputs_are_not_committed_and_do_not_make_the_tree_dirty
    FileUtils.mkdir_p(File.join(@dir, "public", "assets"))
    asset = File.join(@dir, "public", "assets", "application-generated.js")
    File.write(asset, "// compiled before the pin\n")

    refute Checkpoint.dirty?(@dir), "a build output made the tree look dirty"

    File.write(File.join(@dir, "Gemfile"), %(gem "rails", "5.0.0"\n))
    commit = Checkpoint.commit(@dir, from: "4.2.11", to: "5.0.0", out: StringIO.new)

    files = git("show", "--name-only", "--format=", commit).lines.map(&:strip)
    assert_includes files, "Gemfile"
    refute_includes files, "public/assets/application-generated.js",
      "a generated asset entered the step's commit"
    assert File.file?(asset), "the generated asset was removed before the suite could use it"
    refute Checkpoint.dirty?(@dir), "the ignored build output still makes the tree dirty"
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

  # **The patch machinery marks a new file intent-to-add, and a reset has to clear that too.**
  # Measured on the 6.0 rung: the step failed, `app:update` had created
  # `config/initializers/new_framework_defaults_6_0.rb` and an ActiveStorage migration, the loop said
  # the tree was "back at its base commit" — and both files were still there. The reason is the
  # record's own patch: it is built with `git add --intent-to-add --all` (`Step#patch`), which is a
  # path the *index* knows, and `git clean -fd` removes untracked paths only. The next attempt's patch
  # then refused to apply ("already exists in working directory"), which is how it was found — and a
  # 6.0-only initializer sitting in a tree that claims to be 5.2 is exactly the quiet wrongness the
  # kept-tree rule exists to prevent.
  def test_a_reset_clears_an_addition_the_patch_machinery_marked_intent_to_add
    FileUtils.mkdir_p(File.join(@dir, "config", "initializers"))
    File.write(File.join(@dir, "config", "initializers", "new_framework_defaults_6_0.rb"),
      "# app:update's addition, as the patch machinery makes it visible\n")
    git("add", "--intent-to-add", "--all")

    Checkpoint.reset(@dir)

    refute File.exist?(File.join(@dir, "config", "initializers", "new_framework_defaults_6_0.rb")),
      "a file the patch machinery marked intent-to-add survived the reset"
    refute dirty?, "the tree is still dirty after a reset: #{git("status", "--porcelain")}"
  end

  def test_the_message_names_both_releases
    assert_equal "agents-fyi upgrader: the 7.1.0 -> 7.2.0 step, as this tool made it",
      Checkpoint.message(from: "7.1.0", to: "7.2.0")
  end

  # **A failed step's concern commits are the step's too.** A step that commits its pin and then
  # fails the suite has moved HEAD; a reset that only cleans the worktree leaves the next cycle
  # planning from the half-move. `reset(to:)` puts HEAD back at the commit the rung started from,
  # and still leaves the ignored bundle/tmp where it is.
  def test_reset_to_the_base_discards_the_step_s_commits_and_keeps_ignored_files
    base = git("rev-parse", "HEAD").strip
    File.write(File.join(@dir, "Gemfile"), %(gem "rails", "5.0.0"\n))
    File.write(File.join(@dir, "config_moved.rb"), "# app:update's addition\n")
    moved = Checkpoint.commit(@dir, from: "4.2.11", to: "5.0.0", out: StringIO.new)
    refute_equal base, moved

    Checkpoint.reset(@dir, to: base)

    assert_equal base, git("rev-parse", "HEAD").strip, "HEAD is still the step's commit"
    assert_equal %(gem "rails", "4.2.11"\n), File.read(File.join(@dir, "Gemfile"))
    refute File.exist?(File.join(@dir, "config_moved.rb")), "the step's added file survived"
    assert File.exist?(File.join(@dir, "tmp", "cache", "expensive")),
      "an ignored file was removed by the reset"
  end

  # **A concern is a commit a reviewer can read on its own.** The default message is still the whole
  # step, and a step that commits as it goes passes the concern so `git log` reads as a sequence of
  # concerns rather than one opaque commit.
  def test_a_concern_is_named_in_the_message
    assert_equal "agents-fyi upgrader: the 7.1.0 -> 7.2.0 step — pin Rails and move gems",
      Checkpoint.message(from: "7.1.0", to: "7.2.0", concern: "pin Rails and move gems")
  end
end
