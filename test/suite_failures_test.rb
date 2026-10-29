# frozen_string_literal: true

require "minitest/autorun"
require "agents/upgrader"

# The two suite dialects, as data a repair can read.
class SuiteFailuresTest < Minitest::Test
  SuiteFailures = Agents::Upgrader::SuiteFailures

  # The exact Minitest shape volunteer_portal's 6.1 rung printed. The exception class ends in
  # `Reference`, not `Error`, which is why the parser's class vocabulary had to grow.
  MINITEST_ERROR = <<~OUT
    E

    Error:
    UserResolver::individual_events::when user has both events and individual events#test_0001_does not return the correct order:
    ActiveRecord::UnknownAttributeReference: Query method called with non-attribute argument(s): "( SUM( (EXTRACT(EPOCH FROM \\"events\\".\\"ends_at\\") - EXTRACT(EPOCH FROM \\"events\\".\\"starts_at\\")) / 60 ) + SUM( COALESCE(\\"individual_events\\".\\"duration\\", 0) ) ) DESC"
        app/graphql/resolvers/user_resolver.rb:109:in `scope_with_sort_by'
        app/graphql/resolvers/user_resolver.rb:21:in `all'
        test/graphql/resolvers/user_resolver_test.rb:127:in `block (4 levels) in <top (required)>'

    Finished in 0.888324s, 106.9429 runs/s, 136.2115 assertions/s.
    95 runs, 121 assertions, 0 failures, 8 errors, 0 skips
  OUT

  def test_a_minitest_error_keeps_its_name_class_message_file_and_line
    failure = SuiteFailures.parse(MINITEST_ERROR).first

    refute_nil failure
    assert_includes failure.name, "UserResolver::individual_events"
    assert_equal "ActiveRecord::UnknownAttributeReference", failure.error
    assert_includes failure.messages.first, "Query method called with non-attribute argument(s)"
    assert_equal "app/graphql/resolvers/user_resolver.rb", failure.file
    assert_equal 109, failure.line
  end

  # **The browser process is an exception class too.** 19wu's RSpec baseline printed
  # `Capybara::Poltergeist::DeadClient:` as the only failure; without `Client` in the class
  # vocabulary the block read as an anonymous message, and the step's rerun rule could not see it.
  def test_a_browser_client_death_keeps_its_class
    text = <<~OUT
      Failures:

        1) group collaborators sign in
           Failure/Error: before { sign_in user }
           Capybara::Poltergeist::DeadClient:
             PhantomJS client died while processing
           # ./spec/support/devise.rb:33:in `sign_in'

      Finished in 3 minutes 35.1 seconds
      393 examples, 1 failure, 1 pending
    OUT

    failure = SuiteFailures.parse(text).first

    refute_nil failure
    assert_equal "Capybara::Poltergeist::DeadClient", failure.error
    assert_equal "spec/support/devise.rb", failure.file
    assert_equal 33, failure.line
  end

  def test_a_minitest_assertion_failure_keeps_the_expected_sentence_and_the_test_frame
    text = <<~OUT
      Failure:
      ThingTest#test_the_answer:
      Expected: 42
        Actual: 41
          test/models/thing_test.rb:12:in `test_the_answer'
    OUT

    failure = SuiteFailures.parse(text).first

    refute_nil failure
    assert_equal "ThingTest#test_the_answer", failure.name
    assert_nil failure.error
    assert_equal "Expected: 42", failure.message
    assert_equal "test/models/thing_test.rb", failure.file
    assert_equal 12, failure.line
  end

  # **The suite's colors are not part of its grammar.** The step container's terminal makes
  # Minitest print `\e[31mError:\e[0m`; the record's tail is stripped, so a parser tested against
  # the tail looked correct while the live repair saw nothing.
  def test_ansi_colors_do_not_hide_a_minitest_error
    colored = MINITEST_ERROR.sub("Error:", "\e[31mError:\e[0m")

    failure = SuiteFailures.parse(colored).first

    refute_nil failure
    assert_equal "ActiveRecord::UnknownAttributeReference", failure.error
    assert_equal "app/graphql/resolvers/user_resolver.rb", failure.file
  end

  # **A Minitest suite can print a `Failure/Error:` string without being RSpec.** Volunteer's
  # `rails test` output includes application log lines, and the parser used to choose the RSpec
  # branch on that substring, leaving the real `Error:` blocks unread and the SQL repair with
  # nothing to act on. The two dialects are now both parsed.
  def test_a_minitest_suite_that_mentions_failure_error_still_yields_its_errors
    text = MINITEST_ERROR.sub("E\n\nError:", "E\n\nsome log: Failure/Error: not an RSpec block\n\nError:")

    failures = SuiteFailures.parse(text)

    assert_equal "ActiveRecord::UnknownAttributeReference", failures.first.error
    assert_equal "app/graphql/resolvers/user_resolver.rb", failures.first.file
  end

  def test_rspec_still_reads_its_own_failure_error_dialect
    text = <<~OUT
        1) A thing fails
           Failure/Error: expect(subject).to eq(1)

           NoMethodError:
             undefined method `one' for nil
           # ./app/models/thing.rb:7:in `one'
           # ./spec/models/thing_spec.rb:4:in `block (2 levels)'
    OUT
    # RSpec's numbered line carries two leading spaces; the squiggly heredoc above removes the
    # common indent, so put them back rather than widening the parser to accept an unindented
    # line the real formatter never prints.
    text = text.lines.map { |line| "  #{line}" }.join

    failure = SuiteFailures.parse(text).first

    refute_nil failure
    assert_equal "NoMethodError", failure.error
    assert_equal "app/models/thing.rb", failure.file
    assert_equal 7, failure.line
  end
end
