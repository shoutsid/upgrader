# frozen_string_literal: true

require "minitest/autorun"
require "agents_fyi/upgrader/suite_failures"

# **The suite's text, read as the failure it is.** The fixture is the biddingapp 6.0 rung's real
# output — three of its six blocks, copied whole — because a parser tested on a sentence written for
# it tests the spelling somebody chose rather than the formatter's.
class SuiteFailuresTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/rspec_60_biddingapp.txt", __dir__)

  # **The other dialect: a failed expectation.** Copied whole from diaspora's 7.1.6 rung, where
  # Rails 7.1 stopped writing a redirect's body and three examples read the redirect's target out
  # of it. There is no `SomeError:` line in any of the three, which is the shape the parser had to
  # learn.
  DIASPORA = File.expand_path("fixtures/rspec_71_diaspora.txt", __dir__)

  # Not `failures`: Minitest::Test already owns that name for the assertions that failed.
  def parsed = AgentsFyi::Upgrader::SuiteFailures.parse(File.read(FIXTURE))

  def test_a_failure_names_the_application_file_and_line_it_came_out_of
    first = parsed.first

    assert_equal "BidsController GET #edit responds with HTTP 200 status", first.name
    assert_equal "app/views/bids/edit.html.erb", first.file
    assert_equal 5, first.line
    assert_equal "<%= link_to 'Show', @bid %> |", first.source
    assert_equal "ActionView::Template::Error", first.error
  end

  # RSpec wraps a template's exception, so the class a repair can act on is the cause. A parser
  # that stopped at `ActionView::Template::Error` would know a page failed and not why.
  def test_the_cause_is_read_through_the_template_wrapper
    first = parsed.first

    assert_equal "NoMethodError", first.caused_by
    assert_includes first.caused_by_message, "undefined method `bid_path'"
    assert_includes first.messages.join(" "), "undefined method `bid_path'"
  end

  # The layout's failure is the same shape with the other cause: a URL helper given a nil segment.
  # It is found by the file it names, which is how the repair will reach it too.
  def test_a_url_generation_failure_names_the_missing_key_and_the_layout_line
    nav = parsed.find { |failure| failure.file == "app/views/layouts/_navigation.html.erb" }

    refute_nil nav
    assert_equal 81, nav.line
    assert_equal "ActionController::UrlGenerationError", nav.caused_by
    assert_includes nav.messages.join(" "), "missing required keys: [:category_id]"
    assert_includes nav.source, "new_category_item_path(@category)"
  end

  def test_the_failed_examples_list_is_not_a_failure_block
    assert_equal 3, parsed.size
  end

  # **An expectation failure prints no class line, and its own sentence is the failure.** Before
  # this the file and the line parsed and the sentence was nil, so a repair could see that an
  # expectation at line 113 failed and not what it said — which is the whole of the evidence the
  # redirect-body repair is made from.
  def test_an_expectation_failure_is_read_without_an_exception_class
    first = AgentsFyi::Upgrader::SuiteFailures.parse(File.read(DIASPORA)).first

    assert_equal "spec/controllers/api/openid_connect/authorizations_controller_spec.rb", first.file
    assert_equal 113, first.line
    assert_equal 'expect(response.body).to match("error=invalid_scope")', first.source
    assert_nil first.error
    assert_equal 'expected "" to match "error=invalid_scope"', first.message
  end

  # A raised exception still reads as it did: the class line follows `Failure/Error:` and takes the
  # message branch ahead of the detail this parser now expects there.
  def test_a_class_line_still_names_the_exception
    first = parsed.first

    assert_equal "ActionView::Template::Error", first.error
    assert_equal "undefined method `bid_path' for #<#<Class:0x00005578e9acc7d8>:0x00005578e910c7e8>",
      first.message
  end
end
