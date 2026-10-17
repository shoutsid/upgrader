# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents_fyi/upgrader"

# Where a step's working copies and bundles live, and what happens to the ones whose run is
# over. A gemset is per-run on purpose — a killed step must not leave a half-installed one for
# the next run to trust — and the price is that nothing ever asks for the directory again.
# The walker's home is the bind mount every step's container is given, so what accumulates there
# is paid at `docker run`: measured, twenty seconds to five minutes.
class SourceTest < Minitest::Test
  Source = AgentsFyi::Upgrader::Source

  def setup
    @home = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@home) if File.directory?(@home)
  end

  # A run directory and the bundle its key names, as a finished run leaves them.
  def run_with_bundle(run)
    root = File.join(@home, "work", "abc123", "run-#{run}")
    FileUtils.mkdir_p(root)
    bundle = File.join(@home, "bundles", Digest::SHA256.hexdigest(root)[0, 16])
    FileUtils.mkdir_p(File.join(bundle, "gems"))
    [root, bundle]
  end

  def dead_pid
    pid = Process.spawn("true")
    Process.wait(pid)
    pid
  end

  # The rule is the container reap's, one layer down: a run directory's name carries the pid that
  # owns it, so a run whose process is gone is a run whose bundle nothing will ask for again.
  def test_the_bundle_of_a_run_that_is_over_is_pruned_and_a_live_run_s_is_not
    _live_root, live_bundle = run_with_bundle("20261017203314-#{Process.pid}")
    _dead_root, dead_bundle = run_with_bundle("20261017203314-#{dead_pid}")

    removed = Source.prune_bundles(home: @home)

    assert_equal [dead_bundle], removed
    refute File.exist?(dead_bundle), "a finished run's bundle was left behind"
    assert File.directory?(live_bundle), "a live run's bundle was removed"
  end

  # `targets/` holds the tree a walk keeps across its own cycles. It is not a run, so it has no
  # pid to be judged by — and its bundle is the reuse the whole `serve` mode is built around.
  def test_a_kept_tree_s_bundle_is_never_pruned
    tree = File.join(@home, "targets", "abc123", "tree")
    FileUtils.mkdir_p(tree)
    bundle = File.join(@home, "bundles", Digest::SHA256.hexdigest(tree)[0, 16])
    FileUtils.mkdir_p(bundle)

    assert_empty Source.prune_bundles(home: @home)
    assert File.directory?(bundle), "the kept tree's bundle was removed"
  end

  # A directory whose name does not carry a pid is left alone: this removes what it can
  # attribute, and a guess is how a live bundle is deleted.
  def test_a_run_directory_this_cannot_attribute_is_left_alone
    _root, bundle = run_with_bundle("something-else")

    assert_empty Source.prune_bundles(home: @home)
    assert File.directory?(bundle)
  end
end
