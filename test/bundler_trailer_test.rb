# frozen_string_literal: true

require "minitest/autorun"
require "agents_fyi/upgrader"

# The trailer that stops an era installing an application, driven against real lockfiles.
#
# Measured at the 7.2 rung, the first on the 3.2 era: RubyGems reads the lock's `BUNDLED WITH`, installs
# the version it names, restarts into it, and that version cannot run — `undefined method `untaint' for
# an instance of Pathname` from bundler 1.17.3's own `shared_helpers.rb:29`. Dropping the trailer lets
# the era's own bundler read the lock and write its version back.
class BundlerTrailerTest < Minitest::Test
  BundlerTrailer = AgentsFyi::Upgrader::BundlerTrailer

  LOCK = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        rails (7.1.0)

    DEPENDENCIES
      rails (= 7.1.0)

    BUNDLED WITH
       1.17.3
  LOCK

  # **The trailer is the last thing in the file, and only the last thing.** A `BUNDLED WITH` line
  # anywhere else is not the trailer, and a version line elsewhere in the lock belongs to a gem.
  def test_the_trailer_is_dropped_and_everything_else_is_left
    after = BundlerTrailer.drop(LOCK)

    refute_nil after, "a lock with a trailer has something to drop"
    refute_includes after, "BUNDLED WITH"
    refute_includes after, "1.17.3"
    assert_includes after, "rails (7.1.0)"
    assert_includes after, "DEPENDENCIES"
    assert_equal "1.17.3", BundlerTrailer.version(LOCK)
  end

  # A lock without one is "nothing to drop" rather than "nothing to say", so the caller does not ask the
  # machine a question it does not need answered.
  def test_a_lock_with_no_trailer_is_left_alone
    assert_nil BundlerTrailer.drop("GEM\n  remote: https://rubygems.org/\n")
    assert_nil BundlerTrailer.version("GEM\n")
  end

  # **The line has to be the trailer's own.** A gem named `BUNDLED` or a version that happens to sit on
  # its own line is not it, and a rewrite that guessed would edit somebody's lock in the middle.
  def test_a_bundled_with_that_is_not_the_trailer_is_not_dropped
    text = "GEM\n  specs:\n    bundled_with (1.0.0)\n\nBUNDLED WITH\n   2.4.22\n\nextra\n"

    after = BundlerTrailer.drop(text)

    assert_nil after, "the trailer is not at the end of this file, so there is none to drop"
  end
end
