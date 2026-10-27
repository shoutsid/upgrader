# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents/upgrader"

# **The ohana-api 7.1.6 failure, as a fixture.** The rung made every `I18n.t` raise on a key the
# application never defines, and this spec identified a link by one: the navigation renders
# `admin.buttons.locations`, and `admin.navigation.locations` has never existed. Before 7.1 the
# call returned a `translation missing:` string and the assertion passed for a reason it did not
# mean. The tests below are a tree and a failure — no Rails, no suite, no database.
class MissingTranslationsTest < Minitest::Test
  Failure = Agents::Upgrader::SuiteFailures::Failure
  SPEC = "spec/features/admin/dashboard_spec.rb"

  def setup
    @root = Dir.mktmpdir
    write(SPEC, <<~RUBY)
      describe 'Admin Home page' do
        it 'does not include a link to Your locations in the navigation' do
          within '.navbar' do
            expect(page).
              not_to have_link I18n.t('admin.navigation.locations'), href: admin_locations_path
          end
        end
      end
    RUBY
  end

  def teardown
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  # The measured line, repaired to the half that identifies the link. The href is the fact the spec
  # already carries; the label is the half the application cannot supply.
  def test_the_missing_key_is_dropped_and_the_href_kept
    edit = Agents::Upgrader::MissingTranslations.for(root: @root,
      failures: [missing_translation(line: 5)]).first

    refute_nil edit
    assert_equal SPEC, edit["path"]
    assert_equal 5, edit["line"]
    assert_equal "        not_to have_link href: admin_locations_path", edit["after"]
    assert_equal true, edit["automatic"]
    assert_equal "suite-repair", edit["origin"]
    assert_includes edit["note"], "admin.navigation.locations"
    assert_includes edit["note"], "href"
  end

  # A parenthesised matcher stays parenthesised; the comma that separated the argument goes with it.
  def test_a_parenthesised_matcher_keeps_its_parenthesis
    write(SPEC, "expect(page).not_to have_link(I18n.t(\"admin.navigation.locations\"), " \
                "href: admin_locations_path)\n")

    edit = Agents::Upgrader::MissingTranslations.for(root: @root,
      failures: [missing_translation(line: 1)]).first

    assert_equal "expect(page).not_to have_link(href: admin_locations_path)", edit["after"]
  end

  # **A missing key in the application is not this family's failure.** In a view the string is what
  # the page says, and dropping it would change the page rather than the assertion.
  def test_a_missing_key_the_application_raises_is_left_alone
    write("app/views/layouts/_navigation.html.erb",
      "<%= link_to t('admin.navigation.locations'), admin_locations_path %>\n")

    failures = [missing_translation(file: "app/views/layouts/_navigation.html.erb", line: 1)]
    assert_empty Agents::Upgrader::MissingTranslations.for(root: @root, failures: failures)
  end

  # With no href the matcher has nothing left to identify a link with, and `have_link` with no
  # arguments would assert only that some link exists.
  def test_a_matcher_with_no_destination_is_refused
    write(SPEC, "expect(page).not_to have_link I18n.t('admin.navigation.locations')\n")

    assert_empty Agents::Upgrader::MissingTranslations.for(root: @root,
      failures: [missing_translation(line: 1)])
  end

  # Another red suite must not have its specs rewritten, even when the same line is in the tree.
  def test_a_failure_that_is_not_a_missing_translation_is_left_alone
    other = missing_translation(line: 5, error: "NoMethodError",
      message: "undefined method `have_link' for nil")

    assert_empty Agents::Upgrader::MissingTranslations.for(root: @root, failures: [other])
  end

  # A retry after the first repair finds a line with no call left to remove, so the repair is not
  # repeated into a second edit.
  def test_a_repaired_line_produces_no_edit
    write(SPEC, "expect(page).not_to have_link href: admin_locations_path\n")

    assert_empty Agents::Upgrader::MissingTranslations.for(root: @root,
      failures: [missing_translation(line: 1)])
  end

  # A computed key is not a fact this repair can read, and guessing it is the thing a digest entry
  # has to be measured to be allowed to do.
  def test_a_computed_key_is_refused
    write(SPEC, "expect(page).not_to have_link I18n.t(link_key), href: admin_locations_path\n")

    assert_empty Agents::Upgrader::MissingTranslations.for(root: @root,
      failures: [missing_translation(line: 1)])
  end

  private

  def missing_translation(line:, file: SPEC, error: "I18n::MissingTranslationData",
                          message: "translation missing: en.admin.navigation.locations")
    # The parser keeps only the application's own frames, printed with a leading `./`.
    Failure.new(name: "Admin Home page does not include a link to Your locations",
      source: "expect(page).", error: error, message: message, caused_by: nil,
      caused_by_message: nil, frames: [["./#{file}", line]])
  end

  def write(path, text)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end
end
