# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents/upgrader"

# **The ohana-api 7.0.10 failure, as a fixture.** `resource.errors.keys` raises on Rails 7.0
# because ActiveModel::Errors no longer delegates `keys`; the reader that answers the same list is
# `attribute_names`. The tests below are a tree and a failure — no Rails, no suite, no database.
class ErrorsKeysTest < Minitest::Test
  Failure = Agents::Upgrader::SuiteFailures::Failure

  CONTROLLER = "app/controllers/concerns/private_registration.rb"

  def setup
    @root = Dir.mktmpdir
    write(CONTROLLER, <<~RUBY)
      module PrivateRegistration
        private

        def only_email_error_is_duplicate?
          resource.errors.keys == [:email] &&
            resource.errors[:email].uniq == ["has already been taken"]
        end
      end
    RUBY
  end

  def teardown
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  def test_the_removed_reader_becomes_attribute_names_and_the_comparison_stays
    edit = Agents::Upgrader::ErrorsKeys.for(root: @root, failures: [removed_reader]).first

    refute_nil edit
    assert_equal CONTROLLER, edit["path"]
    assert_equal 5, edit["line"]
    assert_equal "    resource.errors.keys == [:email] &&", edit["text"]
    assert_equal "    resource.errors.attribute_names == [:email] &&", edit["after"]
    assert_equal "suite-repair", edit["origin"]
    assert_includes edit["note"], "Rails 7.0"
  end

  # A Hash's keys is a different method with the same spelling; the errors class is what makes
  # this family safe.
  def test_a_hash_keys_failure_is_not_this_family
    other = failure(error: "NoMethodError",
      message: "undefined method `keys' for #<Hash:0x00007f9d8c1b2c40>")

    assert_empty Agents::Upgrader::ErrorsKeys.for(root: @root, failures: [other])
  end

  # The failure's line has to carry the call; a comment or a different expression has nothing to
  # rewrite.
  def test_a_line_without_the_call_produces_no_edit
    write(CONTROLLER, "resource.errors[:email]\n")

    assert_empty Agents::Upgrader::ErrorsKeys.for(root: @root, failures: [removed_reader])
  end

  # A file the tree does not have is a refusal, not a crash.
  def test_a_file_the_tree_does_not_have_produces_no_edit
    gone = removed_reader
    gone.frames = [["./app/controllers/concerns/gone.rb", 1]]

    assert_empty Agents::Upgrader::ErrorsKeys.for(root: @root, failures: [gone])
  end

  private

  def removed_reader
    failure
  end

  def failure(name: "Signing up for a new admin account when signing up with existing email",
              error: "NoMethodError",
              message: "undefined method `keys' for #<ActiveModel::Errors:0x00007f9d8c1b2c40>")
    Failure.new(name: name, source: "resource.errors.keys == [:email] &&", error: error,
      message: message, caused_by: nil, caused_by_message: nil,
      frames: [["./#{CONTROLLER}", 5]])
  end

  def write(path, text)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end
end
