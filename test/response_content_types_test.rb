# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents/upgrader"

# **The ohana-api 6.1.7.10 failure, as a fixture.** `expect(response.content_type).to
# eq("application/json")` failed on a correct response because 6.1 returns the header whole —
# `application/json; charset=utf-8` — where the spec was written against the MIME type 6.0
# stripped to. The repair moves the reader to `response.media_type`, and the tests below are a tree
# and a failure: no Rails, no suite, no database.
class ResponseContentTypesTest < Minitest::Test
  Failure = Agents::Upgrader::SuiteFailures::Failure

  SPEC = "spec/api/get_location_spec.rb"

  def setup
    @root = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  def test_a_content_type_equality_reads_the_media_type_instead
    spec(
      "    it 'is json' do",
      "      expect(response.content_type).to eq('application/json')",
      "    end"
    )

    edit = Agents::Upgrader::ResponseContentTypes.for(root: @root, failures: [failure]).first

    refute_nil edit
    assert_equal SPEC, edit["path"]
    assert_equal 2, edit["line"]
    assert_equal "      expect(response.content_type).to eq('application/json')", edit["text"]
    assert_equal "      expect(response.media_type).to eq('application/json')", edit["after"]
    assert_equal "suite-repair", edit["origin"]
    assert_includes edit["note"], "Rails 6.1"
  end

  # Both spellings a suite uses, and the whole line changes only where the reader is.
  def test_a_double_quoted_expectation_and_two_reads_on_one_line_are_both_moved
    spec(
      "    expect([response.content_type, response.content_type]).to eq([\"application/json\"] * 2)"
    )

    edit = Agents::Upgrader::ResponseContentTypes.for(root: @root,
      failures: [failure(line: 1)]).first

    assert_equal "    expect([response.media_type, response.media_type]).to eq([\"application/json\"] * 2)",
      edit["after"]
  end

  # **A raised exception is not this family's failure.** The message is RSpec's class and sentence,
  # not an equality diff, so the content-type reader was not what failed.
  def test_a_failure_that_is_not_an_equality_mismatch_is_left_alone
    spec("      expect(response.content_type).to eq('application/json')")

    raised = failure(message: "undefined method `content_type' for nil", error: "NoMethodError")

    assert_empty Agents::Upgrader::ResponseContentTypes.for(root: @root, failures: [raised])
  end

  # The line has to be the assertion. A failure reported against a line that only mentions the
  # response's type in passing has nothing this module may move.
  def test_a_line_that_is_not_an_expectation_is_not_rewritten
    spec("      response.content_type")

    assert_empty Agents::Upgrader::ResponseContentTypes.for(root: @root, failures: [failure])
  end

  # A controller is the application, not the suite: reading the response's type there is code the
  # move changed, and choosing between the MIME type and the whole header is a person's decision.
  def test_a_file_outside_the_suite_is_not_touched
    tree("app/controllers/api/locations_controller.rb" => <<~RUBY)
      class Api::LocationsController < ApplicationController
        expect(response.content_type).to eq("application/json")
      end
    RUBY

    denied = failure(file: "./app/controllers/api/locations_controller.rb")

    assert_empty Agents::Upgrader::ResponseContentTypes.for(root: @root, failures: [denied])
  end

  # A missing file is a refusal, not a crash: the suite can name a spec the step's tree does not have.
  def test_a_file_the_tree_does_not_have_produces_no_edit
    gone = failure(file: "./spec/api/gone_spec.rb")

    assert_empty Agents::Upgrader::ResponseContentTypes.for(root: @root, failures: [gone])
  end

  private

  def failure(name: "GET /locations/:id with valid id is json",
              message: 'expected: "application/json"',
              error: nil, file: "./#{SPEC}", line: 2)
    Failure.new(name: name, source: 'expect(response.content_type).to eq("application/json")',
      error: error, message: message, caused_by: nil, caused_by_message: nil,
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
