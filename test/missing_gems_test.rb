# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "agents_fyi/upgrader"

# The boot failure a move can cause without touching the application: a dependency that used to
# provide a gem stops, and the application's own Require was the only declaration there ever was.
class MissingGemsTest < Minitest::Test
  # What the base commit ran with: `devise-two-factor 4.1.0` pulls `attr_encrypted 4.2.0` in, and
  # nothing else in the lockfile mentions it.
  BEFORE = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        attr_encrypted (4.2.0)
          encryptor (~> 3.0.0)
        devise-two-factor (4.1.0)
          attr_encrypted (>= 1.3, < 5, != 2)
          railties (>= 4.0)
        railties (7.0.10)

    PLATFORMS
      ruby

    DEPENDENCIES
      devise-two-factor (= 4.1.0)
      rails (= 7.0.10)

    BUNDLED WITH
       2.5.22
  LOCK

  # What the pin left: the gem's new major version no longer depends on it, so the resolver is
  # free to drop it — and did.
  AFTER = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        devise-two-factor (6.3.1)
          railties (>= 7.1)
        railties (7.1.6)

    PLATFORMS
      ruby

    DEPENDENCIES
      devise-two-factor (= 6.3.1)
      rails (= 7.1.6)

    BUNDLED WITH
       2.5.22
  LOCK

  GEMFILE = <<~RUBY
    source "https://rubygems.org"

    gem "rails", "7.0.10"
    gem "devise-two-factor", "4.1.0"
    gem "pg"
  RUBY

  # The boot's own last lines, because that is what the caller has: the stage's output tail.
  BOOT = <<~TEXT
    bin/rails aborted!
    LoadError: cannot load such file -- attr_encrypted (LoadError)
    /agents-fyi/tree/app/models/user.rb:7:in `<top (required)>'
    /agents-fyi/tree/config/routes.rb:126:in `block in <top (required)>'
    Tasks: TOP => environment
    (See full trace by running task with --trace)
  TEXT

  def test_a_gem_the_pin_stopped_providing_is_declared_at_the_version_the_base_commit_ran
    in_tree do |root|
      edit = repair(root)

      refute_nil edit, "the boot's LoadError names a gem the base lockfile carried"
      assert_equal "Gemfile", edit["path"]
      assert_equal true, edit["automatic"]
      assert_includes edit["after"], "gem \"attr_encrypted\", \"4.2.0\""
      assert_includes edit["note"], "attr_encrypted 4.2.0"
      assert_match(/\A\s*gem "pg"/, edit["text"],
        "the line before the insertion is the Gemfile's own, because the applier compares it")
    end
  end

  # The whole point of going through the applier is that the line it writes is the line it read.
  def test_the_declaration_written_by_the_applier_is_a_gem_line_the_bundle_can_install
    in_tree do |root|
      result = AgentsFyi::Upgrader::Applier.new(root).apply([repair(root)])

      assert_empty result.refused, "the applier refused the declaration"
      assert_equal 1, result.applied.length
      written = File.read(File.join(root, "Gemfile"))
      assert_includes written, "\ngem \"attr_encrypted\", \"4.2.0\"\n"
      assert_operator written.index("gem \"attr_encrypted\""), :>, written.index("gem \"pg\""),
        "the declaration belongs after the gem list, not before it"
    end
  end

  def test_a_gem_the_gemfile_already_declares_is_not_this_repairs
    in_tree(gemfile: "#{GEMFILE}gem \"attr_encrypted\", \"~> 4.2\"\n") do |root|
      assert_nil repair(root)
    end
  end

  # A LoadError with the gem still in the lock is a fact about the install rather than about the
  # pin — a group the suite does not load, an `install` that failed — and a second Gemfile line
  # would not be its answer.
  def test_a_gem_still_in_the_current_lockfile_is_not_missing_from_the_bundle
    in_tree(after: <<~LOCK) do |root|
      GEM
        remote: https://rubygems.org/
        specs:
          attr_encrypted (4.2.0)
          devise-two-factor (6.3.1)
          railties (7.1.6)

      PLATFORMS
        ruby

      DEPENDENCIES
        devise-two-factor (= 6.3.1)
        rails (= 7.1.6)

      BUNDLED WITH
         2.5.22
    LOCK
      assert_nil repair(root)
    end
  end

  # Ruby's standard library and an application's own `lib/` both answer this message, and neither
  # has a version the base lockfile could name.
  def test_a_require_that_names_no_gem_in_the_base_lockfile_is_left_alone
    in_tree do |root|
      output = "LoadError: cannot load such file -- racc (LoadError)"
      assert_nil AgentsFyi::Upgrader::MissingGems.for(output: output, root: root, lock: base_lock(root))
    end
  end

  # RubyGems and Ruby disagree about the spelling: the gem is `activesupport` and the require is
  # `active_support/core_ext`, and a comparison of the two as text finds nothing.
  def test_a_require_path_matches_the_gem_whose_name_spells_it_differently
    in_tree(before: <<~LOCK) do |root|
      GEM
        remote: https://rubygems.org/
        specs:
          activesupport (7.0.10)
          rails (7.0.10)

      PLATFORMS
        ruby

      DEPENDENCIES
        rails (= 7.0.10)

      BUNDLED WITH
         2.5.22
    LOCK
      edit = AgentsFyi::Upgrader::MissingGems.for(
        output: "LoadError: cannot load such file -- active_support/core_ext/object (LoadError)",
        root: root, lock: base_lock(root)
      )

      refute_nil edit
      assert_includes edit["after"], "gem \"activesupport\", \"7.0.10\""
    end
  end

  def test_a_gemfile_with_no_gem_line_has_no_place_this_family_inserts_into
    in_tree(gemfile: "source \"https://rubygems.org\"\n") do |root|
      assert_nil repair(root)
    end
  end

  private

  def repair(root)
    AgentsFyi::Upgrader::MissingGems.for(output: BOOT, root: root, lock: base_lock(root))
  end

  def in_tree(gemfile: GEMFILE, before: BEFORE, after: AFTER)
    Dir.mktmpdir do |root|
      File.write(File.join(root, "Gemfile"), gemfile)
      File.write(File.join(root, "Gemfile.lock"), after)
      File.write(File.join(root, "Gemfile.lock.before"), before)
      yield root
    end
  end

  # The parse the step holds from before the pin, read out of the same tree so a test that wants a
  # different base writes one.
  def base_lock(root)
    AgentsFyi::Upgrader::Lockfile.new(path: File.join(root, "Gemfile.lock.before"), root: root)
  end
end
