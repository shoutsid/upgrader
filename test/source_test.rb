# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents/upgrader"

# Where a step's working copies and bundles live, and what happens to the ones whose run is
# over. A gemset is per-run on purpose — a killed step must not leave a half-installed one for
# the next run to trust — and the price is that nothing ever asks for the directory again.
# The walker's home is the bind mount every step's container is given, so what accumulates there
# is paid at `docker run`: measured, twenty seconds to five minutes.
class SourceTest < Minitest::Test
  Source = Agents::Upgrader::Source

  # The machine a step runs on, as `bundle_env` needs it: an era names the image, and an image is one
  # ruby. A host machine has no era and is named by its interpreter instead.
  Machine = Struct.new(:era, :interpreter)
  def machine_double(era: "2.5", interpreter: "ruby 2.5.9") = Machine.new(era, interpreter)

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

  # **A bundle command's environment carries the build flag for nokogiri, and it is the environment the
  # real class builds.** Driven on `Source` itself rather than through a double, because a double that
  # carried the flag would make this pass while the walker sent nothing — which is the shape of test
  # that holds a bug in place. The measurement behind it is in `bundle_env`'s own comment: on the share
  # `install -c` of a multi-megabyte file is refused, so nokogiri's vendored libxml2 cannot be installed
  # there, and the image already ships the libraries it would vendor.
  def test_every_bundle_command_builds_nokogiri_against_the_image_s_own_libraries
    worktree = Source.new(root: @home, commit: "abc12345", description: "fixture", home: @home)

    env = worktree.bundle_env(machine: machine_double)

    assert_equal "--use-system-libraries", env["BUNDLE_BUILD__NOKOGIRI"],
      "a bundle installed without this builds nokogiri's own libxml2 and dies on the share"
    assert_equal File.join(@home, "Gemfile"), env["BUNDLE_GEMFILE"]
    assert_equal "development", env["BUNDLE_WITHOUT"]
  end

  # **Two eras never share a bundle.** Measured at the 7.0 rung: the path was keyed by the working copy
  # alone, so the 2.7 era's `bundle install` loaded an extension the 2.5 era had built —
  # `LoadError: libruby.so.2.5: cannot open shared object file: No such file or directory`, from
  # `bundles/<key>/gems/strscan-3.1.8/lib/strscan.so` — and every era after the first then failed the
  # machine probe with it, because the probe *is* a `bundle install` and the failure reads as "no
  # interpreter installed the application's bundle". A gem *cache* may be shared; the tree a gem is
  # unpacked into and executed from may not.
  def test_two_eras_never_share_a_bundle_path
    worktree = Source.new(root: @home, commit: "abc12345", description: "fixture", home: @home)

    older = worktree.bundle_env(machine: machine_double(era: "2.5"))["BUNDLE_PATH"]
    newer = worktree.bundle_env(machine: machine_double(era: "2.7"))["BUNDLE_PATH"]

    refute_equal older, newer, "two eras were given one gemset"
    assert_includes older, "2.5"
    assert_includes newer, "2.7"
    assert_equal newer, worktree.bundle_env(machine: machine_double(era: "2.7"))["BUNDLE_PATH"],
      "the same era has to keep its own bundle across the steps of a walk"

    # And a machine with no era — the host, in `rvm` mode — is named by its interpreter, whose spaces
    # do not reach the path.
    host = worktree.bundle_env(machine: machine_double(era: nil, interpreter: "ruby 3.3.12"))["BUNDLE_PATH"]
    assert_includes host, "ruby-3.3.12"
    refute_includes host, " "
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
