# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents/upgrader"
require "agents/upgrader/applier"

# The one place in this tool where a line of somebody's source is rewritten, so most
# of what is asserted here is what it declines to write.
class ApplierTest < Minitest::Test
  # A scan entry, shaped like `POST /api/rails/scan`'s `edits`. `after` is null on an edit
  # that needs a decision, and `text` is the line exactly as the service read it.
  def edit(path:, line:, text:, after:, automatic: true, subject: "before_filter")
    {
      "path" => path,
      "line" => line,
      "text" => text,
      "after" => after,
      "subject" => subject,
      "kind" => "renamed",
      "replacement" => "before_action",
      "source" => "5.0",
      "note" => "renamed in Rails 5.0",
      "automatic" => automatic
    }
  end

  def with_tree
    Dir.mktmpdir { |dir| yield dir }
  end

  def write(dir, path, content)
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.binwrite(full, content)
    full
  end

  def read(dir, path)
    File.binread(File.join(dir, path))
  end

  # Bytes, both sides, deliberately: a file read as binary and a UTF-8 literal are not
  # `==` to each other once either of them holds a non-ASCII character.
  def assert_bytes(expected, actual)
    assert_equal expected.b, actual.b
  end

  def test_an_applied_edit_lands_and_the_rest_of_the_file_is_untouched
    with_tree do |dir|
      write(dir, "app/models/user.rb", "class User\n  before_filter :check\nend\n")

      result = Agents::Upgrader::Applier.new(dir).apply(
        [edit(path: "app/models/user.rb", line: 2, text: "  before_filter :check", after: "  before_action :check")]
      )

      assert_equal 1, result.applied.size
      assert_empty result.refused
      assert_equal 1, result.files_written
      assert_bytes "class User\n  before_action :check\nend\n", read(dir, "app/models/user.rb")
      assert_equal "  before_filter :check", result.applied.first.text
      assert_equal "  before_action :check", result.applied.first.after
    end
  end

  # The case the field exists for: the scan read one version of the file and this writes
  # another, because something changed in between. A line number is not an identity.
  def test_a_stale_line_is_refused_rather_than_written
    with_tree do |dir|
      write(dir, "app/models/user.rb", "class User\n  before_action :check # changed since the scan\nend\n")

      result = Agents::Upgrader::Applier.new(dir).apply(
        [edit(path: "app/models/user.rb", line: 2, text: "  before_filter :check", after: "  before_action :check")]
      )

      assert_empty result.applied
      assert_equal 1, result.refused.size
      assert_equal "  before_action :check # changed since the scan", result.refused.first.found
      assert_includes result.refused.first.reason, "is not the line the scan read"
      # The service's own words for the change, copied off the edit rather than invented
      # here: `upgrade_refusals.kind` means "the kind of change, as the ladder names it"
      # and `source` is the guide chapter, so a client filling them with `"applier"`
      # would be answering a different question in the same field.
      assert_equal "renamed", result.refused.first.kind
      assert_equal "before_action", result.refused.first.replacement
      assert_equal "5.0", result.refused.first.source
      assert_equal "renamed in Rails 5.0", result.refused.first.note
      assert_equal 0, result.files_written
      assert_bytes "class User\n  before_action :check # changed since the scan\nend\n",
        read(dir, "app/models/user.rb")
    end
  end

  # `after` is null on an edit that needs a decision, and a whole-word rename is the only
  # edit this tool makes. Refused rather than skipped, so the record says it happened.
  def test_an_edit_that_needs_a_decision_is_refused
    with_tree do |dir|
      write(dir, "app/models/user.rb", "class User\n  before_filter :check\nend\n")

      result = Agents::Upgrader::Applier.new(dir).apply(
        [edit(path: "app/models/user.rb", line: 2, text: "  before_filter :check", after: nil,
          automatic: false, subject: "attr_accessible")]
      )

      assert_empty result.applied
      assert_equal 1, result.refused.size
      assert_includes result.refused.first.reason, "needs a decision"
      assert_equal 0, result.files_written
      assert_bytes "class User\n  before_filter :check\nend\n", read(dir, "app/models/user.rb")
    end
  end

  def test_two_edits_in_one_file_both_land
    with_tree do |dir|
      write(dir, "app/controllers/posts_controller.rb",
        "class PostsController\n  before_filter :a\n  before_filter :b\nend\n")

      result = Agents::Upgrader::Applier.new(dir).apply(
        [
          edit(path: "app/controllers/posts_controller.rb", line: 2, text: "  before_filter :a",
            after: "  before_action :a"),
          edit(path: "app/controllers/posts_controller.rb", line: 3, text: "  before_filter :b",
            after: "  before_action :b")
        ]
      )

      assert_equal 2, result.applied.size
      assert_empty result.refused
      assert_equal 1, result.files_written, "one file with two edits is one write, not two"
      assert_bytes "class PostsController\n  before_action :a\n  before_action :b\nend\n",
        read(dir, "app/controllers/posts_controller.rb")
    end
  end

  def test_one_refusal_does_not_stop_a_sibling_edit
    with_tree do |dir|
      write(dir, "app/models/user.rb", "class User\n  before_filter :check\nend\n")
      write(dir, "app/models/post.rb", "class Post\n  before_filter :publish\nend\n")

      result = Agents::Upgrader::Applier.new(dir).apply(
        [
          edit(path: "app/models/user.rb", line: 2, text: "  before_filter :stale", after: "  before_action :x"),
          edit(path: "app/models/post.rb", line: 2, text: "  before_filter :publish",
            after: "  before_action :publish")
        ]
      )

      assert_equal 1, result.applied.size
      assert_equal 1, result.refused.size
      assert_equal "app/models/post.rb", result.applied.first.path
      assert_equal 1, result.files_written
      assert_bytes "class Post\n  before_action :publish\nend\n", read(dir, "app/models/post.rb")
    end
  end

  def test_an_absolute_path_is_refused
    with_tree do |dir|
      result = Agents::Upgrader::Applier.new(dir).apply(
        [edit(path: "/etc/hosts", line: 1, text: "anything", after: "anything else")]
      )

      assert_equal 1, result.refused.size
      assert_includes result.refused.first.reason, "absolute path"
      assert_equal 0, result.files_written
    end
  end

  def test_a_path_that_escapes_the_working_copy_is_refused
    Dir.mktmpdir do |outer|
      inside = File.join(outer, "copy")
      FileUtils.mkdir_p(inside)

      result = Agents::Upgrader::Applier.new(inside).apply(
        [edit(path: "../escape.txt", line: 1, text: "before", after: "after")]
      )

      assert_equal 1, result.refused.size
      assert_includes result.refused.first.reason, "outside the working copy"
      assert_equal 0, result.files_written
      refute File.exist?(File.join(outer, "escape.txt"))
    end
  end

  # A file that is inside the copy by its spelling and outside it by its bytes. A path
  # check alone cannot see this one, which is why the applier resolves real paths.
  def test_a_symlink_out_of_the_working_copy_is_refused
    Dir.mktmpdir do |outer|
      inside = File.join(outer, "copy")
      elsewhere = File.join(outer, "elsewhere")
      FileUtils.mkdir_p(inside)
      FileUtils.mkdir_p(elsewhere)
      target = File.join(elsewhere, "secrets.yml")
      File.binwrite(target, "token: before\n")
      File.symlink(target, File.join(inside, "config_link.yml"))

      result = Agents::Upgrader::Applier.new(inside).apply(
        [edit(path: "config_link.yml", line: 1, text: "token: before", after: "token: after")]
      )

      assert_equal 1, result.refused.size
      assert_includes result.refused.first.reason, "symlink"
      assert_equal 0, result.files_written
      assert_bytes "token: before\n", File.binread(target)
    end
  end

  # The same escape one level up, and the subtler of the two: the path itself looks
  # like an ordinary file, and the *directory* it is in is the symlink.
  def test_a_symlinked_directory_out_of_the_working_copy_is_refused
    Dir.mktmpdir do |outer|
      inside = File.join(outer, "copy")
      elsewhere = File.join(outer, "elsewhere")
      FileUtils.mkdir_p(inside)
      FileUtils.mkdir_p(elsewhere)
      target = File.join(elsewhere, "gem.rb")
      File.binwrite(target, "before_filter :check\n")
      File.symlink(elsewhere, File.join(inside, "vendor"))

      result = Agents::Upgrader::Applier.new(inside).apply(
        [edit(path: "vendor/gem.rb", line: 1, text: "before_filter :check", after: "before_action :check")]
      )

      assert_equal 1, result.refused.size
      assert_includes result.refused.first.reason, "outside the working copy"
      assert_equal 0, result.files_written
      assert_bytes "before_filter :check\n", File.binread(target)
    end
  end

  # Not "the write was identical" but "there was no write": the file is read-only, so a
  # write would raise rather than pass quietly.
  def test_a_file_with_no_accepted_edit_is_not_rewritten
    with_tree do |dir|
      full = write(dir, "Gemfile", "source \"https://rubygems.org\"\n")
      File.chmod(0o444, full)
      begin
        result = Agents::Upgrader::Applier.new(dir).apply(
          [edit(path: "Gemfile", line: 1, text: "source \"git://else.example\"", after: "source \"never\"")]
        )

        assert_equal 1, result.refused.size
        assert_equal 0, result.files_written
        assert_bytes "source \"https://rubygems.org\"\n", read(dir, "Gemfile")
      ensure
        File.chmod(0o644, full)
      end
    end
  end

  # A CRLF file whose last line has no terminator: both survive an applied edit, because
  # the terminator belongs to the file rather than to the line the service sent.
  def test_crlf_and_a_missing_trailing_newline_survive_an_applied_edit
    with_tree do |dir|
      write(dir, "app/controllers/pages_controller.rb", "class PagesController\r\n  before_filter :show\r\nend")

      result = Agents::Upgrader::Applier.new(dir).apply(
        [edit(path: "app/controllers/pages_controller.rb", line: 2, text: "  before_filter :show",
          after: "  before_action :show")]
      )

      assert_equal 1, result.applied.size
      assert_equal 1, result.files_written
      assert_bytes "class PagesController\r\n  before_action :show\r\nend",
        read(dir, "app/controllers/pages_controller.rb")
    end
  end

  # Byte comparison, not `==`: a line with an accent in it must be editable, and the two
  # strings being compared have different encodings.
  def test_a_line_with_non_ascii_text_is_matched_by_its_bytes
    with_tree do |dir|
      write(dir, "app/models/person.rb", "class Person\n  before_filter :café_check\nend\n")

      result = Agents::Upgrader::Applier.new(dir).apply(
        [edit(path: "app/models/person.rb", line: 2, text: "  before_filter :café_check",
          after: "  before_action :café_check")]
      )

      assert_equal 1, result.applied.size
      assert_empty result.refused
      assert_bytes "class Person\n  before_action :café_check\nend\n", read(dir, "app/models/person.rb")
    end
  end

  # A change whose fix is a file to create arrives as a documented change with
  # `findable: false`, never as an edit, so a path that is not in the working copy is a
  # refusal rather than a file to write — and the directory it would live in exists, so
  # this is the read that fails rather than the path that cannot be resolved.
  def test_a_file_that_is_not_in_the_working_copy_is_refused_rather_than_created
    with_tree do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))

      result = Agents::Upgrader::Applier.new(dir).apply(
        [edit(path: "config/new_file.rb", line: 1, text: "", after: "created")]
      )

      assert_equal 1, result.refused.size
      assert_includes result.refused.first.reason, "could not be read"
      assert_equal 0, result.files_written
      refute File.exist?(File.join(dir, "config/new_file.rb"))
    end
  end
end
