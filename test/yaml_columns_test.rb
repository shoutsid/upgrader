# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "agents_fyi/upgrader/suite_failures"
require "agents_fyi/upgrader/yaml_columns"
require "agents_fyi/upgrader/sealed"
require "agents_fyi/upgrader/applier"

# **The repair a serialized column earns after the safe-load change.** The tree is synthetic because
# the rule's subject is the class line and the setting, not the application; the failure itself is
# the shape the 5.2.8.1 rung printed, with both classes a suite could name in one run.
class YamlColumnsTest < Minitest::Test
  APPLICATION = <<~RUBY
    require_relative "boot"
    require "rails/all"

    Bundler.require(*Rails.groups)

    module Consul
      class Application < Rails::Application
        config.load_defaults 5.2
      end
    end
  RUBY

  def setup
    @root = Dir.mktmpdir
    write("config/application.rb", APPLICATION)
  end

  def teardown
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  def failure(classes = "ActiveSupport::HashWithIndifferentAccess")
    AgentsFyi::Upgrader::SuiteFailures::Failure.new(
      name: "Legislation::AnnotationsController POST #create accepts a serialized range",
      source: "@annotation = Legislation::Annotation.new(annotation_params)",
      error: "Psych::DisallowedClass",
      message: "Tried to load unspecified class: #{classes}",
      frames: [["app/controllers/legislation/annotations_controller.rb", 52]]
    )
  end

  def edits(classes = "ActiveSupport::HashWithIndifferentAccess")
    AgentsFyi::Upgrader::YamlColumns.for(root: @root, failures: [failure(classes)])
  end

  def test_the_class_the_failure_names_becomes_the_release_s_permitted_classes_line
    edit = edits.first

    refute_nil edit
    assert_equal "config/application.rb", edit["path"]
    assert_equal 7, edit["line"], "the edit is anchored on the application class line"
    assert_equal "  class Application < Rails::Application", edit["text"]
    assert_equal "  class Application < Rails::Application\n    " \
                 "config.active_record.yaml_column_permitted_classes = " \
                 "[ActiveSupport::HashWithIndifferentAccess]", edit["after"]
    assert edit["automatic"]
  end

  # The applier is the only writer, so the repair is proved by the bytes it leaves: the class line
  # is unchanged above the insertion and the setting is inside the class.
  def test_the_edit_is_written_by_the_applier_and_leaves_the_class_line_in_place
    result = AgentsFyi::Upgrader::Applier.new(@root).apply(edits)

    assert_empty result.refused
    assert_equal 1, result.applied.size
    text = File.read(File.join(@root, "config/application.rb"))
    assert_includes text, "class Application < Rails::Application\n"
    assert_includes text, "config.active_record.yaml_column_permitted_classes = " \
                          "[ActiveSupport::HashWithIndifferentAccess]"
    assert_includes text, "config.load_defaults 5.2"
  end

  # A retry reads the file the first edit wrote; a second line would be a duplicate setting rather
  # than a second repair.
  def test_a_second_run_finds_the_setting_and_writes_nothing
    AgentsFyi::Upgrader::Applier.new(@root).apply(edits)

    assert_empty edits, "the same failure produced a second setting after the first was written"
  end

  def test_two_failures_name_their_classes_once_and_in_a_stable_order
    edit = AgentsFyi::Upgrader::YamlColumns.for(root: @root, failures: [
      failure("Symbol"), failure("ActiveSupport::HashWithIndifferentAccess"), failure("Symbol")
    ]).first

    assert_includes edit["after"], "[ActiveSupport::HashWithIndifferentAccess, Symbol]"
  end

  def test_a_failure_that_is_not_a_disallowed_class_is_not_this_family
    other = failure
    other.error = "NoMethodError"
    other.message = "undefined method `ranges' for nil"

    assert_empty AgentsFyi::Upgrader::YamlColumns.for(root: @root, failures: [other])
  end

  def test_an_application_with_no_application_class_is_left_alone
    write("config/application.rb", "require_relative \"boot\"\n")

    assert_empty edits
  end

  # A setting a person already wrote is theirs. The repair refuses rather than adding a second
  # assignment, which would be a line this rule cannot know the effect of.
  def test_an_existing_permitted_classes_setting_is_not_duplicated
    write("config/application.rb", APPLICATION.sub(
      "class Application < Rails::Application\n",
      "class Application < Rails::Application\n      " \
      "config.active_record.yaml_column_permitted_classes = [Symbol]\n"
    ))

    assert_empty edits
  end

  private

  def write(path, content)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end
end
