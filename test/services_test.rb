# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "socket"
require "tmpdir"
require "agents_fyi/upgrader"

# The services a host-run application talks to, in one container for the whole walk.
#
# The container machine starts PostgreSQL and Redis inside the step's own container because a
# 2013 `database.yml` says `host: localhost` and a service on a Docker network is not localhost.
# With the application on the host, a *published port* is localhost — so the services can be a
# sibling that outlives the step, which is the whole reason this class exists: a container per
# step, and per interpreter candidate, was the slowest thing a walk did.
class ServicesTest < Minitest::Test
  Machine = AgentsFyi::Upgrader::Machine
  Interpreters = AgentsFyi::Upgrader::Interpreters
  Command = AgentsFyi::Upgrader::Record::Command

  class FakeShell
    attr_reader :calls

    def initialize(exit_code: 0, output: "c0ffee\n")
      @exit_code = exit_code
      @output = output
      @calls = []
    end

    def run(argv, stage:, chdir:, env: {}, stdin: nil, timeout: nil)
      line = argv.join(" ")
      @calls << { argv: argv, stage: stage, chdir: chdir, env: env }
      Command.new(stage: stage, command: line, ran: true, exit_code: @exit_code,
        seconds: 0.0, output_tail: @output)
    end
  end

  class FakeInspector
    attr_reader :calls

    def initialize
      @calls = []
    end

    def capture3(*argv)
      @calls << argv.join(" ")
      ["", "", nil]
    end

    def capture2e(*argv)
      @calls << argv.join(" ")
      ["", nil]
    end
  end

  def setup
    @dirs = []
    @home = temp_dir
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def temp_dir
    dir = Dir.mktmpdir
    @dirs << dir
    dir
  end

  def entry(name: "2.1", ruby: "2.1.10", image: "agentsfyi-upgrader-ruby-2.1:dev")
    Interpreters::Entry.new(name: name, ruby: ruby, image: image, base: "base",
      bundler: "1.17.3", rvm: "")
  end

  def services(runner: nil, inspector: nil, **kwargs)
    Machine::Services.new(home: @home, runner: runner || FakeShell.new,
      inspector: inspector || FakeInspector.new, volume: "", name: "agentsfyi-services-test",
      **kwargs)
  end

  # The application's own ports, because that is the point: `database.yml` says `localhost`, and
  # libpq's default is 5432. Nothing in the application is edited for the machine's benefit.
  def test_the_application_s_own_ports_are_used_when_they_are_free
    started = services
    return skip("this machine already has PostgreSQL on 5432") unless
      started.pg_port == Machine::PG_PORT

    assert_equal Machine::PG_PORT, started.pg_port
    assert_equal Machine::REDIS_PORT, started.redis_port
  end

  # A developer who is already running PostgreSQL is not a developer who cannot walk: a free
  # port is chosen and `PGHOST`/`PGPORT` carry it, which libpq honours when the `database.yml`
  # names no host or port.
  def test_a_taken_port_falls_back_to_a_free_one_that_the_environment_carries
    occupied = TCPServer.new("127.0.0.1", 0)
    port = occupied.addr[1]
    begin
      chosen = services.send(:free_port, port)

      refute_equal port, chosen
      assert_operator chosen, :>, 0
    ensure
      occupied.close
    end
  end

  # What the container is: the era's image, both ports published on the loopback, the walker's
  # home mounted (the script reads the application's `database.yml` from it), and the labels
  # that make a killed walker's container reapable.
  def test_the_container_is_the_era_s_image_with_both_ports_published_and_labelled
    shell = FakeShell.new
    stages = []
    started = services(runner: shell, pg_port: 55432, redis_port: 56379)

    assert started.ensure!(entry, stage: "interpreter", stages: stages)

    argv = shell.calls.first[:argv].join(" ")
    assert_includes argv, "agentsfyi-upgrader-ruby-2.1:dev"
    assert_includes argv, "-p 127.0.0.1:55432:5432"
    assert_includes argv, "-p 127.0.0.1:56379:6379"
    assert_includes argv, "source=#{@home},target=/agents-fyi"
    assert_includes argv, "--label org.agentsfyi.upgrader.pid=#{Process.pid}"
    assert_includes argv, "agents-fyi-start sleep infinity"
    assert_equal "c0ffee", started.container_id
    assert_equal 1, stages.length
    assert stages.first.ok?
  end

  # One container at a time, and a step on another era replaces it: the application's
  # `localhost:5432` can only be one thing, and an old suite needs its own era's PostgreSQL.
  def test_a_step_on_another_era_replaces_the_container_and_the_same_era_reuses_it
    shell = FakeShell.new
    inspector = FakeInspector.new
    started = services(runner: shell, inspector: inspector)

    started.ensure!(entry(name: "2.1"), stage: "interpreter", stages: [])
    started.ensure!(entry(name: "2.1"), stage: "interpreter", stages: [])
    assert_equal 1, shell.calls.length, "the same era must not start a second container"

    started.ensure!(entry(name: "2.2", ruby: "2.2.10", image: "era-2.2"), stage: "interpreter", stages: [])
    assert_equal 2, shell.calls.length
    assert_includes shell.calls.last[:argv].join(" "), "era-2.2"
    assert_equal ["docker rm --force c0ffee"], inspector.calls
  end

  # The services script runs *in* the container, with the application's own directory as the
  # working directory translated onto the mount — because that is where it reads the
  # `database.yml` whose roles and databases it creates.
  def test_the_services_script_runs_in_the_container_with_the_application_s_directory
    started = services(pg_port: 55432)
    started.ensure!(entry, stage: "interpreter", stages: [])
    work = File.join(@home, "work", "abc", "run-1")

    argv = started.command(["agents-fyi-services"], chdir: work)

    assert_equal ["docker", "exec", "--interactive", "--user", "#{Process.uid}:#{Process.gid}",
      "--workdir", "/agents-fyi/work/abc/run-1", "c0ffee", "agents-fyi-services"], argv
  end

  # A path outside the walker's home is refused rather than translated into a directory nobody
  # looked at — the same rule the step container enforces, through the same function.
  def test_a_directory_outside_the_home_is_refused
    started = services
    started.ensure!(entry, stage: "interpreter", stages: [])

    assert_raises(Machine::Unavailable) { started.command(["agents-fyi-services"], chdir: "/tmp") }
  end

  # What the application's commands read to find the services. `PGHOST` is set even when the
  # `database.yml` names no host: libpq's default is the Unix socket, and a socket inside a
  # container is not one the host can open.
  def test_the_environment_names_the_host_and_both_ports
    started = services(pg_port: 55432, redis_port: 56379)

    assert_equal({ "PGHOST" => "127.0.0.1", "PGPORT" => "55432",
                   "REDIS_URL" => "redis://127.0.0.1:56379" }, started.env)
  end

  # Removed when the walk is over — and a walker that was *killed* runs no cleanup, which is
  # what the reap answers: the container carries the pid of the process that owns it.
  def test_stopping_removes_the_container_and_a_second_stop_is_not_an_error
    inspector = FakeInspector.new
    started = services(inspector: inspector)
    started.ensure!(entry, stage: "interpreter", stages: [])

    started.stop!

    assert_equal ["docker rm --force c0ffee"], inspector.calls
    assert_nil started.container_id
    assert_nil started.stop!
    assert_equal 1, inspector.calls.length
  end

  # A container that will not start is a sentence about the services, not a silent success: the
  # step's own refusal then says the services could not be started rather than blaming the
  # application's bundle.
  def test_a_container_that_will_not_start_is_a_sentence
    shell = FakeShell.new(exit_code: 125, output: "docker: Error response from daemon\n")
    started = services(runner: shell)
    stages = []

    refute started.ensure!(entry, stage: "interpreter", stages: stages)

    assert_includes started.unavailable, "the services container would not start"
    assert_includes started.unavailable, "Error response from daemon"
    assert_nil started.container_id
    assert_equal 1, stages.length
  end
end
