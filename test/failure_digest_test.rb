# frozen_string_literal: true

require "minitest/autorun"
require "agents/upgrader"

# **The failure list a repair is actually briefed with.**
#
# The old brief ended with the last eighty lines of the suite, which is whichever failures
# happened to print last. Measured on brimir's 5.2.8.1 suite, 55 errors and the tail was
# Coveralls output; 46 of the errors were one test calling a controller method that had become
# private. Grouping by exception and the first frame is what turns that into one line.
class FailureDigestTest < Minitest::Test
  Digest = Agents::Upgrader::FailureDigest

  # Two RSpec failures with the same exception and app frame are one group, and the different
  # one is its own; the count is the number of examples, not the number of groups.
  def test_rspec_failures_group_by_exception_and_frame
    digest = Digest.new(<<~LOG)
      Failures:

        1) UsersControllerTest#test_should_get_edit
           Failure/Error: render
           ActionView::Template::Error: wrong number of arguments (1 for 0)
           # ./app/views/users/_form.html.erb:125:in `block'
           # ./app/views/users/edit.html.erb:16:in `show'

        2) RepliesControllerTest#test_reply
           Failure/Error: render
           ActionView::Template::Error: wrong number of arguments (1 for 0)
           # ./app/views/users/_form.html.erb:125:in `block'

        3) TicketsControllerTest#test_should_create
           Failure/Error: current_tenant
           NoMethodError:
             undefined method `current_tenant' for #<TicketsController>
           # ./test/controllers/tickets_controller_test.rb:201:in `block'

      Finished in 4.7 seconds
    LOG

    rendered = digest.render

    assert_includes rendered, "3 failing example(s) in 2 group(s)"
    assert_includes rendered, "2 × ActionView::Template::Error at app/views/users/_form.html.erb:125"
    assert_includes rendered, "1 × NoMethodError at test/controllers/tickets_controller_test.rb:201"
    assert_includes rendered, "undefined method `current_tenant'"
    assert_includes rendered, "The largest group's first failure:"
  end

  # The same shape in Minitest, whose frames are the bare path and line rather than RSpec's
  # leading `#`.
  def test_minitest_errors_group_by_exception_and_frame
    digest = Digest.new(<<~LOG)
      Error:
      ChecksControllerTest#test_should_show_check:
      RangeError: cannot get the first element of beginless range
          app/controllers/checks_controller.rb:30:in `show'
          test/controllers/checks_controller_test.rb:35:in `block'

      Error:
      ChecksControllerTest#test_should_show_index:
      RangeError: cannot get the first element of beginless range
          app/controllers/checks_controller.rb:30:in `show'

      24 runs, 32 assertions, 0 failures, 2 errors, 0 skips
    LOG

    rendered = digest.render

    assert_includes rendered, "2 failing example(s) in 1 group(s)"
    assert_includes rendered, "2 × RangeError at app/controllers/checks_controller.rb:30"
    assert_includes rendered, "cannot get the first element of beginless range"
  end

  # A log the parser cannot read is not a digest that says nothing: the tail is still there,
  # because the model would otherwise be briefed with an empty block.
  def test_an_unparseable_log_falls_back_to_the_tail
    rendered = Digest.new("something went wrong\nno frames here\n").render

    assert_includes rendered, "could not be grouped"
    assert_includes rendered, "something went wrong"
  end

  # Terminal colour is not part of the failure.
  def test_colour_codes_are_stripped
    digest = Digest.new("\e[31mNoMethodError: broken\e[0m\n# ./app/models/user.rb:3:in `x'\n")

    assert_includes digest.render, "NoMethodError: broken"
    refute_includes digest.render, "\e[31m"
  end
end
