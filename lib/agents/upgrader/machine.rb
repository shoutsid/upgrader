# frozen_string_literal: true

require "fileutils"
require "open3"
require "socket"
require "timeout"

module Agents
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
      # keeps `/agents` the same directory on both sides of the boundary.
      CONTAINER_ROOT = "/agents"

      # What keeps a container alive between commands. BusyBox and GNU both accept
      # `sleep infinity`; `tail -f /dev/null` is the alternative and it reads as a trick.
      KEEPALIVE = %w[sleep infinity].freeze

      # The label every container this tool starts carries, and the pid of the process that owns
      # it. A container outlives a walker that was *killed* rather than ended (see `reap!`), so
      # the owner is written onto it where the next run — or an operator — can read it. **A step
      # container and a services container are reaped by the same rule**, which is why the labels
      # live here rather than on one of the two.
      LABEL = "org.agents.upgrader.step"
      PID_LABEL = "org.agents.upgrader.pid"

      # The names this tool gives its containers. Both are reaped when the process that owns
      # them is gone; the pattern is what `reap!` filters on.
      NAME_PREFIX = "agents-"
      NAME_PATTERN = "name=^agents-(step|svc)-"

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

      # Which machine a step executes on: `docker` (the era's container), `rvm` (the host's
      # interpreter for the era), or anything else — including nothing — for this process's own
      # Ruby. Named here rather than on `Step` because the machines and the step all read it,
      # and a name written in three places is a name that drifts.
      RUNTIME_ENV = "UPGRADER_RUNTIME"

      # A path this machine cannot reach — outside the mounted home — is refused rather than
      # translated into a path that does not exist in the container and would run a command
      # somewhere nobody looked.
      class Unavailable < StandardError; end

      # **A step may not take the disk the service it talks to answers on.**
      #
      # A step is the heaviest writer on this daemon: `bundle install` unpacks a hundred gems into
      # a mounted volume and `assets:precompile` writes thousands of small files, all on the same
      # virtual disk as the deployment's PostgreSQL and its Rails process. Measured on the
      # deployment this was written for: while a 5.2 -> 6.0 rung installed and precompiled, the
      # Docker VM reported `full avg300=75%` I/O pressure — three quarters of the time every
      # runnable task was waiting on the disk — the site's own `/app/projects/:id/live` polls took
      # 50 to 495 seconds, three of them finishing in the same second the stall cleared, and
      # `docker run` itself hung at container creation. Guest memory was fine (13.4 GiB of 16
      # available) and the host disk was idle, so the only resource contended was the VM's queue.
      #
      # `--device-write-bps`/`--device-read-bps` are cgroup `io.max` throttles: they bound *this
      # container's* throughput, so the site's queries keep their latency while a rung installs,
      # and the walk simply takes longer. The device is discovered rather than configured, because
      # it differs by deployment (`/dev/vda1` in a Docker Desktop VM, `/dev/nvme0n1p2` on a host)
      # and a wrong name here would silently disable the cap.
      #
      # **Off unless a deployment names a rate.** A walk on somebody's own machine is their disk
      # and their choice; the compose file is what turns this on for a deployment that shares its
      # daemon with a served application. A cap set with no block device behind the home is stated
      # and skipped rather than failing the step: a limit that cannot be applied is not evidence
      # about the release.
      module DiskLimit
        READ_ENV = "UPGRADER_DISK_READ_BPS"
        WRITE_ENV = "UPGRADER_DISK_WRITE_BPS"

        # The mount table a device is read from, injectable so a suite states it.
        MOUNTS = "/proc/mounts"

        # The rates a deployment named, keyed by the flag they become.
        def self.from_env(env = ENV)
          { "read" => env[READ_ENV].to_s.strip, "write" => env[WRITE_ENV].to_s.strip }
            .reject { |_, rate| rate.empty? }
        end

        # The `docker run` flags, in the order the daemon takes them.
        def self.argv(home:, limits:, out: nil, mounts: MOUNTS)
          return [] if limits.nil? || limits.empty?

          device = device_for(home, mounts)
          if device.nil?
            out&.puts("  disk: no block device behind #{home}, so the I/O cap is not applied")
            return []
          end

          limits.flat_map { |kind, rate| ["--device-#{kind}-bps", "#{device}:#{rate}"] }
        end

        # The innermost block device the home is on: the longest mount target that is a prefix
        # of it. A path matched by no `/dev/` mount is nil rather than a guess at the root.
        def self.device_for(home, mounts = MOUNTS)
          home = File.expand_path(home.to_s)
          best = nil
          File.foreach(mounts) do |line|
            source, target = line.split(" ", 3)
            next if source.nil? || target.nil? || !source.start_with?("/dev/")
            next unless under?(home, target)

            best = [target.length, source] if best.nil? || target.length > best.first
          end
          best&.last
        rescue SystemCallError
          nil
        end

        def self.under?(path, target)
          return true if target == "/"

          path == target || path.start_with?("#{target}/")
        end
      end

      # **Every call this tool makes to the daemon is bounded.** A `docker` CLI call blocks while the
      # daemon's containerd snapshot and task path is held, and it does not fail, it waits — so an
      # unbounded one is not a slow step, it is a walk that stops. Measured on this deployment three
      # times in one afternoon, each time with every *metadata* call (`ps`, `version`, `images`, `df`)
      # still answering in milliseconds: `docker rm --force` after a passed rung (its run recorded, the
      # publish behind the `ensure` never run), `docker run` twice before an era container existed (two
      # rungs sat at their preflight line), and `docker rm -f` on the container that started it (still
      # `Up` twenty-two minutes later). The wedge is containerd's rather than this tool's — `docker
      # create` hung for `alpine` with no mount, and the engine restart that cleared it took 25 seconds
      # — so what this constant buys is that the next one costs a deadline instead of the walk.
      DOCKER_SECONDS = 300

      # A teardown is a different bet: nothing waits on the container afterwards, so it gets the short
      # bound and is abandoned to `--rm` and `reap!` rather than the long one.
      TEARDOWN_SECONDS = 15

      # One daemon call, bounded, keeping the shape its callers already read: output and status, with
      # empty output when the daemon would not answer. Empty is what each caller already handles — a
      # missing digest falls back to the image tag, a missing volume to the operator's own name, a
      # missing container id to `Unavailable` — so a deadline reads as "the daemon did not say", which
      # is the true answer.
      def self.docker(inspector, *argv, seconds: DOCKER_SECONDS)
        Timeout.timeout(seconds) { inspector.capture2e(*argv) }
      rescue Timeout::Error
        ["", nil]
      end

      # A host path as a container that has the walker's home mounted at `CONTAINER_ROOT` sees
      # it, or a refusal. One function because two machines mount the home — the step's own
      # container and the services container — and a path translated two different ways is a
      # command that runs in a directory nobody looked at.
      def self.translate(path, home)
        full = File.expand_path(path)
        unless full == home || full.start_with?("#{home}/")
          raise Unavailable,
            "#{path} is outside this step's home (#{home}), which is the only directory " \
            "mounted into its interpreter container"
        end

        "#{CONTAINER_ROOT}#{full.delete_prefix(home)}"
      end

      # The container a step executes on.
      class Container
        attr_reader :entry, :home, :container_id

        def initialize(entry:, home:, out: nil, runner: Shell, uid: Process.uid, gid: Process.gid,
                       name: nil, run_id: nil, inspector: Open3, volume: nil,
                       self_marker: SELF_MARKER, disk_limits: nil, mounts: DiskLimit::MOUNTS)
          @entry = entry
          @home = File.expand_path(home)
          # nil asks the environment; a hash (including an empty one, which disables the cap) is
          # what the caller said — the same rule `volume:` follows, and for the same reason: a
          # test that pinned nothing would pass or fail with the developer's own environment.
          @disk_limits = disk_limits.nil? ? DiskLimit.from_env : disk_limits
          @mounts = mounts
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
          @name = name || "agents-step-#{run_id || Process.pid}-#{entry.name.tr(".", "-")}"
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
          # `/agents/home` and `/agents/tmp` for the *named volume* case, where
          # Docker seeds an empty volume from the image; a bind mount shadows all of that,
          # so `HOME` and `TMPDIR` named directories that did not exist and the first real
          # application answered `bundle install` with \"`/agents/home` is not a
          # directory\" — a failure that reads as the application's.
          FileUtils.mkdir_p([File.join(@home, "home"), File.join(@home, "tmp")])
          # What a killed predecessor left running, before this one adds to the stack.
          self.class.reap!(out: @out, inspector: @inspector)
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

        # The container is started with `--rm` and its keepalive is killed here, so it removes itself;
        # this call is the belt to that braces, which is what makes abandoning it at
        # `TEARDOWN_SECONDS` safe — `reap!` sweeps whatever a dead owner left before the next step.

        # **This runs from an `ensure`, so it never raises.** A cleanup that failed loudly
        # would replace the step's own outcome with its own, and the leak it would be
        # reporting is exactly what `reap!` removes on the next start.
        def stop!
          return if @container_id.to_s.empty?

          # Through the runner rather than the inspector: `Shell.run` is the one place that bounds a
          # child and kills its process group, and this is the call where an unbounded wait is fatal to
          # the *step*, not merely slow.
          @runner.run(["docker", "rm", "--force", @container_id], stage: "teardown",
            chdir: @home, timeout: TEARDOWN_SECONDS)
          @container_id = nil
        rescue StandardError
          @container_id = nil
        end

        # The name this class gives a container, and the pid inside it: `run_id` is
        # `<timestamp>-<pid>` (`Step#run_id`), so a name states its owner even for a container
        # started before the labels existed.
        NAME = /\Aagents-step-\d{14}-(\d+)-/

        # **Remove the containers a walker that was killed rather than ended left behind.**
        #
        # `--rm` removes a container when its own process exits, and this container's process
        # is a keepalive that never exits: it is removed when the walker says so. A `SIGKILL`,
        # a crash or a closed terminal says nothing — so the container keeps running with its
        # Postgres, its Redis and its memory, and eight of them had accumulated here over one
        # afternoon before anybody looked at `docker ps`.
        #
        # Every container therefore carries the pid of the process that owns it, in a label and
        # (through the run id) in its name, and this removes the ones whose owner is gone.
        # **A live owner is never touched**: a container whose pid is still running is a step
        # in flight, possibly somebody else's, and the check errs that way deliberately — a pid
        # reused by an unrelated process keeps a stale container rather than removing a live
        # one. `step` and `serve` call this before starting a container of their own, and
        # `prune` is the same pass for an operator.
        def self.reap!(out: nil, inspector: Open3)
          removed = []
          list(inspector).each do |id, name, pid|
            owner = pid.to_s.strip.empty? ? name.to_s[NAME, 1] : pid
            next if owner.to_s.empty? || Processes.alive?(owner)

            Machine.docker(inspector, "docker", "rm", "--force", id, seconds: TEARDOWN_SECONDS)
            removed << id
          end
          out&.puts("  reaped #{removed.size} step container(s) whose process was gone") if removed.any?
          removed
        end

        # The containers this tool has started, as `[id, name, owner pid]`. The name filter is
        # the primary one because it also finds a container from before the labels existed; the
        # label is read for the ones that carry it.
        def self.list(inspector)
          format = "{{.ID}}\t{{.Names}}\t{{.Label \"#{PID_LABEL}\"}}"
          listing, _status = Machine.docker(inspector,
            "docker", "ps", "-a", "--filter", NAME_PATTERN, "--format", format
          )
          listing.to_s.lines.filter_map do |line|
            id, name, pid = line.split("\t", 3).map(&:strip)
            next if id.to_s.empty? || name.to_s.empty?

            [id, name, pid]
          end
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

        # **One command as root, and only one kind of command: apt.** An era image installs its
        # packages as root at build time, and a step later needs a package the application's own
        # build declared (`Record::PACKAGES`). The alternative — baking every application's native
        # headers into every era image — is a list that grows per repository and still misses the
        # next one. Everything else a step runs stays on the walker's uid, because a package
        # manager is the only command here that must write outside the working copy.
        def root_command(argv, chdir:, env: {})
          [exec_argv(argv, chdir: chdir, env: env, user: "0:0"), {}]
        end

        def interpreter = "ruby #{entry.ruby}"

        # **A database the application names only by URL.** `services.sh` reads a keyed
        # `database.yml` to decide whether to start PostgreSQL; a Heroku-style file whose test
        # section is `url: <%= ENV["DATABASE_URL"] %>` names no adapter at all, so the script
        # started nothing and the application died on `nil` before its first command. Measured
        # on `limestone` at the 6.1 patch rung. The URL names the role and database the script
        # creates; an application with a keyed file ignores it.
        def database_url = "postgres://app@127.0.0.1:#{PG_PORT}/app"

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

        # **Where a browser's driver is seeded, named the way the application's suite reads it.**
        # `webdrivers` asks `WD_INSTALL_DIR` where its cache is, and the step points the suite at
        # this directory; the driver Debian installs beside the browser is linked into it at the
        # start of the step (`Step#prepare_browser`). It is under the container's home, which is
        # the mounted volume, so the seed is written once per step rather than downloaded per
        # run — and the application's own tree is not part of the answer.
        #
        # **One directory per era, because the volume is shared and the driver is the image's.**
        # A walk serves several repositories at once, so a 2.7 step and a 3.3 step can seed at the
        # same moment; one directory would leave the later one's `.version` beside the earlier one's
        # binary, which reads to the gem as "a working driver" and starts the wrong browser's driver.
        def browser_cache = "#{CONTAINER_HOME}/browser/#{era}/webdrivers"

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

          out, _status = Machine.docker(@inspector, "docker", "image", "inspect", "-f", "{{.Id}}", entry.image)
          text = out.to_s.strip
          @digest = DIGEST.match?(text) ? text : ""
        rescue Errno::ENOENT
          @digest = ""
        end

        # A host path, as the container sees it. Anything outside the mounted home is refused:
        # the container has no view of the rest of the machine, and a command sent to a path
        # that does not exist there would run in whatever directory it did find.
        def translate(path) = Machine.translate(path, @home)

        private

        def start_argv
          ["docker", "run", "-d", "--rm", "--name", @name,
           "--label", "#{LABEL}=#{@name}",
           "--label", "#{PID_LABEL}=#{Process.pid}",
           *DiskLimit.argv(home: @home, limits: @disk_limits, mounts: @mounts, out: @out),
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
           # `agents-start` needs; the application never runs as root, because every
           # command is exec'd with `--user`.
           "-e", "AGENTS_UID=#{@uid}",
           "-e", "AGENTS_GID=#{@gid}",
           "-w", translate(@home),
           entry.image, "agents-start", *KEEPALIVE]
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
          out, _status = Machine.docker(@inspector, "docker", "inspect", "-f", template, Socket.gethostname)
          @self_volume = out.to_s.strip
        rescue StandardError
          @self_volume = ""
        end

        def version_argv
          ["docker", "exec", "--workdir", CONTAINER_ROOT, @container_id, "ruby", "-v"]
        end

        # **`-i` is what makes stdin reach the container's process**, and a walk is the reason it is here:
        # without it `docker exec` leaves the process with no stdin at all, so `app:update`'s
        # `Overwrite config/boot.rb?` read nothing, asked again, and repeated the question until the command
        # bound killed it — with the answer pipe the walker had just started giving it sitting unread on the
        # host side. Every other command is unaffected (they are handed `File::NULL`), and `-t` is
        # deliberately absent: a tty would make a generator decorate its output and would make a killed
        # process leave the terminal in a strange state.
        def exec_argv(argv, chdir:, env:, user: "#{@uid}:#{@gid}")
          workdir = translate(chdir)
          flags = env.flat_map { |name, value| ["-e", "#{name}=#{translate_value(value)}"] }
          ["docker", "exec", "--interactive", "--user", user, "--workdir", workdir, *flags,
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

      # The ports the application's own configuration expects when it names none. **The services
      # script is not named here**: it is the stack's (the era images ship it, and the pack says
      # which command it is), so a native machine is told which command to route to the services
      # container rather than recognising one name (see `docs/design-notes.md`).
      PG_PORT = 5432
      REDIS_PORT = 6379

      # **The application on the host, through the era's own Ruby** (`UPGRADER_RUNTIME=rvm`).
      #
      # No container is started for the application, which was the slowest thing a walk did —
      # twenty seconds healthy, ninety when the daemon degraded, paid once per interpreter
      # candidate — and the interpreter is the *era's*, resolved through rvm rather than being
      # whatever Ruby happens to be first on the path.
      #
      # rvm's **wrappers** are the seam: `~/.rvm/wrappers/<ruby>@<gemset>/bundle` is a real
      # executable that sets `GEM_HOME`, `GEM_PATH` and the interpreter before exec'ing, so a
      # command here is an argv with one bin directory in front of `PATH` — the same shape
      # `Machine::Container` produces with `docker exec`. The gemset is the walker's own, so a
      # walk cannot disturb what a developer installed for their own work.
      #
      # **What this machine has no equivalent of is an image digest, and the difference is
      # real.** A container's identity is its image's content id, which is what makes a
      # rebuilt era a *different* machine to the ledger; a host interpreter's identity is its
      # version, its gemset and its bundler, and a gem or a system library that changed under
      # those same versions is not noticed. The stamp says exactly that much and no more.
      #
      # Services are a **sibling container with published ports** (`Services`), because an
      # application running on the host reaches `localhost` — which is what a 2013
      # `database.yml` says, and the reason the container machine keeps them inside itself.
      class Host
        # rvm's own directory, and the gemset this tool keeps its eras in: a walk that installed
        # its gems into the developer's default gemset would be a walk that changed the machine
        # it was run on.
        RVM_ENV = "UPGRADER_RVM_ROOT"
        GEMSET_ENV = "UPGRADER_RVM_GEMSET"
        DEFAULT_GEMSET = "agents-upgrader"

        attr_reader :entry, :home

        def initialize(entry:, home:, services:, out: nil, runner: Shell, rvm_root: nil,
                       gemset: nil, services_command: nil)
          @entry = entry
          @home = File.expand_path(home)
          @services = services
          @services_command = services_command.to_s
          @out = out
          @runner = runner
          @rvm_root = rvm_root.to_s.strip
          @rvm_root = File.expand_path("~/.rvm") if @rvm_root.empty?
          @gemset = gemset.to_s.strip
          @gemset = DEFAULT_GEMSET if @gemset.empty?
          @unavailable = nil
        end

        # The rvm name of the era's interpreter — what `rvm install <version>` produces, which
        # the matrix may override for a deployment that names it differently.
        def rvm_name = entry.rvm.to_s.empty? ? "ruby-#{entry.ruby}" : entry.rvm.to_s

        # Where the era's commands live: rvm's wrapper directory for this gemset.
        def wrapper = File.join(@rvm_root, "wrappers", "#{rvm_name}@#{@gemset}")

        def installed? = File.executable?(File.join(wrapper, "ruby"))

        # The interpreter, then the services it will talk to. Both are refused by name when they
        # are not there, because "no interpreter could install the bundle" is the wrong sentence
        # for a host that has not been set up.
        def start!(stage:, stages:)
          unless installed?
            @unavailable = "the era's interpreter is not installed on this host: " \
                           "#{wrapper}/ruby does not exist — `scripts/upgrader-rubies.sh " \
                           "install #{entry.name}` installs it (rvm install #{entry.ruby}, " \
                           "gemset #{@gemset}), or run this step with #{RUNTIME_ENV}=docker"
            return false
          end
          unless @services.ensure!(entry, stage: stage, stages: stages)
            @unavailable = @services.unavailable
            return false
          end

          verified = @runner.run([File.join(wrapper, "ruby"), "-v"], stage: stage, chdir: @home)
          stages << verified
          unless verified.ok?
            @unavailable = "the era's interpreter could not be asked: " \
                           "#{Record.first_line(verified.output_tail)}"
            return false
          end
          unless verified.output_tail.to_s.include?("ruby #{entry.ruby}")
            @unavailable = "the host's rvm answers #{Record.first_line(verified.output_tail)} and " \
                           "the matrix calls it ruby #{entry.ruby}; the matrix and the host disagree"
            return false
          end

          true
        end

        # Why the last `start!` failed, in one sentence.
        attr_reader :unavailable

        # Nothing to stop: the interpreter is the host's, and the services belong to the *walk*
        # rather than to a step (`Services#stop!` is the caller's, at the end of the walk).
        def stop! = nil

        # Whether a command is the stack's services script, which runs where the services are
        # rather than where the application is.
        def routed_to_services?(command)
          !@services_command.empty? && command.to_s.strip == @services_command
        end

        def command(argv, chdir:, env: {})
          return @services.command(argv, chdir: chdir) if routed_to_services?(argv.first)

          [argv, command_env(env)]
        end

        # A command line the application stated (`bundle exec rspec`): a shell, because
        # splitting it here would be guessing at its quoting. The one name that is not the
        # application's is the services script, which runs where the services are.
        def script(command, chdir:, env: {})
          return @services.command(["sh", "-lc", command.to_s], chdir: chdir) if
            routed_to_services?(command)

          [["sh", "-lc", command.to_s], command_env(env)]
        end

        def interpreter = "ruby #{entry.ruby}"
        def ruby_version = entry.ruby
        def era = entry.name
        # The sibling container publishes the port the host connects to, and the URL-only
        # configuration has to name that port rather than the container's own 5432.
        def database_url = "postgres://app@127.0.0.1:#{@services.pg_port}/app"
        # The record's `image` field for a machine that has none: where the interpreter came
        # from, which is the closest honest analogue of an image reference.
        def image = "rvm #{rvm_name}@#{@gemset}"
        def services? = true

        def stamp
          "#{interpreter} (rvm #{rvm_name}@#{@gemset}, bundler #{entry.bundler})"
        end

        private

        # What every command of the application's runs under: where the services answer, the
        # caller's own environment (the bundle path, the suite's secrets), and the era's bin
        # directory in front of `PATH` — which is what makes `bin/rails`'s shebang resolve to
        # the era's Ruby rather than to this process's.
        def command_env(env)
          @services.env.merge(env).merge("PATH" => "#{wrapper}:#{ENV["PATH"]}")
        end
      end

      # **The services a host-run application talks to, in one container for the whole walk.**
      #
      # The container machine starts PostgreSQL and Redis *inside* the step's own container,
      # and its comment gives the reason: a 2013 `database.yml` says `host: localhost`, and a
      # service on a Docker network is not localhost. With the application on the host, a
      # *published port* is localhost — so the services can be a sibling container that outlives
      # the step, which is the whole point of this class: a container per step, and per
      # interpreter candidate, was the slowest thing a walk did.
      #
      # It is the **era's image**, because an old application's suite may need that era's
      # PostgreSQL, and it is replaced when a step's era changes rather than restarted per step.
      # The application's own ports are used when they are free; when they are not, a free port
      # is chosen and `PGHOST`/`PGPORT` carry it — libpq honours those when the `database.yml`
      # names no host or port, so the application's configuration still needs no edit, and the
      # record says which port answered.
      class Services
        attr_reader :pg_port, :redis_port, :container_id, :name

        def initialize(home:, run_id: nil, out: nil, runner: Shell, pg_port: nil, redis_port: nil,
                       uid: Process.uid, gid: Process.gid, volume: nil, self_marker: SELF_MARKER,
                       name: nil, inspector: Open3, disk_limits: nil, mounts: DiskLimit::MOUNTS)
          @home = File.expand_path(home)
          @disk_limits = disk_limits.nil? ? DiskLimit.from_env : disk_limits
          @mounts = mounts
          @out = out
          @runner = runner
          @uid = uid
          @gid = gid
          @inspector = inspector
          # nil asks the environment; anything else, including "", is what the caller said.
          @volume = (volume.nil? ? ENV[VOLUME_ENV] : volume).to_s.strip
          @self_marker = self_marker
          @name = name || "agents-svc-#{run_id || Process.pid}"
          @pg_port = pg_port || free_port(PG_PORT)
          @redis_port = redis_port || free_port(REDIS_PORT)
          @container_id = nil
          @entry = nil
          @unavailable = nil
        end

        # The services for this era, running. A step on a *different* era replaces the container
        # rather than adding one, because the application's `localhost:5432` can only be one
        # thing at a time — and the era's PostgreSQL is what an old suite needs.
        def ensure!(entry, stage:, stages:)
          return true if !@container_id.nil? && @entry&.name == entry.name

          stop!
          started = @runner.run(start_argv(entry), stage: stage, chdir: @home)
          stages << started
          unless started.ok?
            @unavailable = "the services container would not start: " \
                           "#{Record.first_line(started.output_tail)}"
            return false
          end

          @container_id = started.output_tail.to_s.strip.lines.last.to_s.strip
          @entry = entry
          @out&.puts("  services: #{entry.image} on 127.0.0.1:#{@pg_port} (postgres), " \
                     "127.0.0.1:#{@redis_port} (redis)") if @out
          true
        end

        attr_reader :unavailable

        # What the application's commands read to find them. `PGHOST` is set even when the
        # `database.yml` names no host: libpq's default is the Unix socket, and a socket inside
        # a container is not one the host can open.
        def env
          {
            "PGHOST" => "127.0.0.1",
            "PGPORT" => @pg_port.to_s,
            "REDIS_URL" => "redis://127.0.0.1:#{@redis_port}"
          }
        end

        # A command inside the services container — the script that starts them, with the
        # application's directory as the working directory, because that is where it reads the
        # `database.yml` whose roles and databases it creates.
        # `--interactive` for the same reason the step container's exec has it: one shape for a command
        # inside a container, and a service script that ever asks a question is not the place to find out
        # that stdin was never attached.
        def command(argv, chdir:)
          ["docker", "exec", "--interactive", "--user", "#{@uid}:#{@gid}", "--workdir",
           Machine.translate(chdir, @home), @container_id.to_s, *argv]
        end

        # Removed when the walk is over — the caller's job, and the reason a killed walker's is
        # reaped: it carries the pid of the process that owns it, like a step's container.
        def stop!
          return if @container_id.to_s.empty?

          Machine.docker(@inspector, "docker", "rm", "--force", @container_id,
            seconds: TEARDOWN_SECONDS)
          @container_id = nil
          @entry = nil
        rescue StandardError
          nil
        end

        private

        def start_argv(entry)
          ["docker", "run", "-d", "--rm", "--name", @name,
           "--label", "#{LABEL}=#{@name}",
           "--label", "#{PID_LABEL}=#{Process.pid}",
           *DiskLimit.argv(home: @home, limits: @disk_limits, mounts: @mounts, out: @out),
           "-p", "127.0.0.1:#{@pg_port}:#{PG_PORT}",
           "-p", "127.0.0.1:#{@redis_port}:#{REDIS_PORT}",
           *mount_argv,
           "-e", "HOME=#{CONTAINER_HOME}",
           "-e", "TMPDIR=#{CONTAINER_TMP}",
           "-e", "LANG=C.UTF-8",
           "-e", "PGUSER=app",
           "-e", "AGENTS_UID=#{@uid}",
           "-e", "AGENTS_GID=#{@gid}",
           "-w", CONTAINER_ROOT,
           entry.image, "agents-start", *KEEPALIVE]
        end

        def mount_argv
          name = @volume.empty? ? self_volume : @volume
          return ["--mount", "type=bind,source=#{@home},target=#{CONTAINER_ROOT}"] if name.empty?

          ["--mount", "type=volume,source=#{name},target=#{CONTAINER_ROOT}"]
        end

        def self_volume
          return @self_volume unless @self_volume.nil?

          unless File.exist?(@self_marker)
            return @self_volume = ""
          end
          template = "{{range .Mounts}}{{if eq .Destination \"#{@home}\"}}{{.Name}}{{end}}{{end}}"
          out, _status = Machine.docker(@inspector, "docker", "inspect", "-f", template, Socket.gethostname)
          @self_volume = out.to_s.strip
        rescue StandardError
          @self_volume = ""
        end

        # The port the application expects, or a free one when something else on this machine
        # already has it: a developer with PostgreSQL running is not a developer who cannot walk.
        def free_port(preferred)
          TCPServer.new("127.0.0.1", preferred).close
          preferred
        rescue SystemCallError
          server = TCPServer.new("127.0.0.1", 0)
          port = server.addr[1]
          server.close
          port
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
