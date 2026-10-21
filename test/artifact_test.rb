# frozen_string_literal: true

require "minitest/autorun"

# The client's own two artifacts: the image it builds and the entrypoint a deployment starts.
#
# The deployment half of this contract — that `docker-compose.yml` mounts the right volumes,
# passes the right build arguments and hands the container an operator's key rather than an
# admin token — lives in the service's contract suite
# (`test/contracts/upgrader/deploy_config_test.rb`), because the deployment is the service's.
# What belongs here is what the client's repository can prove alone: that the Dockerfile is
# pinned, that its optional tools are opt-in, that the entrypoint waits and passes only flags
# the CLI accepts, and that the directories the deployment mounts over exist in the image.
#
# Two of these rules are invisible at runtime and expensive to get wrong. A client that can
# reach the database has stopped being a client, and a shared *environment* directory must
# never happen between two clients that execute releases, because a gemset is evidence rather
# than an artifact. Both would ship quietly: a container configured wrongly starts perfectly
# and reports healthy. That is why this is a test and not a comment.
#
# Text is sliced by name rather than parsed, and the slicing keeps this suite on `minitest` and
# the standard library alone — the rule for everything in this repository.
class ArtifactTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DOCKERFILE_PATH = File.join(ROOT, "Dockerfile")
  ENTRYPOINT_PATH = File.join(ROOT, "entrypoint.sh")
  CLI_PATH = File.join(ROOT, "lib", "agents_fyi", "upgrader", "cli.rb")

  def dockerfile
    @dockerfile ||= File.read(DOCKERFILE_PATH, encoding: "utf-8")
  end

  def entrypoint
    @entrypoint ||= File.read(ENTRYPOINT_PATH, encoding: "utf-8")
  end

  def cli
    @cli ||= File.read(CLI_PATH, encoding: "utf-8")
  end

  # Every flag the entrypoint hands the CLI's `serve` mode, in the order it appears.
  def entrypoint_flags
    invocation = entrypoint[/^exec \/app\/bin\/agents-fyi-upgrader serve.*\z/m]
    refute_nil invocation, "the entrypoint does not exec the CLI's serve mode"
    invocation.scan(/--[a-z][a-z-]*/).uniq
  end

  # Every line that is not a comment, because these files' comments *quote* the strings that
  # must not appear. The Dockerfile's own note says "no `DB_PASSWORD` and no admin token in its
  # environment" — a check over the raw text would pass because a comment promised the right
  # thing, which is the failure mode of a test that reads prose as configuration.
  def uncommented(text)
    text.lines.reject { |line| line.lstrip.start_with?("#") }.join
  end

  # A one-line value out of the image's instructions, with the comment lines dropped. The
  # `ENV` block is a line-continuation form, so a declaration is its own line and may be
  # indented — and the first one is preceded by `ENV `, which is why the prefix is optional.
  def image_env(name)
    found = uncommented(dockerfile).match(/^\s*(?:ENV\s+)?#{Regexp.escape(name)}=(\S+)/)
    refute_nil found, "the image does not declare #{name}"
    found[1]
  end

  def test_the_image_can_be_repointed_at_another_interpreter_without_losing_its_pin
    found = uncommented(dockerfile).match(/^ARG RUBY_IMAGE=(ruby:[^\s@]+@sha256:[0-9a-f]{64})$/)
    refute_nil found, "the base image's default is not pinned by digest"

    instructions = uncommented(dockerfile)
    assert_includes instructions, "FROM ${RUBY_IMAGE}"

    # Every `FROM` either takes the argument or carries its own digest: a bare tag is a base
    # that changes under the image without anybody deciding it should.
    froms = instructions.scan(/^FROM .*$/)
    refute_empty froms
    froms.each do |line|
      assert(line.include?("${RUBY_IMAGE}") || line.include?("@sha256:"),
        "#{line.strip} is not pinned")
    end
  end

  def test_the_step_image_arguments_default_to_none_of_the_step_tools
    instructions = uncommented(dockerfile)

    # The default build is the one `docker run <image> plan …` and this suite use. A compiler,
    # a Docker client and a model client in an image that only reads a lockfile are cost and
    # attack surface nobody asked for.
    %w[WITH_BUILD_TOOLS WITH_DOCKER_CLIENT WITH_REPAIR_AGENT].each do |argument|
      assert_includes instructions, "ARG #{argument}=0",
        "#{argument} does not default to off"
      assert_match(/if \[ "\$#{argument}" = "1" \]/, instructions,
        "#{argument} is declared but nothing is installed when it is set")
    end
    assert_includes instructions, "ARG REPAIR_AGENT_VERSION=latest"

    %w[build-essential libsqlite3-dev libyaml-dev].each do |package|
      assert_includes instructions, package, "#{package} is not installed by any instruction"
    end
    assert_includes instructions, "docker-cli", "the Docker client is not installed"
    refute_includes instructions, "docker.io",
      "the daemon package is installed where only the client is needed"
    assert_includes instructions, "opencode-ai", "the repair agent is never installed"
  end

  # The waiter's probe is a Ruby program inside a shell script, and it shipped as a syntax
  # error: `exit(0 if response.is_a?(Net::HTTPSuccess) else 1)` — Ruby has no postfix `if`
  # with an `else` — so every attempt exited 1, the loop always burned its full five
  # minutes, and it then reported that an API answering `/api/health` "did not come up". The
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

  def test_the_entrypoint_waits_for_the_api_and_gives_up
    assert_includes entrypoint, "/api/health"
    assert_match(/attempt=0.*-ge 60/m, entrypoint)
    assert_includes entrypoint, "starting anyway"

    assert_includes entrypoint, "exec /app/bin/agents-fyi-upgrader serve"
    assert_includes entrypoint, "--heartbeat"
    assert_includes entrypoint, "--home"
    refute_includes entrypoint, "step --repo",
      "the entrypoint runs one mode; a step is the loop's business"

    # **`UPGRADER_REPOS` is retired.** The service's queue is the deployment's source of work; a
    # list in the entrypoint would be a second, quieter order. `--repos` stays a manual flag.
    refute_match(/\$\{UPGRADER_REPOS\}/, entrypoint,
      "the retired repository list is still read by the entrypoint")
    refute_match(/set -- "\$@" --repos/, entrypoint,
      "the entrypoint still passes the retired repository list")
    %w[UPGRADER_WALK UPGRADER_RUNGS UPGRADER_PUBLISH].each do |setting|
      assert_match(/if \[ -n "\$\{#{setting}\}" \]; then/, entrypoint,
        "#{setting} is not checked before its flag is passed")
    end
  end

  def test_every_flag_the_entrypoint_passes_is_one_the_cli_accepts
    # Both halves of the contract, because either one alone is satisfied by the bug: the
    # entrypoint passed `--log-level`, `cli.rb`'s OptionParser raised `InvalidOption`, `parse`
    # turned that into a usage error, and `serve` exited 2 — so a long-running service never
    # started, while every description of it said the loop was running.
    flags = entrypoint_flags
    refute_empty flags, "the entrypoint passes no flags at all"
    %w[--to --api --home --heartbeat --interval --step-timeout].each do |flag|
      assert_includes flags, flag, "the entrypoint does not pass #{flag}"
    end
    flags.each do |flag|
      assert_includes cli, flag, "#{flag} is passed to the CLI, which does not accept it"
    end
    # And the specific knob that was removed rather than implemented: this image has no
    # logging framework, so there is no level for a flag to filter. Read from the
    # *uncommented* text, because both files now carry a comment quoting the variable that
    # caused this.
    refute_includes flags, "--log-level"
    refute_includes uncommented(entrypoint), "UPGRADER_LOG_LEVEL"
  end

  def test_the_entrypoint_reads_and_passes_the_settings_a_deployment_sets
    %w[API_BASE_URL UPGRADER_TO UPGRADER_INTERVAL UPGRADER_STEP_TIMEOUT
       UPGRADER_RECORD UPGRADER_SUITE_ENV].each do |name|
      assert_includes entrypoint, "${#{name}:=", "the entrypoint does not read #{name}"
    end

    assert_includes entrypoint, '"${UPGRADER_HOME}/suite.env"',
      "the entrypoint does not write the suite environment into the service's home"
    assert_includes entrypoint, 'UPGRADER_SUITE_ENV_FILE="${UPGRADER_HOME}/suite.env"',
      "the entrypoint does not hand the CLI the path it just wrote"
    assert_includes entrypoint, '--record "${UPGRADER_RECORD}"',
      "the entrypoint never passes the record directory to `serve`"
    assert_includes entrypoint, '--to "${UPGRADER_TO}"',
      "`serve` is never given a target"
  end

  # **The runtime is read from the environment (`Step::RUNTIME_ENV`), not passed as a flag**:
  # it is a property of the deployment rather than of one invocation. The name is declared
  # once, on the machine layer that the step and all three machines read — a name written in
  # three places is a name that drifts, and the step's constant is that name rather than a
  # second copy of the string.
  def test_the_runtime_name_is_declared_once_and_the_step_reads_it
    machine = File.read(File.join(ROOT, "lib", "agents_fyi", "upgrader", "machine.rb"),
      encoding: "utf-8")
    step = File.read(File.join(ROOT, "lib", "agents_fyi", "upgrader", "step.rb"),
      encoding: "utf-8")

    assert_includes machine, 'RUNTIME_ENV = "UPGRADER_RUNTIME"',
      "the runtime's name is no longer declared on the machine layer"
    assert_includes step, "RUNTIME_ENV = Machine::RUNTIME_ENV",
      "the step no longer reads the runtime the deployment sets"
  end

  def test_the_image_owns_the_directories_its_volumes_are_mounted_over
    # The trap a named volume brings: mounted where the image has no directory, it is created
    # owned by root, and this account cannot write it — a gem cache that is silently unused,
    # or a ledger that cannot be written, which is a service that settles nothing and
    # re-derives every step on every restart.
    created = uncommented(dockerfile).match(/mkdir -p (.*?)&&/m)
    refute_nil created, "the image creates no directories for its volumes"
    %w[agents-fyi-upgrader .gem].each do |fragment|
      assert_includes created[1], fragment, "the image does not create the #{fragment} directory"
    end
  end

  def test_the_image_sends_gem_and_bundle_scratch_to_a_volume_rather_than_to_ram
    # `/tmp` in a service container is often a tmpfs, and a bundle is hundreds of gems unpacked
    # into `TMPDIR`. The miner measured what that costs: 4.1 GB of RAM in thirty-five minutes,
    # installs failing with an *empty* message, and the process dying mid-cycle without running
    # its SIGTERM handler. The scratch directory is set in the image, where it applies to the
    # runtime as well as the build.
    home = image_env("UPGRADER_HOME")
    assert_equal "#{home}/tmp", image_env("TMPDIR")
    assert_includes image_env("BUNDLE_USER_HOME"), home
  end
end
