# frozen_string_literal: true

require "minitest/autorun"

# What the deployment decides about the upgrader, read out of the two files that decide
# it rather than out of prose.
#
# Two of these rules are invisible at runtime and expensive to get wrong. A client that
# can reach the database has stopped being a client — the whole argument for the miner
# and the verifiers being separate containers is that the worst any of them can do is
# what any *operator* could do, and a database driver in the web upgrader's image would
# end that. And a shared *environment* directory is the one thing that must never happen
# between two clients that execute releases, because a gemset is evidence rather than an
# artifact (`miner/test/deploy_config_test.rb` carries the argument in full).
#
# Both would ship quietly: a container configured wrongly starts perfectly and reports
# healthy. That is why this is a test and not a comment.
#
# Text is sliced by name rather than parsed as YAML, and the slicing is the point: the
# question is *which service* mounts what, and a substring over the whole file cannot
# tell one service's mount from another's — the same reason the miner's test parses its
# compose file. Slicing by the two-space indent a service starts at is enough here, and
# it keeps this suite on `minitest` and the standard library alone, which is the rule
# for everything in `upgrader/`.
class DeployConfigTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  COMPOSE_PATH = File.join(ROOT, "docker-compose.yml")
  DOCKERFILE_PATH = File.join(ROOT, "components", "upgrader", "Dockerfile")
  ENTRYPOINT_PATH = File.join(ROOT, "components", "upgrader", "entrypoint.sh")
  CLI_PATH = File.join(ROOT, "components", "upgrader", "lib", "agents_fyi", "upgrader", "cli.rb")
  ENV_EXAMPLE_PATH = File.join(ROOT, ".env.example")

  def compose
    @compose ||= File.read(COMPOSE_PATH, encoding: "utf-8")
  end

  def dockerfile
    @dockerfile ||= File.read(DOCKERFILE_PATH, encoding: "utf-8")
  end

  def entrypoint
    @entrypoint ||= File.read(ENTRYPOINT_PATH, encoding: "utf-8")
  end

  def cli
    @cli ||= File.read(CLI_PATH, encoding: "utf-8")
  end

  def env_example
    @env_example ||= File.read(ENV_EXAMPLE_PATH, encoding: "utf-8")
  end

  # Every flag the entrypoint hands the CLI's `serve` mode, in the order it appears.
  def entrypoint_flags
    invocation = entrypoint[/^exec \/app\/bin\/agents-fyi-upgrader serve.*\z/m]
    refute_nil invocation, "the entrypoint does not exec the CLI's serve mode"
    invocation.scan(/--[a-z][a-z-]*/).uniq
  end

  # Every line that is not a comment, for the reason the miner's test removes them from
  # its image: these files' comments *quote* the strings that must not appear. The one
  # above the upgrader's mount says "no `DB_PASSWORD` and no admin token in its
  # environment" — so a check over the raw text would pass because a comment promised the
  # right thing, which is the failure mode of a test that reads prose as configuration.
  def uncommented(text)
    text.lines.reject { |line| line.lstrip.start_with?("#") }.join
  end

  # One service's own block, from its name to the next service or the `volumes:`
  # section.
  def service(name)
    found = compose.match(/^  #{Regexp.escape(name)}:\n(.*?)(?=^  [\w-]+:\n|^volumes:\n|\z)/m)
    refute_nil found, "no service named #{name} in docker-compose.yml"
    found[0]
  end

  # The same block with its comments removed, which is what the "must not be here"
  # assertions read.
  def config(name)
    uncommented(service(name))
  end

  # A one-line value out of the image's instructions, with the comment lines dropped.
  # The `ENV` block is a line-continuation form, so a declaration is its own line and
  # may be indented — and the first one of them is preceded by `ENV `, which is why the
  # prefix is optional here rather than assumed absent.
  def image_env(name)
    found = uncommented(dockerfile).match(/^\s*(?:ENV\s+)?#{Regexp.escape(name)}=(\S+)/)
    refute_nil found, "the image does not declare #{name}"
    found[1]
  end

  def service_value(name, key)
    found = config(name).match(/^\s+#{Regexp.escape(key)}:\s*(\S+)\s*$/)
    refute_nil found, "#{name} does not set #{key}"
    found[1]
  end

  def test_the_service_has_a_waiter_in_front_of_it_that_gives_up
    block = config("upgrader")

    assert_includes block, "entrypoint: [\"/app/entrypoint.sh\"]",
      "the container is not started through the loop's entrypoint"

    # The waiter, and the bound. A process that started against a socket nobody was
    # listening on spends its first cycle logging an outage it did not have; a process
    # that *refused* to start because the API is down is worse, because the loop already
    # treats an unreachable corpus as something to wait out.
    assert_includes entrypoint, "/health"
    assert_match(/attempt=0.*-ge 60/m, entrypoint)
    assert_includes entrypoint, "starting anyway"

    assert_includes entrypoint, "exec /app/bin/agents-fyi-upgrader serve"
    assert_includes entrypoint, "--heartbeat"
    assert_includes entrypoint, "--home"
    refute_includes entrypoint, "step --repo",
      "the service runs one mode; a step is the loop's business"

    # The list is only passed when there is one. Expanded unconditionally, an empty
    # `${UPGRADER_REPOS}` would leave `--repos` with nothing to take and the flag after it
    # would be read as its value — a service that starts, reports healthy, and has been
    # told a repository called `--interval`. The same rule now covers the flags `--walk`,
    # `--rungs` and `--publish`, each appended to the same positional list.
    assert_match(/if \[ -n "\$\{UPGRADER_REPOS\}" \]; then/, entrypoint)
    assert_includes entrypoint, 'set -- "$@" --repos ${UPGRADER_REPOS}'
    %w[UPGRADER_WALK UPGRADER_RUNGS UPGRADER_PUBLISH].each do |setting|
      assert_match(/if \[ -n "\$\{#{setting}\}" \]; then/, entrypoint,
        "#{setting} is not checked before its flag is passed")
    end
  end

  # The waiter's probe is a Ruby program inside a shell script, and it shipped as a syntax
  # error: `exit(0 if response.is_a?(Net::HTTPSuccess) else 1)` — Ruby has no postfix `if`
  # with an `else` — so every attempt exited 1, the loop always burned its full five
  # minutes, and it then reported that an API answering `/health` "did not come up". The
  # probe's stderr goes to `/dev/null`, so the parser's complaint went with it.
  #
  # So: the snippet is compiled by the interpreter, not matched against a shape somebody
  # remembered to forbid. `RbConfig.ruby` is the Ruby running this suite, which is the one
  # the image pins — the same interpreter that would run the probe in the container.
  def test_the_waiters_probe_is_ruby_that_compiles
    snippets = entrypoint.scan(/ruby\s[^\n]*?-e\s+'((?:[^']|\n)*?)'/m).flatten
    refute_empty snippets,
      "no Ruby program was found in the entrypoint: if the probe's quoting changed, teach " \
      "this extractor the new shape rather than deleting the check"

    snippets.each do |snippet|
      # The shell's own value for the variable the snippet reads, so what is compiled is
      # the program the container runs rather than a template with a placeholder in it.
      source = snippet.gsub('${API_BASE_URL}', "http://service:8001")
      output = IO.popen([RbConfig.ruby, "-c", "-e", source], err: [:child, :out], &:read)
      assert_includes output, "Syntax OK", "the waiter's probe does not compile:\n#{output}"
    end
  end

  def test_the_image_can_be_repointed_at_another_interpreter_without_losing_its_pin
    found = uncommented(dockerfile).match(/^ARG RUBY_IMAGE=(ruby:[^\s@]+@sha256:[0-9a-f]{64})$/)
    refute_nil found, "the base image's default is not pinned by digest"

    instructions = uncommented(dockerfile)
    assert_includes instructions, "FROM ${RUBY_IMAGE}"

    # Every `FROM` either takes the argument or carries its own digest: a bare tag is a
    # base that changes under the image without anybody deciding it should.
    froms = instructions.scan(/^FROM .*$/)
    refute_empty froms
    froms.each do |line|
      assert(line.include?("${RUBY_IMAGE}") || line.include?("@sha256:"),
        "#{line.strip} is not pinned")
    end
  end

  def test_the_client_cannot_reach_the_database_and_holds_no_admin_token
    block = config("upgrader")

    # The two credentials that would stop it being a client. The admin token is the
    # moderation surface — hide, unhide, disable, mark-live — and handing a background
    # container that so it could call one route is the mistake this rules out.
    refute_includes block, "DB_PASSWORD"
    refute_includes block, "ADMIN_TOKEN"
    # And no dependency on the database, however it is spelled: `depends_on: db` is the
    # one that would be written by somebody making the service start in a nicer order.
    refute_match(/^\s+db:\s*$/, block)
    refute_includes block, "postgresql"

    # And it *does* wait for the service: a loop that starts before the thing it reads is up
    # spends its first cycle riding out an outage it could have waited through.
    assert_includes block, "service:\n        condition: service_healthy",
      "the client does not wait for the service to be healthy"
  end

  def test_the_gems_are_shared_and_the_ledger_is_shared_with_nobody
    block = config("upgrader")

    # Both mounts are read back from the image rather than repeated here: the paths are
    # the interpreter's own idea of where gems and the home live, so a Dockerfile that
    # moved one must move the mount with it or this fails. A test that hard-coded the
    # path would keep passing after the image moved it, and the volume would be mounted
    # over a directory nothing ever looked in.
    assert_includes block, "upgrader_gems:#{image_env("GEM_HOME")}",
      "the gem cache is not mounted where the image keeps gems"
    assert_includes block, "upgrader_cache:#{image_env("UPGRADER_HOME")}",
      "the ledger is not mounted where the image keeps its home"

    # The ledger is state: it is one service's, and another client mounting it would be
    # two loops writing one book. The gem cache is the opposite kind of thing and is
    # shared for the reason `pip_cache` is.
    others = %w[miner verifier verifier-independent].count { |name| config(name).include?("upgrader_cache:") }
    assert_equal 0, others, "another client mounts the upgrader's ledger"
  end

  # **The application's environment is a value the container writes, not a file it mounts.** It was a
  # host bind, and a bind mount is a dependency on the host's file sharing: with that off the setting
  # named a path the container could not see, so a repository whose suite needs a secret from a
  # git-ignored file could never boot it — for ever, with the container reporting healthy while it
  # happened. Measured on the deployment: 4.0.0 -> 4.1.0 came out `unverified` with the pin,
  # `app:update`, the boot and the post-move suite *all exiting 0*, the baseline red on
  # `RuntimeError: You must set config.secret_key_base in your app's config` — the walk's first real
  # application sets `secret_key_base` from `ENV["RAILS_SECRET_TOKEN"]`.
  def test_the_application_environment_is_a_value_the_container_writes_itself
    block = config("upgrader")

    assert_match(/UPGRADER_SUITE_ENV:\s*\$\{UPGRADER_SUITE_ENV:-\}/, block,
      "the value an operator sets is not forwarded to the container")
    refute_match(%r{suite\.env:/etc/agents-fyi/suite\.env}, block,
      "the deployment still bind-mounts a host file, which the host's file sharing may refuse")

    entrypoint = File.read(ENTRYPOINT_PATH, encoding: "utf-8")
    assert_includes entrypoint, '"${UPGRADER_HOME}/suite.env"',
      "the entrypoint does not write the value into the service's own home"
    assert_includes entrypoint, 'UPGRADER_SUITE_ENV_FILE="${UPGRADER_HOME}/suite.env"',
      "the entrypoint does not hand the CLI the path it just wrote"
  end

  # **The operator's live view is mounted where the console reads it.** The walker writes what it is
  # doing into a volume of its own (`Progress`) and the console reads it read-only; without the mount
  # the panel says "not mounted" — honest, but "is it working?" then has no answer again. Measured:
  # the loop sat in a pipe read with no child for long enough that the question was asked of the
  # logs, and the run it was inside of is only written when the step *ends*.
  def test_the_walkers_live_view_is_mounted_where_the_console_reads_it
    assert_includes config("upgrader"), "upgrader_state:/home/upgrader/.cache/agents-fyi-upgrader/state",
      "the walker does not mount the volume its live view is written to"

    service = config("service")
    assert_includes service, "upgrader_state:/var/lib/agents-fyi/upgrader-state:ro",
      "the console does not mount the walker's view, so its page cannot say what it is doing"
    assert_includes service, "UPGRADER_STATE_DIR: /var/lib/agents-fyi/upgrader-state",
      "the console is pointed somewhere other than where the volume is mounted"
    assert_includes compose, "\n  upgrader_state:",
      "the volume the two halves share is not declared"
  end

  def test_the_service_that_executes_steps_is_built_with_a_compiler
    # A step installs a real application's bundle, and a bundle names gems that ship no
    # prebuilt binary — so this image needs a toolchain, and the `plan`-only image must
    # not grow one. Two halves of one sentence, and both are asserted, because either
    # half alone is a deployment that starts, reports healthy and completes no step:
    # that is `AGENTS.md`'s miner trap (finished and stuck look identical from outside)
    # with no error logged anywhere to say which it is.
    assert_includes config("upgrader"), "WITH_BUILD_TOOLS: 1",
      "the service is built without a compiler, so every step that needs one fails"

    # Read out of the instructions with the comments dropped, or this would pass on the
    # Dockerfile's own prose — the failure mode the comment above `uncommented` records.
    instructions = uncommented(dockerfile)
    assert_includes instructions, "ARG WITH_BUILD_TOOLS=0",
      "the default build would carry a toolchain that only `step` needs"
    assert_match(/if \[ "\$WITH_BUILD_TOOLS" = "1" \]/, instructions,
      "the argument is declared but nothing is installed when it is set")
    %w[build-essential libsqlite3-dev libyaml-dev].each do |package|
      assert_includes instructions, package, "#{package} is not installed by any instruction"
    end
  end

  # The repair agent, and the two halves that fail differently: an image without the binary
  # cannot repair at all (it says so, once, per attempt), and a setting the container never
  # receives is a budget nothing reads. Both are asserted here because both fail *quietly* —
  # the loop reports a failed step either way.
  def test_the_service_that_repairs_carries_the_agent_and_the_budget
    assert_includes config("upgrader"), "WITH_REPAIR_AGENT: 1",
      "the service is built without the repair agent, so every red suite is the end of the rung"

    instructions = uncommented(dockerfile)
    assert_includes instructions, "ARG WITH_REPAIR_AGENT=0",
      "the default build would carry a model client that only the loop needs"
    assert_includes instructions, "opencode-ai", "the agent is never installed"
    assert_match(/if \[ "\$WITH_REPAIR_AGENT" = "1" \]/, instructions,
      "the argument is declared but nothing is installed when it is set")

    block = config("upgrader")
    %w[UPGRADER_REPAIR_ATTEMPTS UPGRADER_REPAIR_TIMEOUT UPGRADER_REPAIR_MODEL
       UPGRADER_REPAIR_AGENT].each do |setting|
      assert_match(/^\s+#{setting}: \$\{#{setting}:-\}/, block,
        "#{setting} is not forwarded to the container")
      assert_includes env_example, "#{setting}=",
        "#{setting} is not in .env.example, so an operator cannot set it"
    end
    assert_includes env_example, "UPGRADER_REPAIR_AGENT_VERSION=",
      "the agent version is not settable from the environment"
  end

  # **A step on an old application executes in an era container, so the deployment has to
  # let this container start one.** The socket is the trust decision the compose file states
  # in its own comment; the runtime setting is what makes the machine explicit, because a
  # loop that fell back to "whatever Ruby this image has" would report healthy and complete
  # no step of a 2013 application. Four facts, and each fails silently on its own: the
  # setting, the mount, the group that may use the socket, and the *client binary* — a
  # mounted socket is useless to an image with no `docker` to speak through it, and
  # `Machine::Container` shells out rather than speaking to the daemon itself.
  def test_the_walker_may_start_the_era_containers_it_executes_on
    block = config("upgrader")

    assert_includes block, "UPGRADER_RUNTIME:", "the service does not choose a machine"
    assert_match(/UPGRADER_RUNTIME:\s*\$\{UPGRADER_RUNTIME:-docker\}/, block,
      "the deployment's default machine is not the era containers")
    assert_includes block, "/var/run/docker.sock:/var/run/docker.sock",
      "the walker cannot start the containers it executes steps on"
    assert_match(/group_add:\s*\n\s+-\s*"\$\{UPGRADER_DOCKER_GID/, block,
      "the socket is mounted without the group that may use it")
    # The fourth fact, and the one this test was written without: the deployment shipped a
    # socket, a runtime and a group, and no `docker` for the image to reach any of them with.
    # Neither half can supply the other — a mount is a fact about the deployment and a binary
    # is a fact about the image — so both are asserted.
    assert_includes block, "WITH_DOCKER_CLIENT: 1",
      "the walker's image is built without a Docker client, so it starts no era container"
    instructions = uncommented(dockerfile)
    assert_includes instructions, "ARG WITH_DOCKER_CLIENT=0",
      "the default build would carry a Docker client that only `step` needs"
    assert_match(/if \[ "\$WITH_DOCKER_CLIENT" = "1" \]/, instructions,
      "the argument is declared but nothing is installed when it is set")
    assert_includes instructions, "docker-cli",
      "the client is never installed — `docker.io` would bring the daemon this walker never starts"
    # The runtime is read from the environment (`Step::RUNTIME_ENV`), not passed as a flag: it
    # is a property of the deployment rather than of one invocation, and the entrypoint's flag
    # contract is checked by the test above. **The name is declared once**, on the machine layer
    # that the step and all three machines read — a name written in three places is a name that
    # drifts, and the step's constant is that name rather than a second copy of the string.
    assert_includes File.read(CLI_PATH.gsub("cli.rb", "machine.rb"), encoding: "utf-8"),
      'RUNTIME_ENV = "UPGRADER_RUNTIME"',
      "the runtime's name is no longer declared on the machine layer"
    assert_includes File.read(CLI_PATH.gsub("cli.rb", "step.rb"), encoding: "utf-8"),
      "RUNTIME_ENV = Machine::RUNTIME_ENV",
      "the step no longer reads the runtime the compose file sets"
  end

  def test_the_step_is_given_the_same_time_to_finish_as_the_miners
    # A step may be inside an application's test suite. The period only has to cover one
    # step's tail, because the loop checkpoints after each step and a restart resumes —
    # so it is not "long enough for a whole upgrade", it is "long enough not to kill work
    # that is about to record itself". Held equal to the miner's rather than written
    # twice: two numbers that mean "let the work finish" drift the moment one is tuned.
    assert_equal service_value("miner", "stop_grace_period"),
      service_value("upgrader", "stop_grace_period")
  end

  def test_liveness_is_a_heartbeat_the_loop_touches_and_nothing_is_installed_to_probe_it
    block = config("upgrader")

    assert_includes block, "healthcheck:"
    # The path is the image's own home, not a second copy of it: a healthcheck watching
    # a file the loop does not write reports a healthy service as dead, every interval,
    # for ever.
    assert_includes block, "#{image_env("UPGRADER_HOME")}/heartbeat",
      "the healthcheck watches a file the loop does not write"
    assert_match(/heartbeat/, block)
    # The interpreter already in the image is the client, so no curl is added to the
    # image just to ask whether a file is old.
    refute_match(/\bcurl\b|\bwget\b/, block)
    %w[interval timeout start_period retries].each do |key|
      assert_match(/^\s+#{key}:/, block, "the healthcheck sets no #{key}")
    end
  end

  def test_the_loop_is_given_the_identity_and_the_schedule_it_needs
    # The entrypoint's `serve` invocation is a contract with the CLI: every tunable the
    # compose service sets has to be one the entrypoint reads, or an operator raises it
    # in `.env` and nothing happens. (The coordinator runs the CLI's own suite for the
    # other half — that these flags exist.)
    #
    # `UPGRADER_LOG_LEVEL` used to be in this list, and its removal is the bug this file
    # should have caught: the entrypoint read it, passed it as `--log-level`, and the CLI
    # accepts no such flag — so the container refused to start. It is asserted *absent*
    # below, by the test that reads both sides of the flag contract.
    %w[API_BASE_URL UPGRADER_TO UPGRADER_REPOS UPGRADER_INTERVAL UPGRADER_STEP_TIMEOUT].each do |name|
      assert_includes config("upgrader"), "#{name}:", "the service does not set #{name}"
      # The prefix only: the entrypoint reads each name with a default (`:=` plus the
      # value that is a decision), which is what an operator relies on when they set
      # nothing at all. Asserting the closing brace would pin the default's *value*
      # here and in the entrypoint at once, and the value belongs in the entrypoint.
      assert_includes entrypoint, "${#{name}:=", "the entrypoint does not read #{name}"
    end
  end

  # The bug this exists for, and it is the log level's one rung over.
  #
  # `serve` needs a target — with none it prints "set `UPGRADER_TO`" and returns from
  # `walk` on every cycle, so it does no work — and the entrypoint never passed `--to`,
  # while `UPGRADER_TO` appeared in no file of this repository at all. The container
  # started, passed the healthcheck whose whole job is to catch a loop that is up and
  # stuck, and mined nothing; a loop between cycles looks exactly the same. It was found
  # by reading the CLI's own help text against the argv, which is what the flag test
  # above does for *spelling* and this one does for *completeness*: a flag that is
  # accepted but never supplied is the half a spelling check cannot see.
  def test_the_loop_is_told_which_release_every_move_ends_at
    assert_includes entrypoint_flags, "--to", "`serve` is never given a target"
    assert_includes entrypoint, "${UPGRADER_TO:=", "the entrypoint does not read a target"
    assert_includes config("upgrader"), "UPGRADER_TO:", "the service cannot set a target"
    assert_includes env_example, "UPGRADER_TO=", ".env.example does not name the target"
  end

  def test_every_flag_the_entrypoint_passes_is_one_the_cli_accepts
    # Both halves of the contract, because either one alone is satisfied by the bug: the
    # entrypoint passed `--log-level "${UPGRADER_LOG_LEVEL}"`, `cli.rb`'s OptionParser
    # raised `InvalidOption`, `parse` turned that into a usage error, and `serve` exited 2
    # — so a long-running service never started, while its compose block, its healthcheck,
    # its `start_period: 15m` and the rest of this suite all described a working loop.
    # Reading the flags off the script and the accepted ones off the CLI is the check that
    # would have caught it, and the reason a flag is only a contract when both sides are
    # read rather than when each is read alone.
    flags = entrypoint_flags
    refute_empty flags, "the entrypoint passes no flags at all"
    assert_includes flags, "--interval"
    assert_includes flags, "--step-timeout"
    flags.each do |flag|
      assert_includes cli, flag, "#{flag} is passed to the CLI, which does not accept it"
    end
    # And the specific knob that was removed rather than implemented: this image has no
    # logging framework, so there is no level for a flag to filter. Read from the
    # *uncommented* text, because both files now carry a comment quoting the variable that
    # caused this — which is the reason this file slices comments off everything it reads.
    refute_includes flags, "--log-level"
    refute_includes uncommented(entrypoint), "UPGRADER_LOG_LEVEL"
    refute_includes config("upgrader"), "UPGRADER_LOG_LEVEL"
  end

  def test_the_client_gets_an_operators_key_and_never_the_admin_token
    block = config("upgrader")

    # The Ruby client reads `Corpus::ENV_KEY` and nothing else — named in one file, so a
    # deployment that set a differently spelled variable would hand it an empty string and
    # no error. Both halves are asserted: the name the client reads, and the operator's own
    # setting name it is translated from, the same shape as `API_BASE_URL` above.
    assert_includes block, "AGENTS_FYI_KEY:"
    assert_includes block, "${UPGRADER_API_KEY:-"

    # And the credential it must never be handed, however convenient it would look: the
    # admin token is the moderation surface — hide, unhide, disable, mark-live — and this
    # container clones and executes other people's applications. A client's key can file a
    # report; the whole of this container's bar is filing one.
    refute_includes block, "ADMIN_TOKEN"
    refute_includes block, "API_KEY_PEPPER"
  end

  def test_the_env_example_documents_what_the_service_sets_and_no_log_level
    documented = env_example

    assert_includes documented, "UPGRADER_REPOS=", ".env.example does not name the loop's list"
    assert_includes documented, "UPGRADER_API_BASE_URL="
    assert_includes documented, "UPGRADER_API_KEY=", ".env.example does not name the client's key"
    assert_includes documented, "UPGRADER_INTERVAL="
    assert_includes documented, "UPGRADER_STEP_TIMEOUT="
    refute_includes documented, "UPGRADER_LOG_LEVEL"

    # And nothing there is named that the service does not set: an operator who sets a
    # knob that nothing reads has been handed dead configuration, which is the shape the
    # API's own configuration test reads this file for — so the two suites would otherwise
    # disagree about what this file may name.
    set = config("upgrader").scan(/^\s+(UPGRADER_[A-Z_]+):/).flatten.uniq
    refute_empty set, "the service sets no UPGRADER_ variable at all"
    set.each do |name|
      assert_includes documented, "#{name}=", "the service sets #{name} and .env.example omits it"
    end
  end

  def test_every_volume_the_upgrader_mounts_is_declared
    declared = compose[/^volumes:\n(.*)\z/m, 1]
    refute_nil declared, "the compose file declares no volumes"

    %w[upgrader_cache upgrader_gems].each do |name|
      assert_match(/^  #{name}:/, declared, "#{name} is mounted but not declared")
    end
  end

  def test_the_image_owns_the_directories_those_volumes_are_mounted_over
    # The trap this image already documents for its other volumes: a named volume mounted
    # where the image has no directory is created owned by root, and this account could
    # not write to it — a gem cache that is silently unused, or a ledger that cannot be
    # written, which is a service that settles nothing and re-derives every step on every
    # restart.
    created = uncommented(dockerfile).match(/mkdir -p (.*?)&&/m)
    refute_nil created, "the image creates no directories for its volumes"
    %w[agents-fyi-upgrader .gem].each do |fragment|
      assert_includes created[1], fragment, "the image does not create the #{fragment} directory"
    end
  end

  def test_the_image_sends_gem_and_bundle_scratch_to_a_volume_rather_than_to_ram
    # `/tmp` in this container is a tmpfs, and a bundle is hundreds of gems unpacked into
    # `TMPDIR`. The miner measured what that costs: 4.1 GB of RAM in thirty-five minutes,
    # installs failing with an *empty* message, and the process dying mid-cycle without
    # running its SIGTERM handler. So the scratch directory is set in the image, where it
    # applies to the runtime as well as the build, and the compose service keeps a small
    # bounded tmpfs for whatever ignores it.
    home = image_env("UPGRADER_HOME")
    assert_equal "#{home}/tmp", image_env("TMPDIR")
    assert_includes image_env("BUNDLE_USER_HOME"), home

    block = config("upgrader")
    assert_match(/tmpfs:/, block)
    assert_match(%r{/tmp:size=\d+[mg]}, block, "the tmpfs is unbounded")
  end
end
