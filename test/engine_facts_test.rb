# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents_fyi/upgrader"

# **The engine names no project, and no stack spelling outside the pack.**
#
# The design notes call this the engine's first seam, and it is a source test because the failure it
# prevents is invisible at runtime: a second project walked by an engine that still carries
# `bin/rails` and `RAILS_SECRET_TOKEN` does not crash, it quietly measures the second project with
# the first one's knowledge. Measured on the first complete walk, those spellings were spread across
# `step.rb`, `tests.rb` and `machine.rb`; the table below is that measurement, and the two sources
# that remain are the ones allowed to hold them:
#
# * `data/projects/<slug>.json` — the project's declaration (the `Project` value object reads it).
# * `stacks.rb` — the Rails pack, where a command spelling is the framework's knowledge rather than
#   one application's.
#
# Comments are stripped before the scan: the *reasons* a spelling is what it is belong in the engine
# (`app:update` arrived after `bin/rails`, and that sentence explains a decision), while the spelling
# itself belongs to the pack.
class EngineFactsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  LIB = File.join(ROOT, "lib", "agents_fyi", "upgrader")
  PACK = "stacks.rb"

  # Facts about *one* application: its repository, the ref its walk starts from, the secret its suite
  # reads, and the images built for it. A second project has none of these.
  PROJECT_FACTS = [
    "biddingapp",
    "shoutsid",
    "agents-fyi/baseline",
    "RAILS_SECRET_TOKEN",
    "agentsfyi-upgrader"
  ].freeze

  # Spellings that are the *framework's*: the suites, the runner, the services script, the
  # environment a suite runs under, and the command that prepares a test database. The pack may name
  # them; the engine may only ask the pack.
  STACK_SPELLINGS = [
    "bin/rails",
    "bundle exec rspec",
    "bundle exec rake",
    "agents-fyi-services",
    "RAILS_ENV",
    "RACK_ENV",
    "db:test:prepare"
  ].freeze

  def engine_files = Dir[File.join(LIB, "*.rb")].sort

  # The code of a file, without its comments: what the engine *does*, rather than what it explains.
  def code_lines(path)
    File.readlines(path, encoding: "utf-8").reject { |line| line.strip.start_with?("#") }
  end

  def offenders(files, facts)
    files.flat_map do |path|
      code_lines(path).filter_map do |line|
        fact = facts.find { |candidate| line.include?(candidate) }
        "#{File.basename(path)}: #{fact}" if fact
      end
    end
  end

  def test_the_engine_names_no_fact_about_one_application
    found = offenders(engine_files, PROJECT_FACTS)

    assert_empty found, "the walk engine names an application's own facts: #{found.uniq.join(", ")} — " \
      "they belong in data/projects/<slug>.json, so a second project is a declaration rather than a fork"
  end

  def test_only_the_stack_pack_names_a_rails_command_spelling
    found = offenders(engine_files.reject { |path| File.basename(path) == PACK }, STACK_SPELLINGS)

    assert_empty found, "the engine spells a framework command outside the pack: #{found.uniq.join(", ")} — " \
      "the pack (Stacks::Rails) is where a spelling is knowledge about the framework"
  end

  # The other direction: the pack really holds what the engine stopped naming, so the test above
  # cannot pass by the engine having simply dropped a capability.
  def test_the_pack_holds_the_spellings_the_engine_asks_for
    pack = AgentsFyi::Upgrader::Stacks::Rails

    assert_equal ["agents-fyi-services"], pack.services_command
    assert_equal %w[RAILS_ENV RACK_ENV], pack.test_env.keys
    assert_equal %i[rspec rails rake], pack.suite_candidates.map { |candidate| candidate[:kind] }
    assert_equal "bin/rails app:update", pack.update_command(five_or_newer: true)
    assert_equal "bundle exec rake rails:update", pack.update_command(five_or_newer: false)
    assert_equal "no bin/rails and no Rakefile: nothing to run", pack.no_update_reason
    assert_equal "bin/rails active_storage:install", pack.install_command("active_storage")
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "bin"))
      File.write(File.join(root, "bin", "rails"), "")
      File.chmod(0o755, File.join(root, "bin", "rails"))
      assert_equal ["bin/rails", "runner", "puts 1"], pack.routes_runner(root, script: "puts 1")
    end
    assert_nil pack.routes_runner("/nonexistent", script: "puts 1"),
      "no binstub is no route table, not a command that fails for another reason"
    assert pack.five_or_newer?(Struct.new(:rails).new(Struct.new(:version).new("8.1.0")))
    refute pack.five_or_newer?(Struct.new(:rails).new(Struct.new(:version).new("4.0.0.rc1")))
  end

  # **A binstub is looked for, not its mode bit.** `rails_modular_monolith` commits its whole `bin/`
  # directory at 0644, and a volume mounted without file modes drops the bit from files git records
  # at 100755 — both leave an application whose `bin/rails` exists and cannot be exec'd directly. The
  # step runs such a script through its shebang's interpreter (`Step#runnable`), so the gates here
  # must not read the bit: measured on that application, `app:update` was skipped for the whole walk
  # as "no bin/rails", and `db:test:prepare`/`assets:precompile` answered exit 126.
  def test_a_binstub_that_is_not_executable_is_still_a_binstub
    pack = AgentsFyi::Upgrader::Stacks::Rails
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "bin"))
      File.write(File.join(root, "bin", "rails"), "#!/usr/bin/env ruby\n")
      File.chmod(0o644, File.join(root, "bin", "rails"))

      assert_equal [["bin/rails"], "app:update"], pack.app_update(root, five_or_newer: true)
      assert_equal ["bin/rails", "runner", "puts 1"], pack.routes_runner(root, script: "puts 1")
      assert_equal ["bin/rails", "runner", "puts Rails.version"], pack.boot(root)
    end
  end

  def test_a_stack_is_chosen_by_the_name_a_project_declares
    assert_same AgentsFyi::Upgrader::Stacks::Rails, AgentsFyi::Upgrader::Stacks.for("rails")
    assert_same AgentsFyi::Upgrader::Stacks::Rails, AgentsFyi::Upgrader::Stacks.for(" Rails ")

    error = assert_raises(AgentsFyi::Upgrader::Project::Invalid) do
      AgentsFyi::Upgrader::Stacks.for("node")
    end

    assert_includes error.message, "no stack pack named"
    assert_includes error.message, "known: rails"
  end

  # A walk starts from its declaration: the fact that used to be a CLI flag (`--to`) and a branch
  # name in the publisher now arrives in one object, and the pack is chosen from it.
  def test_the_lighthouse_declaration_carries_everything_the_lighthouse_walk_needs
    project = AgentsFyi::Upgrader::Project.find("lighthouse", dir: File.join(LIB, "data", "projects"))

    refute_empty project.repo
    refute_empty project.base_ref
    assert_equal "4.0.0", project.from
    assert_equal "8.1.0", project.to
    assert_equal "rails", project.stack
    assert_equal %w[postgres redis], project.services
    assert_equal %w[RAILS_SECRET_TOKEN], project.env_names
    assert project.delivery.github?
    assert_empty offenders([File.join(LIB, "project.rb")], PROJECT_FACTS),
      "the Project value object is the engine's reader of a declaration, so it must not name one either"
  end
end
