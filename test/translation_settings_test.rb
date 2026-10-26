# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents_fyi/upgrader"

# **The ohana-api 7.0.10 failure, as a fixture.** Every example that rendered a template died with
# `NoMethodError: undefined method 'raise_on_missing_translations=' for ActionView::Base:Class`; the
# application's environment files still carried the 5.x spelling. The repair moves the setting to
# its 7.0 home, and the tests below are a tree and a failure — no Rails, no suite, no database.
class TranslationSettingsTest < Minitest::Test
  Failure = AgentsFyi::Upgrader::SuiteFailures::Failure

  def setup
    @root = Dir.mktmpdir
    write("config/environments/test.rb", <<~RUBY)
      Rails.application.configure do
        config.action_view.raise_on_missing_translations = true
      end
    RUBY
    write("config/environments/development.rb", <<~RUBY)
      Rails.application.configure do
        config.action_view.raise_on_missing_translations = false
      end
    RUBY
  end

  def teardown
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  def test_every_environment_file_moves_to_the_i18n_namespace_and_keeps_its_value
    edits = AgentsFyi::Upgrader::TranslationSettings.for(root: @root, failures: [removed_setter])

    assert_equal %w[config/environments/development.rb config/environments/test.rb],
      edits.map { |edit| edit["path"] }.sort
    assert_equal "  config.i18n.raise_on_missing_translations = true",
      edits.find { |edit| edit["path"] == "config/environments/test.rb" }["after"]
    assert_equal "  config.i18n.raise_on_missing_translations = false",
      edits.find { |edit| edit["path"] == "config/environments/development.rb" }["after"]
    assert(edits.all? { |edit| edit["automatic"] })
    assert(edits.all? { |edit| edit["origin"] == "suite-repair" })
    assert_includes edits.first["note"], "Rails 7.0"
  end

  # The value is the application's; only the namespace is the release's.
  def test_the_line_number_and_text_are_the_line_the_application_wrote
    edit = AgentsFyi::Upgrader::TranslationSettings.for(root: @root, failures: [removed_setter]).first

    assert_equal 2, edit["line"]
    assert_equal "  config.action_view.raise_on_missing_translations = false", edit["text"]
  end

  # A suite that failed for another reason must not have its configuration rewritten, even when the
  # line is present in the tree.
  def test_a_failure_that_does_not_name_the_removed_setter_is_left_alone
    other = failure(error: "NoMethodError", message: "undefined method `foo' for nil")

    assert_empty AgentsFyi::Upgrader::TranslationSettings.for(root: @root, failures: [other])
  end

  # A setter of the same name on another class is not this removal.
  def test_the_same_name_on_another_class_is_not_this_family
    other = failure(error: "NoMethodError",
      message: "undefined method `raise_on_missing_translations=' for Something::Else:Class")

    assert_empty AgentsFyi::Upgrader::TranslationSettings.for(root: @root, failures: [other])
  end

  # A tree whose environment file already uses the new spelling is written nothing, so a retry
  # after the first repair is not a second edit.
  def test_a_tree_already_using_the_i18n_namespace_produces_no_edit
    write("config/environments/test.rb", <<~RUBY)
      Rails.application.configure do
        config.i18n.raise_on_missing_translations = true
      end
    RUBY
    write("config/environments/development.rb", "Rails.application.configure do\nend\n")

    assert_empty AgentsFyi::Upgrader::TranslationSettings.for(root: @root, failures: [removed_setter])
  end

  private

  def removed_setter
    failure(error: "NoMethodError",
      message: "undefined method `raise_on_missing_translations=' for ActionView::Base:Class")
  end

  def failure(name: "GET /api/locations renders", error: "NoMethodError",
              message: "undefined method `raise_on_missing_translations=' for ActionView::Base:Class")
    Failure.new(name: name, source: "render", error: error, message: message,
      caused_by: nil, caused_by_message: nil, frames: [])
  end

  def write(path, text)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end
end
