# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents/upgrader"

# **The bundle's groups, read from the application's own Gemfile and `database.yml`.**
#
# The measured failure: `pg` sits in `group :postgresql, optional: true`, `database.yml` names
# PostgreSQL, and `BUNDLE_WITHOUT=development` plus an unset `BUNDLE_WITH` left the bundle with no
# adapter — so the baseline failed on a gem the application had declared all along. The second
# rule is the same question one layer up: a declared formatter whose gem is in the development
# group cannot run there either, and a gate that cannot run leaves every rung unverified.
class BundleGroupsTest < Minitest::Test
  Groups = Agents::Upgrader::BundleGroups
  Rails = Agents::Upgrader::Stacks::Rails

  def setup
    @dirs = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def tree(files)
    dir = Dir.mktmpdir
    @dirs << dir
    files.each do |path, text|
      full = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, text)
    end
    dir
  end

  GEMFILE = <<~GEM
    source "https://rubygems.org"

    gem "rails", "6.1.7.10"

    group :mysql, optional: true do
      gem "mysql2", "0.5.7"
    end

    group :postgresql, optional: true do
      gem "pg", "1.6.3"
    end

    group :development do
      gem "rubocop", "1.86.0", require: false
    end

    group :test do
      gem "rspec", "3.13.0"
    end
  GEM

  DATABASE = <<~YAML
    postgresql: &postgresql
      adapter: postgresql
      host: localhost

    common: &common
      <<: *postgresql

    test:
      <<: *common
      database: app_test
  YAML

  def test_an_optional_group_is_reported_as_optional
    dir = tree("Gemfile" => GEMFILE)

    result = Groups.for(dir).needed(%w[pg])

    assert_equal [:postgresql], result.groups
    assert_equal [:postgresql], result.optional
  end

  def test_a_development_gem_is_reported_as_a_plain_group
    dir = tree("Gemfile" => GEMFILE)

    result = Groups.for(dir).needed(%w[rubocop])

    assert_equal [:development], result.groups
    assert_empty result.optional
  end

  def test_a_gem_declared_in_two_groups_at_once_is_in_both
    dir = tree("Gemfile" => <<~GEM)
      source "https://rubygems.org"
      group :development, :test do
        gem "pry"
      end
    GEM

    result = Groups.for(dir).needed(%w[pry])

    assert_equal %i[development test], result.groups.sort
  end

  def test_an_unknown_gem_contributes_no_group
    dir = tree("Gemfile" => GEMFILE)

    result = Groups.for(dir).needed(%w[not-a-gem])

    assert_empty result.groups
    assert_empty result.optional
  end

  # A Gemfile the walker's interpreter cannot evaluate is not a step-level failure: the install
  # that follows is the authority on whether that Gemfile works, and detection falls back to the
  # environment every walk had before this rule existed.
  def test_a_gemfile_the_dsl_refuses_answers_no_groups_instead_of_raising
    dir = tree("Gemfile" => <<~GEM)
      source "https://rubygems.org"
      raise "this Gemfile cannot be evaluated"
      gem "rails"
    GEM

    result = Groups.for(dir).needed(%w[rails])

    assert_empty result.groups
    assert_empty result.optional
  end

  def test_the_database_adapter_names_the_optional_group_its_gem_is_in
    dir = tree("Gemfile" => GEMFILE, "config/database.yml" => DATABASE)

    result = Rails.bundle_groups(dir)

    assert_equal [:postgresql], result.groups
    assert_equal [:postgresql], result.optional
  end

  # The adapter is the *test* environment's, because that is the database the suite and
  # `db:test:prepare` use. A file that names MySQL first and PostgreSQL in test must not install
  # the MySQL client for a PostgreSQL suite.
  def test_the_test_environments_adapter_wins
    dir = tree("Gemfile" => GEMFILE, "config/database.yml" => <<~YAML)
      development:
        adapter: mysql2
      test:
        adapter: postgresql
    YAML

    result = Rails.bundle_groups(dir)

    assert_equal [:postgresql], result.groups
  end

  # A Rails 7.1 multi-database file nests its connections one level down; the adapter is still
  # the adapter, and the reader that missed it would leave the same suite without its client.
  def test_a_multi_database_test_section_is_read_one_level_down
    dir = tree("Gemfile" => GEMFILE, "config/database.yml" => <<~YAML)
      test:
        primary:
          adapter: postgresql
          database: app_test
    YAML

    result = Rails.bundle_groups(dir)

    assert_equal [:postgresql], result.groups
  end

  def test_a_url_names_the_adapter_without_an_adapter_key
    dir = tree("Gemfile" => GEMFILE, "config/database.yml" => <<~YAML)
      test:
        url: postgres://localhost/app_test
    YAML

    result = Rails.bundle_groups(dir)

    assert_equal [:postgresql], result.groups
  end

  # The declared formatter is why the development group is installed: `bundle exec rubocop -A`
  # names a gem in that group, and a style stage that cannot find its executable leaves the rung
  # unverified rather than measured.
  def test_a_declared_formatter_pulls_its_group_in
    dir = tree("Gemfile" => GEMFILE, "config/database.yml" => DATABASE)

    result = Rails.bundle_groups(dir, commands: ["bundle exec rubocop -A"])

    assert_includes result.groups, :development
    assert_includes result.groups, :postgresql
  end

  # A command that is not `bundle exec <gem>` names a file in the application, not a gem.
  def test_a_command_that_is_not_a_bundle_exec_contributes_nothing
    dir = tree("Gemfile" => GEMFILE)

    result = Rails.bundle_groups(dir, commands: ["bin/rails assets:precompile"])

    assert_empty result.groups
  end

  Machine = Struct.new(:era, :interpreter)

  def step_with(root, project: nil)
    source = Agents::Upgrader::Source.new(root: root, commit: "0" * 40, description: root,
      home: root)
    step = Agents::Upgrader::Step.new(repository: "acme/app", to: "6.1.0", home: root,
      runtime: "native", env: {})
    step.instance_variable_set(:@worktree, source)
    step.instance_variable_set(:@stack, Rails)
    step.instance_variable_set(:@project, project) if project
    step
  end

  def test_the_environment_adds_the_optional_group_and_keeps_development_installed
    dir = tree("Gemfile" => GEMFILE, "config/database.yml" => DATABASE)
    project = Agents::Upgrader::Project.new(
      { "slug" => "app", "repo" => "acme/app", "from" => "6.0.0", "to" => "6.1.0",
        "style" => { "format" => "bundle exec rubocop -A", "check" => "bundle exec rubocop" } }
    )

    env = step_with(dir, project: project).send(:bundle_env, Machine.new("3.2", "ruby 3.2"))

    assert_equal "postgresql", env["BUNDLE_WITH"]
    assert_equal "", env["BUNDLE_WITHOUT"]
  end

  def test_the_environment_keeps_development_excluded_when_nothing_needs_it
    dir = tree("Gemfile" => GEMFILE, "config/database.yml" => "test:\n  adapter: postgresql\n")

    env = step_with(dir).send(:bundle_env, Machine.new("3.2", "ruby 3.2"))

    assert_equal "postgresql", env["BUNDLE_WITH"]
    assert_equal "development", env["BUNDLE_WITHOUT"]
  end
end
