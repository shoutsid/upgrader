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
    assert_equal %w[app lib config], project.source_roots
    assert_equal %w[RAILS_SECRET_TOKEN], project.env_names
    assert_equal "auto", project.eras
    assert project.delivery.github?
    assert project.delivery.chain
  end

  # The branch a rung is published on is the declaration's, with the release substituted: one branch
  # per rung is a property of the project rather than a string in the publisher.
  # **The site admin's directory is read first, and the built-in is the fallback.** The site admin writes
  # what the operator edits into a volume this client mounts; an empty volume must still walk the
  # project this image ships, and a written declaration of the same slug must shadow it.
  def test_the_site_admin_directory_is_read_before_the_built_in_declaration
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "site_admin.json"), JSON.generate(
        "slug" => "site_admin", "repo" => "acme/site-admin", "from" => "7.0.0", "to" => "7.1.0",
        "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" }
      ))
      written = PROJECT.find("site_admin", dir: dir)
      assert_equal "acme/site-admin", written.repo
      assert_equal dir, File.dirname(written.path)

      # Nothing written under the built-in slug in this directory: the image's own copy answers.
      assert_equal "shoutsid/biddingapp", PROJECT.find("lighthouse", dir: dir).repo

      # With the same slug written, the site admin's copy is the one used.
      File.write(File.join(dir, "lighthouse.json"), JSON.generate(
        "slug" => "lighthouse", "repo" => "owner/edited", "from" => "7.0.0", "to" => "7.1.0",
        "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" }
      ))
      assert_equal "owner/edited", PROJECT.find("lighthouse", dir: dir).repo
    end
  end

  # **A repository is one identity however it is spelled.** The declaration may say `owner/name`; the
  # queue carries the URL; and the join must not depend on which the caller happened to use.
  def test_a_github_url_gets_one_canonical_clone_spelling
    assert_equal "https://github.com/acme/app.git",
      AgentsFyi::Upgrader::Repository.normalize("https://github.com/acme/app")
    assert_equal "https://github.com/acme/app.git",
      AgentsFyi::Upgrader::Repository.normalize("https://github.com/acme/app/")
    assert_equal "https://github.com/acme/app.git",
      AgentsFyi::Upgrader::Repository.normalize("https://github.com/acme/app.git")
    assert_equal "https://gitlab.com/acme/app",
      AgentsFyi::Upgrader::Repository.normalize("https://gitlab.com/acme/app")
  end

  def test_a_repository_is_one_identity_and_a_declaration_finds_its_row
    project = lighthouse

    assert_equal "https://github.com/shoutsid/biddingapp.git", project.repository
    found = PROJECT.find_by_repository("shoutsid/biddingapp")
    refute_nil found
    assert_equal "lighthouse", found.slug
    assert_nil PROJECT.find_by_repository("https://github.com/example/absent")
  end

  # The site admin's copy of a slug shadows the built-in one, in the repository join too: an operator
  # who edits the declaration means the edited file, not the image's.
  def test_the_site_admin_s_copy_is_the_one_the_repository_join_finds
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "lighthouse.json"), JSON.generate(
        "slug" => "lighthouse", "repo" => "https://github.com/shoutsid/biddingapp",
        "from" => "7.0.0", "to" => "7.1.0",
        "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" }
      ))

      found = PROJECT.find_by_repository("shoutsid/biddingapp", dir: dir)
      assert_equal "7.0.0", found.from, "the site admin's declaration did not shadow the built-in"
    end
  end

  def test_the_delivery_branch_names_the_release
    assert_equal "agents-fyi/upgrade-7.1.0", lighthouse.delivery.branch_for("7.1.0")
  end

  # **An accepted decision is part of the declaration, and its effects are what make it machinery.** The
  # shape is checked here (keys, an id, a list of effects); what an effect *means* is `Effects`'s,
  # because that is where it is applied and where a refusal belongs beside the run.
  def test_a_declaration_carries_the_decisions_the_project_has_made
    project = PROJECT.parse(minimal.merge("decisions" => [decision]).to_json)

    assert_equal 1, project.decisions.length
    assert_equal "d1", project.decisions.first["id"]
    assert_equal "operator:9f2c1ab8", project.decisions.first["accepted_by"]
    assert_equal "patch", project.decisions.first["effects"].first["kind"]
    assert_equal project.to_h, PROJECT.parse(project.to_h.to_json).to_h
    # **The built-in walk no longer carries the 6.0 proof's decisions.** The baseline branch it
    # starts from already contains those view facts, so the effects would be patches looking for
    # lines that are no longer there — and the corpus's decision rows were reset with the upgrade
    # evidence. The capability is what this test drives above, with a declaration written here.
    assert_empty lighthouse.decisions
  end

  # **The application's complete contract is a declaration, not a convention.** The suite, the source
  # roots, the other checks, the toolchain, the formatter and the app:update policy are all facts
  # about *this* application, and each one is checked here rather than discovered by a walk.
  def test_a_declaration_carries_the_checks_source_roots_toolchain_style_and_update_policy
    project = PROJECT.parse(minimal.merge(
      "source_roots" => ["app", "lib", "components"],
      "checks" => [
        { "id" => "lint", "kind" => "lint", "command" => "bundle exec rubocop" },
        { "id" => "packwerk", "kind" => "static",
          "command" => "bundle exec packwerk validate && bundle exec packwerk check" },
        { "id" => "ci", "kind" => "external", "name" => "GitHub Actions: test",
          "reason" => "the application's CI runs it, and this walker does not" }
      ],
      "toolchain" => { "ruby" => "3.3.12", "node" => "20", "postgres" => "pgvector/pgvector:pg16",
                       "extensions" => ["pgvector"], "apt" => ["libvips"] },
      "style" => { "format" => "bundle exec rubocop -A", "check" => "bundle exec rubocop" },
      "app_update" => { "skip" => ["config/storage.yml"],
                        "skip_unused_engines" => false,
                        "framework_defaults" => "step" }
    ).to_json)

    assert_equal %w[app lib components], project.source_roots
    assert_equal %w[lint packwerk ci], project.checks.map(&:id)
    assert project.checks.last.external?
    assert_equal "GitHub Actions: test", project.checks.last.name
    assert_equal "pgvector/pgvector:pg16", project.toolchain.postgres
    assert_equal %w[pgvector], project.toolchain.extensions
    assert_equal "bundle exec rubocop -A", project.style.format
    assert_equal "bundle exec rubocop", project.style.check
    assert project.app_update.skip?("config/storage.yml")
    refute project.app_update.skip?("config/application.rb")
    refute project.app_update.skip_unused_engines
    assert project.app_update.step_defaults?
    assert_equal project.to_h, PROJECT.parse(project.to_h.to_json).to_h
  end

  def test_a_check_with_no_command_is_refused_because_it_could_not_be_run
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("checks" => [{ "id" => "lint", "kind" => "lint" }]).to_json)
    end

    assert_includes error.message, "lint"
    assert_includes error.message, "no `command`"
  end

  # **An external check has to say where it runs.** "Not run here" with no reason is
  # indistinguishable from a check somebody forgot to declare.
  def test_an_external_check_without_a_reason_is_refused
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("checks" => [
        { "id" => "ci", "kind" => "external" }
      ]).to_json)
    end

    assert_includes error.message, "external"
    assert_includes error.message, "`reason`"
  end

  def test_a_check_kind_or_environment_the_engine_does_not_know_is_refused
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("checks" => [
        { "id" => "typo", "kind" => "linter", "command" => "true" }
      ]).to_json)
    end
    assert_includes error.message, "known:"

    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("checks" => [
        { "id" => "lint", "kind" => "lint", "command" => "true", "environment" => "staging" }
      ]).to_json)
    end
    assert_includes error.message, "environment"
  end

  # **A boolean is not a string.** `"required": "false"` used to make a required check optional,
  # because a string is not `true`; a typo must not weaken the gate.
  def test_a_check_boolean_that_is_not_a_boolean_is_refused
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("checks" => [
        { "id" => "lint", "kind" => "lint", "command" => "true", "required" => "false" }
      ]).to_json)
    end

    assert_includes error.message, "required"
    assert_includes error.message, "true or false"
  end

  # A local check cannot be the application's CI job. `environment: "ci"` without `external` used
  # to run the command here and call it CI; it is refused instead.
  def test_a_local_check_cannot_claim_the_ci_environment
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("checks" => [
        { "id" => "ci", "kind" => "lint", "command" => "true", "environment" => "ci" }
      ]).to_json)
    end

    assert_includes error.message, "cannot reproduce"
  end

  def test_a_source_root_that_leaves_the_application_is_refused
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("source_roots" => ["../somewhere"]).to_json)
    end

    assert_includes error.message, "source_roots"
    assert_includes error.message, "leaves it"
  end

  def test_a_style_block_that_asks_for_nothing_is_refused
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("style" => {}).to_json)
    end

    assert_includes error.message, "neither"
  end

  def test_an_app_update_adoption_this_build_does_not_implement_is_refused
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("app_update" => { "adopt" => "all" }).to_json)
    end

    assert_includes error.message, "app_update.adopt"
    assert_includes error.message, "decision"
  end

  def test_an_unknown_field_in_a_decision_is_refused
    broken = decision.merge("asker" => "somebody")
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("decisions" => [broken]).to_json)
    end

    assert_includes error.message, "unknown field(s) in decision 0"
    assert_includes error.message, "asker"
  end

  def test_a_decision_with_no_id_is_refused_because_nothing_could_name_it
    error = assert_raises(PROJECT::Invalid) do
      PROJECT.parse(minimal.merge("decisions" => [decision.merge("id" => "")]).to_json)
    end

    assert_includes error.message, "has no `id`"
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

  # The site admin edits a declaration, so the object has to write one back that a reader would accept.
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

  def decision
    { "id" => "d1", "question" => "Should the row keep a Show link?",
      "answer" => "remove the link", "accepted_by" => "operator:9f2c1ab8",
      "effects" => [{ "kind" => "patch",
                      "payload" => { "path" => "app/views/bids/index.html.erb",
                                     "find" => "show", "replace" => "" },
                      "applies_when" => { "rung_gte" => "6.0.0" } }] }
  end

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
