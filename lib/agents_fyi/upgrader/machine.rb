# frozen_string_literal: true

require "fileutils"
require "open3"
require "socket"

module AgentsFyi
  module Upgrader
    # The machine one step's application-level commands run on.
    #
    # A step installs a bundle, rewrites a pin, runs `app:update`, boots the application and
    # runs its suite — and every one of those is a fact about an interpreter, not about this
    # process. The interpreter running this tool is Ruby 3.3; an application from 2013 cannot
    # even install its bundle on it. So the application's commands are executed *elsewhere*,
    # and there are exactly two elsewheres:
    #
    # * **A container** (`Machine::Container`) — one `docker run -d … sleep infinity` per
    #   step, with each command sent in through `docker exec`. One container per *step* and
    #   not one per command, and that is the load-bearing choice: the services a Rails suite
    #   expects (Postgres, Redis) run inside it, and a per-command container would take them
    #   down between the install and the suite. It also means the application's own
    #   `database.yml` keeps working — `localhost:5432` is where the service it started
    #   listens — so the upgrade never has to edit a connection string to make a test suite
    #   run, which is a change a PR would otherwise carry for the machine's convenience
    #   rather than the application's benefit.
    # * **This process** (`Machine::Native`) — the host interpreter, for a step run by hand on
    #   a machine that has the right Ruby. It is also what makes the whole abstraction
    #   testable: a native machine's `command` is the identity, so the existing suite drives
    #   the pipeline exactly as it did before this file existed.
    #
    # **The container is a step's, and it is disposable.** It is named after the run, it is
    # removed when the step is finished with it, and nothing that matters is left inside it:
    # the worktree, the bundle and the home are all under the mounted home, and the databases
    # live in the container's own `/tmp` on purpose — an environment that survives a step is
    # an environment the next step can silently inherit evidence from, which is the trap the
    # miner's verifiers were built around.
    #
    # **The stamp is the machine's identity, and it carries the image's digest.** A verdict is
    # re-opened when the stamp no longer matches (`Ledger.settled?`), so the digest is what
    # makes a rebuilt era image a different machine rather than the same one with a
    # different build.
    module Machine
      # Where the walker's home is mounted inside the container. Paths handed to `docker` are
      # translated onto this; nothing outside the home is reachable from a step, which is what
      # keeps `/agents-fyi` the same directory on both sides of the boundary.
      CONTAINER_ROOT = "/agents-fyi"

      # What keeps a container alive between commands. BusyBox and GNU both accept
      # `sleep infinity`; `tail -f /dev/null` is the alternative and it reads as a trick.
      KEEPALIVE = %w[sleep infinity].freeze

      # The interpreter's own home inside the container, on the volume, so a gem's build
      # cache (`~/.gem`) and a bundler's user config survive between steps rather than being
      # re-derived. Scratch is a volume too: `/tmp` here is tmpfs and a bundle is hundreds of
      # gems unpacked into `TMPDIR` — the miner measured 4.1 GB of RAM in thirty-five minutes
      # from exactly that.
      CONTAINER_HOME = "#{CONTAINER_ROOT}/home".freeze
      CONTAINER_TMP = "#{CONTAINER_ROOT}/tmp".freeze

      # The named volume the walker's home lives on, when the walker itself runs in a
      # container. Discovered rather than configured: the walker asks the daemon what its own
      # home is mounted from (`docker inspect` on its own hostname) and joins the same volume
      # by name. `UPGRADER_DOCKER_VOLUME` overrides the discovery, which is the escape hatch
      # for a daemon that will not answer.
      #
      # The distinction is not cosmetic and the failure it prevents is silent: from inside a
      # container, `--mount source=<home>` names a path on the *host* that the daemon will
      # create as an empty directory, so the era container would start with a working copy
      # that does not exist and every install would fail with "Could not locate Gemfile" —
      # a failure that looks like the application's fault.
      VOLUME_ENV = "UPGRADER_DOCKER_VOLUME"

      # How a containerised process knows it is one. Docker creates this file for every
      # container; a false negative falls back to the bind mount, which is what a host run
      # wants anyway.
      SELF_MARKER = "/.dockerenv"

      # How long a `docker version` probe may take before this machine is declared absent.
      DOCKER_PROBE_SECONDS = 5

      # A path this machine cannot reach — outside the mounted home — is refused rather than
      # translated into a path that does not exist in the container and would run a command
      # somewhere nobody looked.
      class Unavailable < StandardError; end

      # The container a step executes on.
      class Container
        attr_reader :entry, :home, :container_id

        def initialize(entry:, home:, out: nil, runner: Shell, uid: Process.uid, gid: Process.gid,
                       name: nil, run_id: nil, inspector: Open3, volume: nil,
                       self_marker: SELF_MARKER)
          @entry = entry
          @home = File.expand_path(home)
          @out = out
          @runner = runner
          @uid = uid
          @gid = gid
          @inspector = inspector
          # nil asks the environment; anything else, including "", is what the caller said —
          # a test that pinned nothing would otherwise pass or fail with the developer's own
          # `UPGRADER_DOCKER_VOLUME`.
          @volume = (volume.nil? ? ENV[VOLUME_ENV] : volume).to_s.strip
          @self_marker = self_marker
          # Named after the run so two loops stepping two repositories at once cannot collide
          # on a container name, and so an operator reading `docker ps` sees which step owns
          # a container that outlived its process.
          @name = name || "agentsfyi-step-#{run_id || Process.pid}-#{entry.name.tr(".", "-")}"
          @container_id = nil
        end

        # Start the container and prove it is the interpreter it claims to be.
        #
        # Two commands, both recorded: the `docker run` that started it, and a `ruby -v`
        # inside it — because the matrix's version is compared against a step's Ruby floor,
        # and a matrix that drifted from its image would pick an interpreter that cannot run
        # the step it was chosen for. A mismatch fails the candidate rather than adjusting the
        # matrix at runtime: the fix is a corrected matrix, not a silent upgrade of the
        # interpreter a verdict is about to be stamped with.
        def start!(stage:, stages:)
          # **The mounted home has to hold the directories the container's own environment
          # points at, and on a bind mount nothing creates them.** The image creates
          # `/agents-fyi/home` and `/agents-fyi/tmp` for the *named volume* case, where
          # Docker seeds an empty volume from the image; a bind mount shadows all of that,
          # so `HOME` and `TMPDIR` named directories that did not exist and the first real
          # application answered `bundle install` with \"`/agents-fyi/home` is not a
          # directory\" — a failure that reads as the application's.
          FileUtils.mkdir_p([File.join(@home, "home"), File.join(@home, "tmp")])
          pulled = @runner.run(start_argv, stage: stage, chdir: @home)
          stages << pulled
          unless pulled.ok?
            @unavailable = "`#{pulled.command}` exited #{pulled.exit_code}: " \
                           "#{Record.first_line(pulled.output_tail)}"
            return false
          end

          @container_id = pulled.output_tail.to_s.strip.lines.last.to_s.strip
          verified = @runner.run(version_argv, stage: stage, chdir: @home)
          stages << verified
          unless verified.ok?
            @unavailable = "the container started but its interpreter could not be asked: " \
                           "#{Record.first_line(verified.output_tail)}"
            return false
          end
          unless verified.output_tail.to_s.include?("ruby #{entry.ruby}")
            @unavailable = "the image runs #{Record.first_line(verified.output_tail)} and the " \
                           "matrix calls it ruby #{entry.ruby}; the matrix and its images disagree"
            return false
          end

          true
        end

        # Why the last `start!` failed, in one sentence.
        attr_reader :unavailable

        def stop!
          return if @container_id.to_s.empty?

          _out, _err, _status = Open3.capture3("docker", "rm", "--force", @container_id)
          @container_id = nil
        rescue Errno::ENOENT
          nil
        end

        # [argv, process_env] for Shell, and for anything else that spawns its own child:
        # a command inside the container, with the environment handed over as `-e` flags
        # rather than inherited — the walker's environment names paths on the host.
        def command(argv, chdir:, env: {})
          [exec_argv(argv, chdir: chdir, env: env), {}]
        end

        # The same, for a command line that needs a shell inside the container (`bundle exec
        # rspec` is a string the application stated, and splitting it here would be guessing
        # at its quoting).
        def script(command, chdir:, env: {})
          [exec_argv(["sh", "-lc", command.to_s], chdir: chdir, env: env), {}]
        end

        def interpreter = "ruby #{entry.ruby}"

        # The interpreter's own version, for the routing question ("can these gems run on
        # the Ruby this step executes on?") which is asked of the machine rather than of the
        # process.
        def ruby_version = entry.ruby

        # The era this container is, by the matrix's own name ("2.2"), which is what a ledger
        # entry carries so the next cycle can try the same interpreter first.
        def era = entry.name

        # Whether the application's services are started inside this machine. A container
        # owns them; a native step uses whatever the host has, because starting databases on
        # somebody's laptop because they ran a step is not this tool's to do.
        def services? = true

        def image = entry.image

        # The machine's identity, for the ledger: the interpreter and the image it came from,
        # with the image's digest when the daemon will say — a rebuilt image is a new machine,
        # and a stamp that named only the tag would let yesterday's verdict stand on today's
        # bytes.
        def stamp
          found = digest
          found.empty? ? "#{interpreter} (#{entry.image})" : "#{interpreter} (#{entry.image}@#{found})"
        end

        # The image's content id, or "" when the daemon will not describe it — a missing
        # image, a dead daemon, an error message instead of an id. Matched on the whole
        # shape rather than a prefix, because the stamp it feeds is compared for equality:
        # text that merely starts with `sha256:` would become part of a machine's identity.
        DIGEST = /\Asha256:[0-9a-f]{64}\z/

        def digest
          return @digest unless @digest.nil?

          out, _status = @inspector.capture2e("docker", "image", "inspect", "-f", "{{.Id}}", entry.image)
          text = out.to_s.strip
          @digest = DIGEST.match?(text) ? text : ""
        rescue Errno::ENOENT
          @digest = ""
        end

        # A host path, as the container sees it. Anything outside the mounted home is refused:
        # the container has no view of the rest of the machine, and a command sent to a path
        # that does not exist there would run in whatever directory it did find.
        def translate(path)
          full = File.expand_path(path)
          unless full == @home || full.start_with?("#{@home}/")
            raise Unavailable,
              "#{path} is outside this step's home (#{@home}), which is the only directory " \
              "mounted into its interpreter container"
          end

          "#{CONTAINER_ROOT}#{full.delete_prefix(@home)}"
        end

        private

        def start_argv
          ["docker", "run", "-d", "--rm", "--name", @name,
           *mount_argv,
           "-e", "HOME=#{CONTAINER_HOME}",
           "-e", "TMPDIR=#{CONTAINER_TMP}",
           "-e", "LANG=C.UTF-8",
           # The default role libpq reaches for when a `database.yml` names no user. The
           # services script creates it; naming it here means an application that relied on
           # its operating-system user gets a role rather than a connection error.
           "-e", "PGUSER=app",
           # Who every `docker exec` runs as, and therefore who owns what a step creates.
           # The container's own process stays root so it can create the passwd entry
           # `agents-fyi-start` needs; the application never runs as root, because every
           # command is exec'd with `--user`.
           "-e", "AGENTS_FYI_UID=#{@uid}",
           "-e", "AGENTS_FYI_GID=#{@gid}",
           "-w", translate(@home),
           entry.image, "agents-fyi-start", *KEEPALIVE]
        end

        # The walker's home, as the era container sees it: the named volume when this process
        # is itself in a container, a bind mount when it runs on a host.
        def mount_argv
          name = @volume.empty? ? self_volume : @volume
          return ["--mount", "type=bind,source=#{@home},target=#{CONTAINER_ROOT}"] if name.empty?

          ["--mount", "type=volume,source=#{name},target=#{CONTAINER_ROOT}"]
        end

        # The name of the volume this process's home is mounted from, asked of the daemon
        # rather than configured: `docker inspect` on this container answers with its mounts,
        # and the one whose destination is the home names the volume the era container has to
        # join. Empty means "not in a container, or the daemon would not say", and the caller
        # falls back to a bind mount, which is right on a host and loudly wrong in a
        # container — loudly, because the era container then finds no working copy.
        def self_volume
          return @self_volume unless @self_volume.nil?

          unless File.exist?(@self_marker)
            return @self_volume = ""
          end
          template = "{{range .Mounts}}{{if eq .Destination \"#{@home}\"}}{{.Name}}{{end}}{{end}}"
          out, _status = @inspector.capture2e("docker", "inspect", "-f", template, Socket.gethostname)
          @self_volume = out.to_s.strip
        rescue StandardError
          @self_volume = ""
        end

        def version_argv
          ["docker", "exec", "--workdir", CONTAINER_ROOT, @container_id, "ruby", "-v"]
        end

        def exec_argv(argv, chdir:, env:)
          workdir = translate(chdir)
          flags = env.flat_map { |name, value| ["-e", "#{name}=#{translate_value(value)}"] }
          ["docker", "exec", "--user", "#{@uid}:#{@gid}", "--workdir", workdir, *flags,
           @container_id, *argv]
        end

        # An environment value that names a path under the walker's home, as the container
        # sees it. Values that are not paths are passed through untouched, and the check is
        # the same one `translate` makes — a value that is not under the home is not this
        # machine's to rewrite.
        def translate_value(value)
          text = value.to_s
          return text unless text == @home || text.start_with?("#{@home}/")

          translate(text)
        end
      end

      # The interpreter this process is. The identity — so a machine that *can* meet a floor
      # runs the step where it stands, which is what makes a hand-run `step` work on a laptop
      # with the right Ruby and no Docker at all.
      class Native
        def initialize(ruby: RUBY_VERSION)
          @ruby = ruby.to_s
        end

        # Nothing to start, and that is a statement rather than a shortcut: this machine is
        # the process, and if it is running the step at all then it exists.
        def start!(stage:, stages:) = true

        # Nor is there anything to stop. A step run natively leaves nothing behind that this
        # tool owns.
        def stop! = nil

        def command(argv, chdir:, env: {}) = [argv, env]

        def script(command, chdir:, env: {}) = [[command.to_s], env]

        def interpreter = "ruby #{@ruby}"

        def ruby_version = @ruby

        # Its own services are the host's, and this tool does not start them.
        def services? = false

        def era = nil

        def image = ENV["UPGRADER_IMAGE"].to_s

        def stamp
          image.empty? ? interpreter : "#{interpreter} (#{image})"
        end
      end
    end
  end
end
