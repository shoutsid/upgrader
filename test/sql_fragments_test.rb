# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents/upgrader"

# Rails 6.1's `UnknownAttributeReference`, repaired from the failure's own line.
#
# The two shapes here are the ones volunteer_portal's 6.1 rung produced: an `order` handed a
# variable that holds a SQL fragment, and a `pluck` with a literal SQL expression beside an
# attribute string. The rule wraps the arguments that can be proven to be the fragment and leaves
# symbols, hashes and expressions alone.
class SqlFragmentsTest < Minitest::Test
  SqlFragments = Agents::Upgrader::SqlFragments
  Failure = Struct.new(:messages, :file, :line)

  def setup
    @dirs = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def app(path, text)
    dir = Dir.mktmpdir
    @dirs << dir
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
    [dir, full]
  end

  def failure(line, message, path: "app/graphql/resolvers/user_resolver.rb")
    Failure.new([message], path, line)
  end

  def test_a_variable_handed_to_order_is_wrapped_in_arel_sql
    dir, full = app("app/graphql/resolvers/user_resolver.rb", <<~RUBY)
      class UserResolver
        def scope_with_sort_by(scope, order)
          scope
            .joins(:events)
            .group(:id)
            .order(order)
        end
      end
    RUBY

    edits = SqlFragments.for(root: dir, failures: [
      failure(6, 'Query method called with non-attribute argument(s): "( SUM(COALESCE("individual_events"."duration", 0)) ) DESC"')
    ])

    assert_equal 1, edits.length
    assert_equal ".order(Arel.sql(order))", edits.first["after"].strip
    assert_equal "app/graphql/resolvers/user_resolver.rb", edits.first["path"]
    assert_equal 6, edits.first["line"]
    assert_includes File.read(full), ".order(order)",
      "the rule returns an edit; the applier is what writes it"

    result = Agents::Upgrader::Applier.new(dir).apply(edits)

    assert_empty result.refused, "the applier treated the suite repair as a ladder decision"
    assert_equal 1, result.applied.length
    assert_includes File.read(full), ".order(Arel.sql(order))"
  end

  def test_only_the_string_arguments_of_pluck_are_wrapped
    dir, = app("app/graphql/loaders/event_hours_loader.rb", <<~RUBY)
      class EventHoursLoader
        def query(user_ids)
          scope
            .where(signups: { user_id: user_ids })
            .group('"signups"."user_id"')
            .pluck('"signups"."user_id"', 'SUM((EXTRACT(EPOCH FROM "events"."ends_at") - EXTRACT(EPOCH FROM "events"."starts_at")) / 60)')
        end
      end
    RUBY

    edits = SqlFragments.for(root: dir, failures: [
      failure(6, 'Query method called with non-attribute argument(s): "SUM((EXTRACT(EPOCH FROM \"events\".\"ends_at\") - EXTRACT(EPOCH FROM \"events\".\"starts_at\")) / 60)"',
        path: "app/graphql/loaders/event_hours_loader.rb")
    ])

    assert_equal 1, edits.length
    after = edits.first["after"]
    assert_includes after, %q{.pluck(Arel.sql('"signups"."user_id"'), Arel.sql('SUM(}
    assert_includes after, %q{Arel.sql('SUM((EXTRACT(EPOCH FROM "events"."ends_at")}
    refute_includes after, "Arel.sql(Arel.sql"
  end

  def test_a_symbol_argument_and_an_already_wrapped_fragment_are_left_alone
    dir, = app("app/models/thing.rb", <<~RUBY)
      scope.order(:created_at)
      scope.order(Arel.sql("SUM(duration) DESC"))
    RUBY

    edits = SqlFragments.for(root: dir, failures: [
      failure(1, 'Query method called with non-attribute argument(s): "SUM(duration) DESC"', path: "app/models/thing.rb"),
      failure(2, 'Query method called with non-attribute argument(s): "SUM(duration) DESC"', path: "app/models/thing.rb")
    ])

    assert_empty edits, "an attribute symbol and an Arel.sql call need no second wrapper"
  end

  def test_a_failure_without_the_query_message_is_left_to_another_rule
    dir, = app("app/models/thing.rb", "scope.order(order)\n")

    assert_empty SqlFragments.for(root: dir, failures: [
      failure(1, "some other error", path: "app/models/thing.rb")
    ])
  end
end
