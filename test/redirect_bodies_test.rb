# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents_fyi/upgrader"

# **The diaspora 7.1.6 failure, as a fixture.** `expect(response.body).to match("error=invalid_scope")`
# failed with `expected "" to match "error=invalid_scope"` because Rails 7.1 stopped writing a body
# with a redirect. The repair moves the assertion to `response.location`, and the tests below are a
# tree and a failure — no Rails, no suite, no database.
class RedirectBodiesTest < Minitest::Test
  Failure = AgentsFyi::Upgrader::SuiteFailures::Failure

  SPEC = "spec/controllers/api/openid_connect/authorizations_controller_spec.rb"

  def setup
    @root = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  def test_a_redirect_body_assertion_reads_the_location_instead
    spec(
      "        post api_openid_connect_authorizations_new_path, params: {client_id: client.client_id}",
      '        expect(response.body).to match("error=invalid_scope")'
    )

    # The failure names line 2, which is the assertion, not the request above it.
    edit = AgentsFyi::Upgrader::RedirectBodies.for(root: @root, failures: [empty_body]).first

    refute_nil edit
    assert_equal SPEC, edit["path"]
    assert_equal 2, edit["line"]
    assert_equal '        expect(response.body).to match("error=invalid_scope")', edit["text"]
    assert_equal '        expect(response.location).to match("error=invalid_scope")', edit["after"]
    assert_equal "suite-repair", edit["origin"]
    assert_includes edit["note"], "Rails 7.1"
  end

  # **A body that came back wrong is not this family's failure.** The rewrite is only right when the
  # actual was the empty string; content that says something else is a change in the application,
  # and moving the assertion would hide it.
  def test_a_body_assertion_that_failed_on_its_content_is_left_alone
    spec(
      "        get :new",
      '        expect(response.body).to include("Diaspora Test Client")'
    )

    failure = empty_body(message: 'expected "Something Else" to include "Diaspora Test Client"')

    assert_empty AgentsFyi::Upgrader::RedirectBodies.for(root: @root, failures: [failure])
  end

  # The line has to be the assertion. A failure reported against a line that only mentions the body
  # in passing (a request that carried it) has nothing this module may move.
  def test_a_line_that_is_not_an_expectation_on_the_body_is_not_rewritten
    spec(
      "        get :new",
      '        expect(response.status).to eq(302)'
    )

    assert_empty AgentsFyi::Upgrader::RedirectBodies.for(root: @root, failures: [empty_body])
  end

  # A controller is the application, not the suite: an assertion living there is not a test to move.
  def test_a_file_outside_the_suite_is_not_touched
    tree("app/controllers/sessions_controller.rb" => <<~RUBY)
      class SessionsController < ApplicationController
        expect(response.body).to match("error=invalid_scope")
      end
    RUBY

    failure = empty_body(file: "./app/controllers/sessions_controller.rb")

    assert_empty AgentsFyi::Upgrader::RedirectBodies.for(root: @root, failures: [failure])
  end

  # A missing file is a refusal, not a crash: the suite can name a spec the step's tree does not have.
  def test_a_file_the_tree_does_not_have_produces_no_edit
    failure = empty_body(file: "./spec/controllers/gone_spec.rb")

    assert_empty AgentsFyi::Upgrader::RedirectBodies.for(root: @root, failures: [failure])
  end

  private

  def empty_body(name: "AuthorizationsController#new should return an invalid scope error",
                 message: 'expected "" to match "error=invalid_scope"',
                 file: "./#{SPEC}", line: 2)
    Failure.new(name: name, source: 'expect(response.body).to match("error=invalid_scope")',
      error: nil, message: message, caused_by: nil, caused_by_message: nil,
      frames: [[file, line]])
  end

  def spec(*lines)
    tree(SPEC => "#{lines.join("\n")}\n")
  end

  def tree(files)
    files.each do |path, text|
      full = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, text)
    end
  end
end
