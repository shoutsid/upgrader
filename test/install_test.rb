# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

# **The era image's `install`, driven as the program a gem's Makefile calls.**
#
# Docker Desktop's bind mounts refuse the `chmod` that `install -c -m` performs for a file of a few
# megabytes — the shape of every native extension a build installs. Measured on the lighthouse's 6.0
# rung: `sassc`'s 3.2 MB `libsass.so` failed with `Operation not permitted` while a three-byte file in
# the same directory installed cleanly and `cp` plus `chmod` on the large one succeeded
# (`images/install.rb` carries the measurements and the paragraph).
#
# The file is a program rather than a shell function for the same reason `dbconfig.rb` is: the
# fallback is a rule, and a rule inside a shell heredoc is a rule no test can run. The seam is an
# environment variable the test points at a double, because on a host where the real `install` works
# the fallback is unreachable otherwise.
class InstallTest < Minitest::Test
  SHIM = File.expand_path("../images/install.rb", __dir__)

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def run_shim(argv, real:)
    out, status = Open3.capture2e({ "AGENTS_INSTALL_REAL" => real }, "ruby", SHIM, *argv)
    [out, status.exitstatus]
  end

  def source(name, content = "x" * 3)
    path = File.join(@dir, name)
    File.write(path, content)
    path
  end

  def destination
    File.join(@dir, "out").tap { |path| FileUtils.mkdir_p(path) }
  end

  # The real one working is the normal case on every local filesystem, and the fallback must not touch
  # anything when it does: the double copies nothing, so a destination that exists could only have been
  # written by the fallback.
  def test_the_real_install_is_used_when_it_works
    out, status = run_shim(["-c", "-m", "0755", source("libsass.so"), destination], real: "/bin/true")

    assert_equal 0, status, out
    refute File.exist?(File.join(destination, "libsass.so")),
      "the fallback ran although the real install succeeded"
  end

  # The measured failure: the real one cannot set the mode, and what a build depends on is that the
  # file arrives with the mode the Makefile asked for.
  def test_the_fallback_copies_and_sets_the_mode_when_the_real_install_cannot
    src = source("libsass.so")

    out, status = run_shim(["-c", "-m", "0755", src, destination], real: "/bin/false")

    assert_equal 0, status, out
    target = File.join(destination, "libsass.so")
    assert_equal File.read(src), File.read(target)
    assert_equal 0o755, File.stat(target).mode & 0o777
  end

  # A flag the fallback does not know is the real `install`'s business: a wrong success would be worse
  # than the real one's failure, so the caller sees exactly that failure.
  def test_an_unknown_flag_is_refused_rather_than_guessed_at
    out, status = run_shim(["-b", "-m", "0755", source("libsass.so"), destination], real: "/bin/false")

    assert_equal 1, status, out
    refute File.exist?(File.join(destination, "libsass.so")),
      "a flag this file does not know was answered anyway"
  end
end
