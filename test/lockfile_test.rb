# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "agents/upgrader"

# Reading an application's own file, because everything downstream is a statement
# about the version this returns.
class LockfileTest < Minitest::Test
  RAILS_APP = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        actionpack (4.2.11)
          actionview (= 4.2.11)
        actionview (4.2.11)
        rails (4.2.11)
          actionpack (= 4.2.11)
          actionview (= 4.2.11)

    PLATFORMS
      ruby

    DEPENDENCIES
      rails (= 4.2.11)

    RUBY VERSION
       ruby 2.7.8p225

    BUNDLED WITH
       2.5.22
  LOCK

  COMPONENTS_ONLY = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        activerecord (5.2.8)
          activesupport (= 5.2.8)
        activesupport (5.2.8)
        railties (5.2.8)
          activesupport (= 5.2.8)

    PLATFORMS
      ruby

    DEPENDENCIES
      railties

    BUNDLED WITH
       2.5.22
  LOCK

  # The shape a real application's lockfile has: the meta-gem pins its components at its own
  # version, and the gems it depends on that are *not* components are pinned elsewhere.
  FRAMEWORK = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        actionpack (4.0.0.rc1)
          activesupport (= 4.0.0.rc1)
        activesupport (4.0.0.rc1)
        rails (4.0.0.rc1)
          actionpack (= 4.0.0.rc1)
          railties (= 4.0.0.rc1)
          sprockets-rails (~> 2.0.0)
        railties (4.0.0.rc1)
        rake (10.0.4)
        sprockets-rails (2.0.0)

    PLATFORMS
      ruby

    DEPENDENCIES
      rails (= 4.0.0.rc1)
  LOCK

  NO_RAILS = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        rake (13.0.6)

    PLATFORMS
      ruby

    DEPENDENCIES
      rake

    BUNDLED WITH
       2.5.22
  LOCK

  # A lockfile that vendors a gem names a relative remote, and Bundler resolves that
  # against the application's root — which it takes from `BUNDLE_GEMFILE`, not from
  # the parser. huginn at `v2022.01.04`, the first real repository this was pointed
  # at, vendors dotenv exactly this way; no fixture here did until it did.
  VENDORED = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        actionpack (6.0.4.4)
        rails (6.0.4.4)
          actionpack (= 6.0.4.4)

    PATH
      remote: vendor/gems/dotenv-2.0.1
      specs:
        dotenv (2.0.1)

    PLATFORMS
      ruby

    DEPENDENCIES
      dotenv!
      rails (= 6.0.4.4)

    BUNDLED WITH
       2.5.22
  LOCK

  VENDORING_GEMFILE = %(source "https://rubygems.org"
gem "rails", "6.0.4.4"
gem "dotenv", path: "vendor/gems/dotenv-2.0.1"
)

  def with_lockfile(text, gemfile: nil, dot_ruby: nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), text)
      File.write(File.join(dir, "Gemfile"), gemfile) if gemfile
      File.write(File.join(dir, ".ruby-version"), dot_ruby) if dot_ruby
      yield Agents::Upgrader::Lockfile.read(dir)
    end
  end

  def test_the_meta_gem_names_the_release_when_the_application_pins_it
    with_lockfile(RAILS_APP) do |lockfile|
      assert_equal "rails", lockfile.rails.gem
      assert_equal "4.2.11", lockfile.rails_version
    end
  end

  # **A lockfile spells "the framework" as the gems pinned at the meta-gem's own version.**
  # Rails releases its components in lockstep, so this is the set that has to move with the
  # meta-gem — and the gems that merely depend on them (`rake`, `sprockets-rails`) are not in
  # it. The pin names exactly these in its `bundle update`, and nothing else.
  def test_the_gems_pinned_at_the_framework_s_version_are_the_framework
    with_lockfile(FRAMEWORK) do |lockfile|
      assert_equal %w[actionpack activesupport rails railties], lockfile.pinned_at("4.0.0.rc1")
      assert_empty lockfile.pinned_at("4.1.0")
    end
  end

  # An application that pins the framework as components still pins `railties`, and
  # its version is the Rails version. Reading `activerecord` instead would be right
  # by accident here and wrong for an application that held one component back.
  def test_an_application_that_pins_components_is_read_from_railties
    with_lockfile(COMPONENTS_ONLY) do |lockfile|
      assert_equal "railties", lockfile.rails.gem
      assert_equal "5.2.8", lockfile.rails_version
    end
  end

  def test_an_application_with_no_rails_pinned_is_not_guessed_at
    with_lockfile(NO_RAILS) do |lockfile|
      assert_nil lockfile.rails
      assert_nil lockfile.rails_version
    end
  end

  # Three different statements about the interpreter, kept apart because they mean
  # different things: what the lockfile resolved under, what the Gemfile requires,
  # and what a developer had installed.
  def test_the_three_ruby_versions_are_reported_separately
    gemfile = %(source "https://rubygems.org"\nruby "2.7.8"\ngem "rails", "4.2.11"\n)
    with_lockfile(RAILS_APP, gemfile: gemfile, dot_ruby: "2.7.8\n") do |lockfile|
      assert_equal "2.7.8p225", lockfile.locked_ruby
      assert_equal "2.7.8", lockfile.declared_ruby
      assert_equal "2.7.8", lockfile.dot_ruby_version
    end
  end

  def test_nothing_pins_ruby_when_nothing_does
    with_lockfile(COMPONENTS_ONLY) do |lockfile|
      assert_nil lockfile.locked_ruby
      assert_nil lockfile.declared_ruby
      assert_nil lockfile.dot_ruby_version
    end
  end

  def test_a_lockfile_that_vendors_a_gem_is_read_against_the_application_root
    with_lockfile(VENDORED, gemfile: VENDORING_GEMFILE) do |lockfile|
      assert_equal "6.0.4.4", lockfile.rails_version
      assert_equal "2.0.1", lockfile.specs["dotenv"]
    end
  end

  # The root is process-global, so the read has to hand it back: left set, the next
  # application read in this process would resolve its own relative remotes against
  # this one's directory — and `serve` reads many applications in one process.
  def test_the_application_root_is_handed_back_after_a_read
    before = ENV.fetch("BUNDLE_GEMFILE", nil)
    read_root = nil
    with_lockfile(VENDORED, gemfile: VENDORING_GEMFILE) do |lockfile|
      assert_equal "6.0.4.4", lockfile.rails_version
      read_root = lockfile.root
    end

    # `assert_equal nil, …` is deprecated, and "unset" is the common case here.
    if before.nil?
      assert_nil ENV["BUNDLE_GEMFILE"]
    else
      assert_equal before, ENV["BUNDLE_GEMFILE"]
    end
    refute_equal File.join(read_root, "Gemfile"), bundler_gemfile_now
  end

  # The same property from the other side, and the one a leak would show up as: a
  # vendored lockfile with no Gemfile beside it has no root Bundler may use, so it
  # fails rather than borrowing the application read a moment ago. A test that only
  # checked the environment variable would pass while Bundler's own memo still held
  # the last root.
  def test_a_vendored_lockfile_with_no_gemfile_is_not_read_against_the_last_one
    with_lockfile(VENDORED, gemfile: VENDORING_GEMFILE) { |_lockfile| nil }

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), VENDORED)

      assert_raises(Agents::Upgrader::Lockfile::Unreadable) do
        Agents::Upgrader::Lockfile.read(dir)
      end
    end
  end

  # What Bundler currently believes its Gemfile is, or a note that it has none — the
  # reader of a shared process has to come back to where it started, whatever that
  # was.
  def bundler_gemfile_now
    Bundler.default_gemfile.to_s
  rescue Bundler::GemfileNotFound
    "(none)"
  end

  def test_a_directory_with_no_lockfile_says_so_rather_than_returning_nothing
    Dir.mktmpdir do |dir|
      error = assert_raises(Agents::Upgrader::Lockfile::Missing) do
        Agents::Upgrader::Lockfile.read(dir)
      end

      assert_includes error.message, "no Gemfile.lock"
    end
  end
end
