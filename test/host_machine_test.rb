# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents/upgrader"

# The application on the host, through the era's own Ruby.
#
# Nothing here starts a container or an interpreter. What is asserted is what the machine
# composes — the environment a command runs under, where the services script goes — and what it
# refuses by name when the host has not been set up for the era, because "no interpreter could
# install the bundle" is the wrong sentence for a machine that is missing a setup step.
class HostMachineTest < Minitest::Test
  Machine = Agents::Upgrader::Machine
  Interpreters = Agents::Upgrader::Interpreters
  Command = Agents::Upgrader::Record::Command

  class FakeShell
    attr_reader :calls

    def initialize(answers: {})
      @answers = answers
      @calls = []
    end

    def run(argv, stage:, chdir:, env: {}, stdin: nil, timeout: nil, excerpt_bytes: nil)
      line = argv.join(" ")
      @calls << { argv: argv, stage: stage, chdir: chdir, env: env, stdin: stdin }
      exit_code, output = @answers.find { |needle, _| line.include?(needle) }&.last || [0, ""]
      Command.new(stage: stage, command: line, ran: true, exit_code: exit_code,
        seconds: 0.0, output_tail: output.to_s)
    end
  end

  # A services container that is already up, so these tests are about the host machine rather
  # than about `Services` (which has its own file).
  class FakeServices
    attr_reader :ensured

    def initialize(env: { "PGHOST" => "127.0.0.1", "PGPORT" => "5432" }, up: true)
      @env = env
      @up = up
      @ensured = []
    end

    def ensure!(entry, stage:, stages:)
      @ensured << entry.name
      stages << Command.new(stage: stage, command: "docker run services", ran: @up,
        exit_code: @up ? 0 : 1, seconds: 0.0, output_tail: "cid\n")
      @up
    end

    def env = @env
    def command(argv, chdir:) = [["docker", "exec", "cid", *argv], {}]
    def unavailable = "the services container would not start: no such image"
  end

  def setup
    @dirs = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def temp_dir
    dir = Dir.mktmpdir
    @dirs << dir
    dir
  end

  def entry(name: "2.1", ruby: "2.1.10", rvm: "")
    Interpreters::Entry.new(name: name, ruby: ruby, image: "era", base: "base",
      bundler: "1.17.3", rvm: rvm)
  end

  # An rvm root with the era's wrapper, as `rvm install <version>` and a gemset leave it.
  def rvm_root(ruby: "2.1.10", gemset: "agents-upgrader", tools: %w[ruby bundle rake])
    root = temp_dir
    bin = File.join(root, "wrappers", "ruby-#{ruby}@#{gemset}")
    FileUtils.mkdir_p(bin)
    tools.each do |tool|
      File.write(File.join(bin, tool), "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, File.join(bin, tool))
    end
    root
  end

  def machine(entry: entry(), root: nil, runner: nil, services: nil, home: nil,
    services_command: "agents-services")
    Machine::Host.new(entry: entry, home: home || temp_dir, out: nil,
      runner: runner || FakeShell.new, services: services || FakeServices.new,
      rvm_root: root || rvm_root, gemset: "agents-upgrader",
      services_command: services_command)
  end

  # **The era's bin directory goes in front of `PATH`, and that is the whole mechanism.** The
  # application's `bin/rails` is a `#!/usr/bin/env ruby` script, so what makes it the era's Ruby
  # is which `ruby` resolves first — the same thing the container machine gets from its image.
  def test_a_command_runs_with_the_era_s_bin_directory_in_front_of_the_path
    root = rvm_root
    argv, env = machine(root: root).command(%w[bundle install], chdir: temp_dir, env: {})

    assert_equal %w[bundle install], argv
    assert_equal File.join(root, "wrappers", "ruby-2.1.10@agents-upgrader"), env["PATH"].split(":").first
    assert_includes env["PATH"], ENV["PATH"].to_s
  end

  # Where the services answer, and the caller's own environment on top of it: the bundle path
  # and the suite's secrets are the caller's, and `PGPORT` is the machine's.
  def test_the_services_address_travels_and_the_caller_s_environment_wins
    services = FakeServices.new(env: { "PGHOST" => "127.0.0.1", "PGPORT" => "55432" })
    _argv, env = machine(services: services).command(%w[bin/rails runner], chdir: temp_dir,
      env: { "BUNDLE_PATH" => "/tmp/bundle", "RAILS_SECRET_TOKEN" => "s", "PGPORT" => "1" })

    assert_equal "127.0.0.1", env["PGHOST"]
    assert_equal "/tmp/bundle", env["BUNDLE_PATH"]
    assert_equal "s", env["RAILS_SECRET_TOKEN"]
    assert_equal "1", env["PGPORT"], "the caller's own value must win"
  end

  # A command line the application stated runs through a shell, because splitting `bundle exec
  # rspec` here would be guessing at its quoting.
  def test_a_command_line_runs_through_a_shell_on_the_host
    argv, env = machine.script("bundle exec rspec", chdir: temp_dir, env: {})

    assert_equal ["sh", "-lc", "bundle exec rspec"], argv
    refute_empty env["PATH"]
  end

  # **The one command that is not the application's.** The services script starts PostgreSQL and
  # Redis, and on a host-run step they live in the services container — with the application's own
  # directory as the working directory, because that is where it reads the `database.yml` whose
  # roles and databases it creates. *Which* command that is comes from the stack pack through the
  # caller: this machine is told rather than recognising a name, because the name is one
  # application's (see `docs/design-notes.md`).
  def test_the_services_script_runs_in_the_services_container_with_the_application_s_directory
    argv, _env = machine(services_command: "agents-services").command(["agents-services"], chdir: "/tmp/app", env: {})

    assert_equal ["docker", "exec", "cid", "agents-services"], argv
  end

  # And a machine told nothing routes nothing: without the stack's word, a command runs where the
  # application is. That is what keeps the engine from carrying a second copy of the name.
  def test_a_machine_with_no_services_command_routes_nothing
    argv, _env = machine(services_command: "").command(["agents-services"], chdir: "/tmp/app", env: {})

    assert_equal ["agents-services"], argv
  end

  # Starting verifies the interpreter, and both the services container and the version check are
  # in the record — the same two stages the container machine writes.
  def test_starting_verifies_the_era_s_interpreter_and_records_it
    root = rvm_root
    shell = FakeShell.new(answers: { "ruby -v" => [0, "ruby 2.1.10p492 (2016-04-01)\n"] })
    services = FakeServices.new
    stages = []

    assert machine(root: root, runner: shell, services: services).start!(stage: "interpreter", stages: stages)

    assert_equal ["2.1"], services.ensured
    assert_equal 2, stages.length
    assert_equal "docker run services", stages.first.command
    assert_includes stages.last.command, "ruby-2.1.10@agents-upgrader/ruby -v"
  end

  # A host that has not been set up is refused by name, with the command that sets it up: the
  # alternative is a walk that reports "no interpreter could install the bundle" about a machine
  # nobody asked to install anything on.
  def test_an_era_that_is_not_installed_is_refused_by_name_and_names_the_script
    host = machine(root: temp_dir) # an rvm root with no wrapper in it
    stages = []

    refute host.start!(stage: "interpreter", stages: stages)

    assert_includes host.unavailable, "not installed on this host"
    assert_includes host.unavailable, "scripts/upgrader-rubies.sh install 2.1"
    assert_includes host.unavailable, "rvm install 2.1.10"
    assert_empty stages, "nothing should have been recorded for a host that has no interpreter"
  end

  # A wrapper that answers a different version is a host whose rvm and matrix disagree, which is
  # a setup fact rather than a verdict about the move.
  def test_a_wrapper_that_answers_another_version_fails_the_start_and_says_which
    shell = FakeShell.new(answers: { "ruby -v" => [0, "ruby 3.3.12p0 (2025-01-01)\n"] })
    host = machine(runner: shell)

    refute host.start!(stage: "interpreter", stages: [])

    assert_includes host.unavailable, "ruby 3.3.12p0"
    assert_includes host.unavailable, "the matrix calls it ruby 2.1.10"
  end

  # The stamp says what a host interpreter can honestly say: the version, the gemset and the
  # bundler. **It is weaker than a digest and the sentence does not pretend otherwise** — a gem
  # or a system library that changed under the same versions is not noticed, which is the one
  # thing an image's content id would have caught.
  def test_the_stamp_names_the_interpreter_the_gemset_and_the_bundler
    assert_equal "ruby 2.1.10 (rvm ruby-2.1.10@agents-upgrader, bundler 1.17.3)",
      machine.stamp
    assert_equal "rvm ruby-2.1.10@agents-upgrader", machine.image
    assert_equal "2.1", machine.era
    assert_equal "2.1.10", machine.ruby_version
    assert machine.services?
  end

  # A matrix that names the interpreter differently is honoured: a deployment with a patched
  # build says so in the matrix rather than being told its interpreter cannot be found.
  def test_a_matrix_that_names_the_interpreter_differently_is_honoured
    root = rvm_root(ruby: "2.1.10", gemset: "agents-upgrader")
    named = entry(rvm: "ruby-2.1.10")
    host = machine(entry: named, root: root)

    assert_equal "ruby-2.1.10", host.rvm_name
    assert host.installed?
  end
end
