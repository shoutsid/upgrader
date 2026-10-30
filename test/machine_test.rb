# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "agents/upgrader"

# The machine a step's application-level commands run on.
#
# Nothing here starts a container. What is asserted is the argv each machine *composes* — the
# command that would start a container, the `docker exec` that carries one command into it,
# the environment handed over as flags, the working directory translated from the host's path
# to the container's — plus the two things a started container must prove: that it came up,
# and that the interpreter inside it is the one the matrix promised. A test that required a
# daemon would be a test the unit suite cannot run, and the argv is the whole contract with
# the daemon anyway.
class MachineTest < Minitest::Test
  Machine = Agents::Upgrader::Machine
  Interpreters = Agents::Upgrader::Interpreters
  Command = Agents::Upgrader::Record::Command

  # The shell, answering by substring: the `docker run` gets a container id, `ruby -v` gets the
  # interpreter's own line, and anything else gets a zero exit with no output — which is what
  # a command that worked prints.
  class FakeShell
    attr_reader :calls

    def initialize(answers: {})
      @answers = answers
      @calls = []
    end

    def run(argv, stage:, chdir:, env: {}, stdin: nil, timeout: nil, excerpt_bytes: nil)
      line = argv.join(" ")
      @calls << { argv: argv, stage: stage, chdir: chdir, env: env, stdin: stdin, timeout: timeout }
      exit_code, output = @answers.find { |needle, _| line.include?(needle) }&.last || [0, ""]
      Command.new(stage: stage, command: line, ran: true, exit_code: exit_code,
        seconds: 0.0, output_tail: output.to_s)
    end
  end

  # What `docker image inspect` prints for a rebuilt image, what `docker inspect` prints for
  # this process's own mounts, and what `docker ps` lists for the containers a killed run left
  # behind — so the digest a stamp carries, the volume an era container joins and the reaping
  # are stated by the test rather than by the daemon.
  class FakeInspector
    attr_reader :calls

    def initialize(sha: "b" * 64, volume: "", listing: "")
      @sha = sha
      @volume = volume
      @listing = listing
      @calls = []
    end

    def capture2e(*argv)
      @calls << argv
      line = argv.join(" ")
      return [@listing, nil] if line.include?("docker ps")
      return ["#{@volume}\n", nil] if line.include?("Mounts")

      ["sha256:#{@sha}\n", nil]
    end
  end

  def entry(name: "2.2", ruby: "2.2.10", image: "agents-upgrader-ruby-2.2:dev",
            bundler: "1.17.3")
    Interpreters::Entry.new(name: name, ruby: ruby, image: image,
      base: "ruby:2.2@sha256:#{"a" * 64}", bundler: bundler)
  end

  # The home a machine starts against has to be a directory this process can write to —
  # `start!` creates the two directories the container's environment points at — so the
  # tests get a temporary one rather than a path that reads well and does not exist.
  def container(home: nil, runner: nil, inspector: FakeInspector.new, volume: "",
                self_marker: "/nonexistent-self-marker", out: nil, disk_limits: nil,
                mounts: Machine::DiskLimit::MOUNTS, **kwargs)
    home ||= temp_home
    Machine::Container.new(entry: entry(**kwargs), home: home, runner: runner || FakeShell.new,
      uid: 1000, gid: 1000, run_id: "run1", inspector: inspector, volume: volume,
      self_marker: self_marker, out: out, disk_limits: disk_limits, mounts: mounts)
  end

  # A mount table as the kernel writes one, so the device a cap names is stated by the test
  # rather than read from the machine running it.
  def mounts_file(*lines)
    path = File.join(temp_home, "mounts")
    File.write(path, lines.join("\n") + "\n")
    path
  end

  def temp_home
    dir = Dir.mktmpdir
    (@homes ||= []) << dir
    dir
  end

  def teardown
    @homes&.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def test_a_command_is_an_exec_into_the_step_s_container
    machine = container(home: "/home/walker")
    machine.instance_variable_set(:@container_id, "abc123")
    argv, env = machine.command(%w[bundle install], chdir: "/home/walker/work/tree", env: {})

    # `--user` on every exec, and never on the container: the container's own process runs as
    # root so it can name the walker's uid (`agents-start`), and every command that
    # touches the application runs as the account that owns the mounted home.
    #
    # **`--interactive` is the other half, and a walk is what proved it**: without it `docker exec`
    # leaves the process with no stdin at all, so `app:update`'s `Overwrite config/boot.rb?` read
    # nothing, asked again, and repeated the question until the command bound killed it — with the
    # answer pipe the walker had just started giving it sitting unread on the host side.
    assert_equal ["docker", "exec", "--interactive", "--user", "1000:1000", "--workdir",
                  "/agents/work/tree", "abc123", "bundle", "install"], argv
    assert_empty env, "a container command's environment is the flags, not this process's"
  end

  # **A package installed for the application runs as root, and nothing else does.** The image
  # installs its own packages at build time; a package the application's workflow declares arrives
  # after the container is up, and `apt-get install` cannot write outside the working copy as the
  # walker's uid.
  def test_a_package_install_is_the_one_command_that_runs_as_root
    machine = container(home: "/home/walker")
    machine.instance_variable_set(:@container_id, "abc123")
    argv, env = machine.root_command(["sh", "-lc", "apt-get install -y libidn11-dev"],
      chdir: "/home/walker/work/tree", env: {})

    assert_equal "0:0", argv[argv.index("--user") + 1]
    assert_equal ["sh", "-lc", "apt-get install -y libidn11-dev"], argv.last(3)
    assert_empty env
    refute_includes argv, "1000:1000", "a root command carried the walker's uid as well"
  end

  # The run's bundle lives under the walker's home on the host and under the mount inside the
  # container, and the two paths are the same directory: a `BUNDLE_PATH` that named the host
  # path would be a path the interpreter inside cannot see, and the bundle it installed would
  # be looked for in the wrong place for the whole of the suite.
  def test_the_environment_travels_as_flags_with_the_paths_translated
    machine = container(home: "/home/walker")
    machine.instance_variable_set(:@container_id, "abc123")
    argv, _env = machine.command(["bundle", "install"], chdir: "/home/walker/work/tree",
      env: { "BUNDLE_PATH" => "/home/walker/bundles/x", "BUNDLE_WITHOUT" => "development" })

    assert_includes argv, "BUNDLE_PATH=/agents/bundles/x"
    assert_includes argv, "BUNDLE_WITHOUT=development"
    assert_equal "abc123", argv[argv.index("BUNDLE_WITHOUT=development") + 1]
  end

  def test_a_command_line_runs_through_a_shell_inside_the_container
    machine = container(home: "/home/walker")
    machine.instance_variable_set(:@container_id, "abc123")
    argv, _env = machine.script("bundle exec rspec", chdir: "/home/walker/work/tree", env: {})

    assert_equal ["sh", "-lc", "bundle exec rspec"], argv.last(3)
    assert_equal "bundle exec rspec", argv.last
  end

  # Anything outside the mounted home does not exist inside the container, and a command sent
  # to it would run in whatever directory the container did find. Refused by name rather than
  # silently rewritten.
  def test_a_path_outside_the_home_is_refused_rather_than_translated
    machine = container(home: "/home/walker")
    error = assert_raises(Machine::Unavailable) do
      machine.command(%w[true], chdir: "/somewhere/else", env: {})
    end
    assert_includes error.message, "outside this step's home"
  end

  def test_the_stamp_names_the_interpreter_and_the_image_digest
    strip = container(inspector: FakeInspector.new(sha: "c" * 64))
    assert_equal "ruby 2.2.10 (agents-upgrader-ruby-2.2:dev@sha256:#{"c" * 64})", strip.stamp
  end

  # **The pin asks the machine for its Bundler, and the container is the machine a walk runs
  # on.** The step's own test double answered this first, so the sample 7.2.4 pin silently kept
  # the lock's Bundler 1.17.3 on the 3.1 era; the real container must answer the matrix's entry.
  def test_the_container_names_the_bundler_its_image_installs
    assert_equal "1.17.3", container.bundler
    assert_equal "2.5.9", container(name: "3.1", ruby: "3.1.7",
      image: "agents-upgrader-ruby-3.1:dev", bundler: "2.5.9").bundler
  end

  # A rebuilt image is a new machine: the digest is what makes yesterday's verdict not stand
  # on today's bytes, which is the rule the ledger's own stamp documents.
  def test_a_rebuilt_image_is_a_different_machine
    first = container(inspector: FakeInspector.new(sha: "d" * 64)).stamp
    second = container(inspector: FakeInspector.new(sha: "e" * 64)).stamp
    refute_equal first, second
  end

  def test_an_image_the_daemon_cannot_describe_still_has_a_stamp
    machine = container(inspector: FakeInspector.new(sha: "not-a-digest"))
    assert_equal "ruby 2.2.10 (agents-upgrader-ruby-2.2:dev)", machine.stamp
  end

  # Starting a container is two commands and both are recorded: the `docker run` that started
  # it, and the `ruby -v` that proves it is the interpreter the matrix promised. The second is
  # what catches a matrix that drifted from its image, which nothing else would see until a
  # step failed for a reason nobody could explain.
  def test_starting_the_container_verifies_the_interpreter_inside_it
    shell = FakeShell.new(answers: {
      "docker run" => [0, "f00dfeed\n"],
      "ruby -v" => [0, "ruby 2.2.10p489 (2018-03-28 revision 63023) [x86_64-linux]\n"]
    })
    machine = container(runner: shell)
    stages = []

    assert machine.start!(stage: "interpreter", stages: stages)
    assert_match(/^docker run /, stages.first.command)
    assert_match(/ruby -v/, stages.last.command)
    assert_equal "f00dfeed", machine.container_id
  end

  def test_a_container_running_another_interpreter_fails_the_start_and_says_which
    shell = FakeShell.new(answers: {
      "docker run" => [0, "f00dfeed\n"],
      "ruby -v" => [0, "ruby 2.7.8p225 (2023-03-30 revision 1f4d455848) [x86_64-linux]\n"]
    })
    machine = container(runner: shell)

    refute machine.start!(stage: "interpreter", stages: [])
    assert_includes machine.unavailable, "ruby 2.7.8"
    assert_includes machine.unavailable, "matrix"
  end

  def test_a_container_that_will_not_start_fails_with_the_daemon_s_own_sentence
    shell = FakeShell.new(answers: { "docker run" => [125, "Error response from daemon: pull access denied\n"] })
    machine = container(runner: shell)

    refute machine.start!(stage: "interpreter", stages: [])
    assert_includes machine.unavailable, "pull access denied"
  end

  # How the walker's home reaches the container. On a host it is a bind mount of the absolute
  # path; inside a walker container it is the *named volume*, because a bind mount written from
  # inside a container names a host path the daemon would create empty — a working copy that is
  # not there, and install failures that look like the application's.
  #
  # The volume is *discovered*, not configured: a containerised walker asks the daemon which
  # volume its own home is mounted from. The test states the answer where a daemon would, and
  # the marker file that says "this process is in a container" is a parameter for the same
  # reason.
  def test_the_home_is_bind_mounted_on_a_host_and_joined_by_name_in_a_container
    started = { "docker run" => [0, "f00dfeed\n"], "ruby -v" => [0, "ruby 2.2.10\n"] }
    home = temp_home
    host = container(home: home, runner: FakeShell.new(answers: started))
    host.start!(stage: "interpreter", stages: [])
    run_argv = host.instance_variable_get(:@runner).calls.first[:argv].join(" ")
    assert_includes run_argv, "--mount type=bind,source=#{home},target=/agents"
    assert_includes run_argv, "AGENTS_UID=1000", "the start script is not told which uid to name"
    assert_includes run_argv, "agents-start", "the container is not started through the naming script"

    wrapped = container(runner: FakeShell.new(answers: started), self_marker: __FILE__,
      inspector: FakeInspector.new(volume: "agents_upgrader_cache"))
    wrapped.start!(stage: "interpreter", stages: [])
    assert_includes wrapped.instance_variable_get(:@runner).calls.first[:argv].join(" "),
      "--mount type=volume,source=agents_upgrader_cache,target=/agents"
  end

  def test_an_operator_can_name_the_volume_when_the_daemon_will_not_answer
    started = { "docker run" => [0, "f00dfeed\n"], "ruby -v" => [0, "ruby 2.2.10\n"] }
    pinned = container(runner: FakeShell.new(answers: started), self_marker: __FILE__,
      inspector: FakeInspector.new(volume: ""), volume: "named-by-the-operator")
    pinned.start!(stage: "interpreter", stages: [])
    assert_includes pinned.instance_variable_get(:@runner).calls.first[:argv].join(" "),
      "--mount type=volume,source=named-by-the-operator,target=/agents"
  end

  def test_stopping_a_container_that_never_started_is_not_an_error
    assert_nil container.stop!
  end

  # **A daemon call that never answers costs its deadline, not the caller.** What this deployment
  # measured was not "docker is down" — the callers already handle that — but "docker is answering,
  # and this call is not coming back": `ps`, `version`, `images` and `df` returned in milliseconds
  # while `create`, `run` and `rm` hung for minutes. A `Timeout` turns the second into the first.
  def test_a_daemon_call_that_never_answers_returns_empty_after_its_deadline
    hang = Object.new
    def hang.capture2e(*) = sleep

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    answer = Agents::Upgrader::Machine.docker(hang, "docker", "create", "alpine", seconds: 0.2)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal ["", nil], answer
    assert_operator elapsed, :<, 2.0, "the bound did not bound anything"
  end

  # **No call site may reach the inspector directly**, or the bound is a helper that half the code
  # skips — which is exactly how the teardown fix left `docker run` unbounded and the next rung hung.
  def test_the_machine_reaches_the_daemon_only_through_the_bounded_helper
    source = File.read(File.expand_path("../lib/agents/upgrader/machine.rb", __dir__))
    offenders = source.lines.each_with_index.filter_map do |line, number|
      next unless line.match?(/inspector\.capture[23]/)
      next if line.include?("inspector.capture2e(*argv)")

      "#{number + 1}: #{line.strip}"
    end

    assert_empty offenders, "a daemon call bypasses Machine.docker, so a wedged daemon holds it for ever"
  end

  # **The teardown is bounded, because it is the one call that can hold a step that has already
  # finished.** `docker rm` talks to the daemon, and a daemon that is restarting held one walk for three
  # minutes at exactly this line: the suite had passed, the run was recorded, and the publish behind the
  # `ensure` had not run — from outside, a walk that stopped for no reason. Measured on the deployment's
  # 4.0.0 -> 4.1.0 rung, whose `PASSED` line is followed by three minutes of nothing until the hung
  # `docker rm` was killed by hand. `Shell.run` bounds it and kills its process group; the container is
  # `--rm`, so leaving it is safe and `reap!` sweeps what a dead owner leaves.
  def test_the_step_container_is_torn_down_through_the_bounded_runner
    runner = FakeShell.new(answers: { "docker run" => [0, "f00dfeed\n"], "ruby -v" => [0, "ruby 2.2.10\n"] })
    started = container(runner: runner)
    started.start!(stage: "interpreter", stages: [])

    started.stop!

    removal = runner.calls.find { |call| call[:argv].first(2) == ["docker", "rm"] }
    refute_nil removal, "the container was not removed at all"
    assert_equal Agents::Upgrader::Machine::TEARDOWN_SECONDS, removal[:timeout],
      "the teardown has no deadline, so a wedged daemon holds a step that already passed"
  end

  # A pid that is certainly gone: this process's own child, waited for.
  def dead_pid
    pid = Process.spawn("true")
    Process.wait(pid)
    pid
  end

  # **The container carries the pid of the process that owns it.** `--rm` removes a container
  # when its own process exits, and this container's process is a keepalive that never does —
  # so a walker that is *killed* leaves a container running for ever, and the pid on the
  # container is what lets the next run tell "in flight" from "abandoned".
  def test_the_container_is_labelled_with_the_process_that_owns_it
    shell = FakeShell.new(answers: { "docker run" => [0, "c0ffee\n"], "ruby -v" => [0, "ruby 2.2.10\n"] })
    container(runner: shell).start!(stage: "interpreter", stages: [])

    run_argv = shell.calls.first[:argv].join(" ")
    assert_includes run_argv, "--label org.agents.upgrader.step=agents-step-run1-2-2"
    assert_includes run_argv, "--label org.agents.upgrader.pid=#{Process.pid}"
  end

  # **A deployment that shares its daemon with a served application caps the step's disk rate.**
  # The flags are the contract: `io.max` is what keeps a `bundle install` from queueing every
  # query the application's own PostgreSQL makes, and a cap that named no device would be
  # silently absent rather than visible in the argv.
  def test_a_step_carries_the_disk_rate_the_deployment_named
    started = { "docker run" => [0, "c0ffee\n"], "ruby -v" => [0, "ruby 2.2.10\n"] }
    shell = FakeShell.new(answers: started)
    machine = container(runner: shell, disk_limits: { "read" => "80mb", "write" => "40mb" },
      mounts: mounts_file("/dev/vda1 / ext4 rw,relatime 0 0"))

    machine.start!(stage: "interpreter", stages: [])

    argv = shell.calls.first[:argv]
    assert_includes argv.join(" "), "--device-read-bps /dev/vda1:80mb"
    assert_includes argv.join(" "), "--device-write-bps /dev/vda1:40mb"
    assert_operator argv.index("--device-write-bps"), :<, argv.index("--mount"),
      "the cap is after the mount, so a daemon parsing the command sees the mount first"
  end

  # The home is what the cap is about, and a volume or a bind can sit on its own mount: the
  # innermost mount is the device the writes will actually reach.
  def test_the_innermost_mount_behind_the_home_names_the_device
    home = temp_home
    shell = FakeShell.new(answers: { "docker run" => [0, "c0ffee\n"], "ruby -v" => [0, "ruby 2.2.10\n"] })
    machine = container(home: home, runner: shell, disk_limits: { "write" => "40mb" },
      mounts: mounts_file("/dev/vda1 / ext4 rw 0 0", "/dev/vdb1 #{home} ext4 rw 0 0"))

    machine.start!(stage: "interpreter", stages: [])

    assert_includes shell.calls.first[:argv].join(" "), "--device-write-bps /dev/vdb1:40mb"
  end

  # A cap with no device behind the home is stated and skipped: the step still runs, because a
  # limit that could not be applied is not evidence about the release.
  def test_a_cap_with_no_block_device_is_stated_and_skipped
    out = StringIO.new
    shell = FakeShell.new(answers: { "docker run" => [0, "c0ffee\n"], "ruby -v" => [0, "ruby 2.2.10\n"] })
    machine = container(runner: shell, out: out, disk_limits: { "write" => "40mb" },
      mounts: mounts_file("tmpfs / tmpfs rw 0 0", "proc /proc proc rw 0 0"))

    assert machine.start!(stage: "interpreter", stages: [])

    assert_empty shell.calls.first[:argv].grep(/--device-\w+-bps/)
    assert_includes out.string, "no block device behind"
  end

  # A container whose owner is gone is removed; a container whose owner is running — a step
  # in flight, possibly somebody else's — is not, and the check errs that way on purpose.
  def test_a_container_whose_owner_is_gone_is_reaped_and_a_live_one_is_not
    gone = dead_pid
    listing = [
      "aaa111\tagents-step-20261017193851-#{gone}-2-1\t",
      "bbb222\tagents-step-20261017193851-#{Process.pid}-2-1\t#{Process.pid}"
    ].join("\n") + "\n"
    inspector = FakeInspector.new(listing: listing)

    assert_equal ["aaa111"], Machine::Container.reap!(inspector: inspector)
    refute_includes inspector.calls.map { |argv| argv.join(" ") }, "docker rm --force bbb222"
  end

  # A container started before the labels existed still states its owner in its name, which is
  # the run id `Step#run_id` composes — `<timestamp>-<pid>` — so the reaper finds the ones
  # already on a daemon rather than only the ones it starts from now on.
  def test_a_container_from_before_the_labels_is_reaped_through_the_pid_in_its_name
    listing = "ccc333\tagents-step-20261017193851-#{dead_pid}-2-1\t\n"

    assert_equal ["ccc333"], Machine::Container.reap!(inspector: FakeInspector.new(listing: listing))
  end

  # The reaping is not only an operator's command: a step removes what the step before it left,
  # which is what keeps the leak from accumulating in the first place.
  def test_starting_a_container_reaps_what_a_killed_run_left_behind
    inspector = FakeInspector.new(
      listing: "ddd444\tagents-step-20261017193851-#{dead_pid}-2-1\t\n"
    )
    machine = container(runner: FakeShell.new(
      answers: { "docker run" => [0, "c0ffee\n"], "ruby -v" => [0, "ruby 2.2.10\n"] }
    ), inspector: inspector)

    assert machine.start!(stage: "interpreter", stages: [])

    assert_includes inspector.calls.map { |argv| argv.join(" ") }, "docker rm --force ddd444"
  end

  # The native machine is this process, and its identity is the interpreter plus the image, if
  # this deployment runs in one — the same rule `Ledger.machine` uses, because the two have to
  # agree for a settled move to stay settled.
  def test_the_native_machine_is_this_process
    native = Machine::Native.new
    argv, env = native.command(%w[bundle install], chdir: "/tmp", env: { "A" => "B" })

    assert_equal %w[bundle install], argv
    assert_equal({ "A" => "B" }, env)
    assert_equal [["bundle exec rspec"], {}], native.script("bundle exec rspec", chdir: "/tmp", env: {})
    refute native.services?
    assert_nil native.era
    assert_equal "ruby #{RUBY_VERSION}", native.interpreter
  end
end
