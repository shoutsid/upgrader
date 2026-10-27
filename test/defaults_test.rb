# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents/upgrader"

# The new framework defaults, stepped one at a time.
#
# `app:update` writes `new_framework_defaults_<version>.rb` commented out on purpose — the guide's
# advice is to turn the defaults on one by one and read what each does. What is asserted here is the
# file's own shape: which lines are toggles, what Rails says above each of them, and the two edits
# that touch the application's tree (uncommenting one, and the guide's last step).
class DefaultsTest < Minitest::Test
  Defaults = Agents::Upgrader::Defaults

  FILE = <<~RUBY
    # Be sure to restart your server when you modify this file.
    #
    # This file contains migration options to ease your Rails 4.1 upgrade.

    # Enable per-form CSRF tokens. Previous versions had false.
    # Rails.application.config.action_controller.per_form_csrf_tokens = true

    # Enable origin-checking CSRF mitigation. Previous versions had false.
    # Rails.application.config.action_controller.forgery_protection_origin_check = true

    # Raise an error when a translation is missing. Previous versions had false.
    # Rails.application.config.i18n.raise_on_missing_translations = true
  RUBY

  APPLICATION = <<~RUBY
    require_relative "boot"

    module Storefront
      class Application < Rails::Application
        config.autoload_paths = []
      end
    end
  RUBY

  def setup
    @dirs = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def app(file: FILE, application: APPLICATION, name: "new_framework_defaults_4_1.rb")
    dir = Dir.mktmpdir
    @dirs << dir
    FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
    File.write(File.join(dir, "config", "initializers", name), file) if file
    File.write(File.join(dir, "config", "application.rb"), application) if application
    dir
  end

  def defaults(dir)
    Defaults.new(path: Defaults.file_in(dir), root: dir)
  end

  # The toggles are the commented statements, in the file's own order, each with Rails' own sentence
  # above it — which is what lets the record say *what* a default does rather than only that it moved.
  def test_the_toggles_are_the_commented_statements_with_their_own_notes
    toggles = defaults(app).toggles

    assert_equal 3, toggles.size
    assert_equal "Rails.application.config.action_controller.per_form_csrf_tokens", toggles.first.setting
    assert_equal "Enable per-form CSRF tokens. Previous versions had false.", toggles.first.note
    assert_equal 6, toggles.first.line
    assert_equal "Rails.application.config.i18n.raise_on_missing_translations", toggles.last.setting
  end

  # Enabling and putting back rewrite the one line, so a walk killed between them leaves the file it
  # had rather than half of both.
  def test_enabling_and_disabling_a_toggle_change_one_line
    dir = app
    found = defaults(dir)
    toggle = found.toggles.first

    found.enable(toggle)
    assert_includes File.read(File.join(dir, "config", "initializers", "new_framework_defaults_4_1.rb")),
      "\nRails.application.config.action_controller.per_form_csrf_tokens = true"
    assert_equal 2, found.toggles.size, "an enabled toggle is no longer a toggle"

    found.disable(toggle)
    assert_equal 3, found.toggles.size
  end

  # The guide's last step: the line goes inside the application's class, and a class line this does
  # not recognise is left alone rather than guessed at.
  def test_load_defaults_is_written_inside_the_application_class_and_never_guessed_at
    dir = app
    assert_equal "config.load_defaults 4.1", defaults(dir).load_defaults!("4.1.0")

    written = File.read(File.join(dir, "config", "application.rb"))
    assert_match(/class Application < Rails::Application\n    config\.load_defaults 4\.1\n/, written)
    assert_nil defaults(dir).load_defaults!("4.1.0"), "a second call must not write a second line"

    odd = app(application: "module Storefront\n  class App < Rails::Application\n  end\nend\n")
    assert_nil defaults(odd).load_defaults!("4.1.0"), "an unrecognised class line is not a guess"
    refute_includes File.read(File.join(odd, "config", "application.rb")), "load_defaults"
  end

  def test_dropping_the_file_removes_it
    dir = app
    defaults(dir).drop!

    refute Defaults.file_in(dir)
  end

  # A walk that has crossed several rungs has one file per rung, and the newest is the one this step
  # is about.
  def test_the_newest_file_wins_when_a_walk_has_crossed_several_rungs
    dir = app
    older = File.join(dir, "config", "initializers", "new_framework_defaults_5_0.rb")
    File.write(older, FILE)
    File.utime(Time.now - 3600, Time.now - 3600, older)

    assert_equal "new_framework_defaults_4_1.rb", File.basename(Defaults.file_in(dir))
  end

  # **Two names, because Rails renamed it**: 4.1 wrote `new_framework_defaults.rb` with no version
  # in it, 4.2 and later write `new_framework_defaults_<version>.rb`. A glob with only the second
  # shape finds nothing on the release this walker's first real application stands on.
  def test_the_unsuffixed_name_rails_4_1_wrote_is_found_too
    dir = app(name: "new_framework_defaults.rb")

    assert_equal "new_framework_defaults.rb", File.basename(Defaults.file_in(dir))
    assert_equal 3, defaults(dir).toggles.size
  end

  def test_a_repository_with_no_such_file_has_nothing_to_step
    assert_nil Defaults.file_in(app(file: nil))
  end
end
