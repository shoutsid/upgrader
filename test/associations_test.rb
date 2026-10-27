# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents/upgrader"

# **The rung that made diaspora's suite red, as a fixture.** `StatusMessage < Post` declares
# `has_one :poll`; Rails 7.0 derives the key from `Post`, so the query asks `polls.post_id` and the
# table has `status_message_id`. The repair is answered from the failure and the schema, so these
# tests are a tree, a dump and one failure — no database, no Rails.
class AssociationsTest < Minitest::Test
  Failure = Agents::Upgrader::SuiteFailures::Failure

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def test_an_association_whose_key_the_table_lacks_is_given_the_one_it_has
    tree(
      "db/schema.rb" => <<~RUBY,
        ActiveRecord::Schema.define(version: 2020_01_01_000000) do
          create_table "polls", force: :cascade do |t|
            t.string "question"
            t.integer "status_message_id"
          end
        end
      RUBY
      "app/models/post.rb" => "class Post < ApplicationRecord\nend\n",
      "app/models/status_message.rb" => <<~RUBY
        class StatusMessage < Post
          has_one :poll, autosave: true, dependent: :destroy
        end
      RUBY
    )

    edits = Agents::Upgrader::Associations.for(root: @dir, failures: [missing_poll_key])

    assert_equal 1, edits.length
    edit = edits.first
    assert_equal "app/models/status_message.rb", edit["path"]
    assert_equal 2, edit["line"]
    assert_equal "  has_one :poll, autosave: true, dependent: :destroy, foreign_key: :status_message_id",
      edit["after"]
    assert_includes edit["note"], "post_id"
    assert_includes edit["note"], "status_message_id"
  end

  # **The inverse is written with the key, and only when the child declares it.** With the key
  # named and no `inverse_of`, `build_poll` leaves `poll.status_message` nil and the child's
  # `belongs_to` validation fails on nine examples that passed on 6.1.
  def test_the_repair_names_the_inverse_when_the_child_declares_it
    tree(
      "db/schema.rb" => <<~RUBY,
        ActiveRecord::Schema.define(version: 2020_01_01_000000) do
          create_table "polls", force: :cascade do |t|
            t.integer "status_message_id"
          end
        end
      RUBY
      "app/models/post.rb" => "class Post < ApplicationRecord\nend\n",
      "app/models/poll.rb" => "class Poll < ApplicationRecord\n  belongs_to :status_message\nend\n",
      "app/models/status_message.rb" => "class StatusMessage < Post\n  has_one :poll\nend\n"
    )

    edit = Agents::Upgrader::Associations.for(root: @dir, failures: [missing_poll_key]).first

    assert_equal "  has_one :poll, foreign_key: :status_message_id, inverse_of: :status_message",
      edit["after"]
    assert_includes edit["note"], "inverse_of"
  end

  # The key the schema does not have is the *base* class's; a table that has neither is an
  # application whose association was always wrong, and this module has no fact to repair it with.
  def test_a_table_with_neither_key_is_left_alone
    tree(
      "db/schema.rb" => <<~RUBY,
        ActiveRecord::Schema.define(version: 2020_01_01_000000) do
          create_table "polls", force: :cascade do |t|
            t.string "question"
          end
        end
      RUBY
      "app/models/post.rb" => "class Post < ApplicationRecord\nend\n",
      "app/models/status_message.rb" => "class StatusMessage < Post\n  has_one :poll\nend\n"
    )

    assert_empty Agents::Upgrader::Associations.for(root: @dir, failures: [missing_poll_key])
  end

  # A declaration that already names its key is not the repair's subject, and neither is a form
  # whose key is not the owner's (`through`, `as`, `class_name`).
  def test_an_association_that_names_its_own_key_or_its_route_is_not_touched
    tree(
      "db/schema.rb" => <<~RUBY,
        ActiveRecord::Schema.define(version: 2020_01_01_000000) do
          create_table "polls", force: :cascade do |t|
            t.integer "status_message_id"
          end
        end
      RUBY
      "app/models/post.rb" => "class Post < ApplicationRecord\nend\n",
      "app/models/status_message.rb" => <<~RUBY
        class StatusMessage < Post
          has_one :poll, foreign_key: :status_message_id
          has_many :polls, through: :something
        end
      RUBY
    )

    assert_empty Agents::Upgrader::Associations.for(root: @dir, failures: [missing_poll_key])
  end

  # A failure that is not a missing column is not this family's business: a template error and a
  # validation error both reach the loop, and neither may produce an association edit.
  def test_a_failure_about_something_else_produces_no_edit
    tree(
      "db/schema.rb" => "ActiveRecord::Schema.define do\nend\n",
      "app/models/post.rb" => "class Post < ApplicationRecord\nend\n"
    )

    other = Failure.new(name: "a page", error: "ActionView::Template::Error",
      message: "undefined method 'bids_path'", caused_by: nil, caused_by_message: nil, frames: [])

    assert_empty Agents::Upgrader::Associations.for(root: @dir, failures: [other])
  end

  # The other spelling of the schema, because a tree that keeps `db/structure.sql` is the same
  # application and the repair must not depend on which dump it kept.
  def test_a_structure_sql_dump_is_read_the_same_way
    tree(
      "db/structure.sql" => <<~SQL,
        CREATE TABLE public.polls (
            id bigint NOT NULL,
            question character varying,
            status_message_id bigint
        );
      SQL
      "app/models/post.rb" => "class Post < ApplicationRecord\nend\n",
      "app/models/status_message.rb" => "class StatusMessage < Post\n  has_one :poll\nend\n"
    )

    edits = Agents::Upgrader::Associations.for(root: @dir, failures: [missing_poll_key])

    assert_equal 1, edits.length
    assert_equal "  has_one :poll, foreign_key: :status_message_id", edits.first["after"]
  end

  private

  def missing_poll_key
    Failure.new(name: "PollParticipationService voting on poll succeeds",
      error: "ActiveRecord::StatementInvalid",
      message: "PG::UndefinedColumn: ERROR:  column polls.post_id does not exist",
      caused_by: nil, caused_by_message: nil, frames: [])
  end

  def tree(files)
    files.each do |path, text|
      full = File.join(@dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, text)
    end
  end
end
