# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "agents_fyi/upgrader"

# The project declaration: everything the walk needs to know about *one* application, and nothing
# about how it is walked.
#
# The rules here are all the same rule — a declaration that says something the engine cannot honour
# must fail loudly at the point it is read — and the cases are the ones measured on the first
# complete walk: an unknown key, an environment *value* where a name belongs, a suite with no command,
# and a delivery destination that does not exist.
class ProjectTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PROJECT = AgentsFyi::Upgrader::Project

  # The declaration the deployment walks, read from the file the image copies.
  def lighthouse
    PROJECT.find("lighthouse", dir: File.join(ROOT, "lib", "agents_fyi", "upgrader", "data", "projects"))
  end

  def test_the_lighthouse_is_declared_as_data_and_reads_back_completely
    project = lighthouse

    assert_equal "lighthouse", project.slug
    assert_equal "shoutsid/biddingapp", project.repo
    assert_equal "agents-fyi/baseline", project.base_ref
    assert_equal "4.0.0", project.from
    assert_equal "8.1.0", project.to
    assert_equal "rails", project.stack
    assert_equal "rspec", project.suite.kind
    assert_equal "bundle exec rspec", project.suite_command
    assert_equal %w[postgres redis], project.services
    assert_equal %w[RAILS_SECRET_TOKEN], project.env_names
    assert_equal "auto", project.eras
    assert project.delivery.github?
    assert project.delivery.chain
  end

  # The branch a rung is published on is the declaration's, with the release substituted: one branch
  # per rung is a property of the project rather than a string in the publisher.
  def test_the_delivery_branch_names_the_release
    assert_equal "agents-fyi/upgrade-7.1.0", lighthouse.delivery.branch_for("7.1.0")
  end

  # **A typo is not a comment.** A key the engine does not know is a setting that would silently do
  # nothing, which is the failure mode the class exists to prevent.
  def test_an_unknown_field_is_refused_rather_than_ignored
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("suites" => { "kind" => "rspec" }).to_json)
    end

    assert_includes error.message, "unknown field(s)"
    assert_includes error.message, "suites"
  end

  def test_a_declaration_missing_a_required_field_is_refused
    %w[slug repo from to].each do |field|
      error = assert_raises(PROJECT::Invalid) { PROJECT.parse(minimal.reject { |key, _| key == field }.to_json) }
      assert_includes error.message, field
    end
  end

  # **Names, never values.** A declaration that carried `RAILS_SECRET_TOKEN=abc` would be a secret in
  # the image and in every record that prints the declaration.
  def test_an_environment_value_is_refused_where_a_name_belongs
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("env_names" => ["RAILS_SECRET_TOKEN=abc123"]).to_json)
    end

    assert_includes error.message, "never a value"
    assert_includes error.message, "the value belongs in the deployment"
  end

  def test_a_suite_without_a_command_is_refused_unless_it_says_it_has_none
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("suite" => { "kind" => "rspec" }).to_json)
    end
    assert_includes error.message, "no command is declared"

    no_suite = PROJECT.parse(minimal.merge("suite" => { "kind" => "none" }).to_json)
    assert no_suite.suite.none?
    assert_nil no_suite.suite_command
  end

  def test_a_suite_dialect_the_engine_does_not_know_is_refused
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("suite" => { "kind" => "cucumber", "command" => "cucumber" }).to_json)
    end

    assert_includes error.message, "known: rspec, minitest, none"
  end

  # A unit without a delivery destination is a real declaration — a repository the walk may commit to
  # but has nowhere to open a request for — and it says so rather than defaulting to GitHub.
  def test_a_project_with_no_delivery_says_none_rather_than_defaulting_to_github
    project = PROJECT.parse(minimal.to_json)

    refute project.delivery.github?
    assert_equal "none", project.delivery.provider
  end

  def test_a_field_the_declaration_does_not_carry_reads_as_absent
    project = PROJECT.parse(minimal.to_json)

    assert_nil project.base_ref
    assert_equal "the repository's default branch", project.starting_point
    assert_equal "rails", project.stack
    assert_equal "auto", project.eras
  end

  # The console edits a declaration, so the object has to write one back that a reader would accept.
  def test_the_declaration_round_trips_through_its_own_hash
    project = lighthouse
    again = PROJECT.parse(project.to_h.to_json)

    assert_equal project.to_h, again.to_h
    assert_equal project.suite_command, again.suite_command
  end

  def test_a_declaration_that_is_not_json_says_so_rather_than_raising_a_parser_error
    error = assert_raises(PROJECT::Invalid) { PROJECT.parse("{") }
    assert_includes error.message, "not JSON"
  end

  def test_a_slug_with_no_declaration_says_which_directory_it_looked_in
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.find("nothing-here", dir: Dir.mktmpdir)
    end

    assert_includes error.message, "nothing-here"
    assert_includes error.message, "no project"
  end

  private

  # The smallest declaration that is complete: every other rule is about what may be added to it.
  def minimal
    {
      "slug" => "storefront",
      "repo" => "acme/storefront",
      "from" => "5.2.0",
      "to" => "6.0.0",
      "suite" => { "kind" => "minitest", "command" => "bin/rails test" }
    }
  end
end
