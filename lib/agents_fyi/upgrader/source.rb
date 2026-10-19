# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"

module AgentsFyi
  module Upgrader
    # Where a plan reads its application from.
    #
    # A path is used where it is and never written to — the tool's whole product is a
    # reading, and a client that could touch an application is a client that has to be
    # trusted with one. A URL is cloned once into `$UPGRADER_HOME/work/<digest>` and
    # reused afterwards: a plan is asked repeatedly while a move is being worked out,
    # and re-cloning a repository per question is slower and less honest about what
    # was read.
    class Source
      class Failed < StandardError; end

      attr_reader :root, :commit, :description, :home

      def initialize(root:, commit:, description:, home:)
        @root = root
        @commit = commit
        @description = description
        @home = home
      end

      # `reference` is a local directory or a git URL. `ref` names a branch, tag or
      # commit and only applies to a URL: a local path is read at whatever state its
      # working tree is in, which is what a person looking at their own repository
      # means by asking.
      def self.resolve(reference, ref: nil, home: nil)
        if File.directory?(reference)
          where = File.expand_path(reference)
          new(root: where, commit: head_of(where), description: where, home: home)
        elsif url?(reference)
          clone(reference, ref: ref, home: home)
        else
          raise Failed, "no such directory: #{reference} (and it is not a git URL either)"
        end
      end

      def self.url?(reference)
        reference.include?("://") || reference.start_with?("git@") || reference.end_with?(".git")
      end

      def self.clone(url, ref:, home:)
        digest = Digest::SHA256.hexdigest("#{url}\n#{ref}")[0, 16]
        root = File.join(home, "work", digest)
        unless File.directory?(File.join(root, ".git"))
          FileUtils.mkdir_p(File.dirname(root))
          argv = ["git", "clone", "--depth", "1"]
          argv += ["--branch", ref] if ref
          argv += [url, root]
          run(argv, what: "clone #{url}")
        end
        new(root: root, commit: head_of(root), description: url, home: home)
      end

      # A *writable* copy of the application, for `step`, which edits one and must
      # never edit the caller's.
      #
      # Three cases, and the third is a refusal rather than a guess:
      #
      # * a **URL** is cloned shallow into a run-specific directory under `home`. A
      #   fresh copy per run, because a step leaves a tree in a state nobody wants to
      #   resume from — half a bundle, a Gemfile rewritten, `app:update`'s added files;
      # * a **local git working tree** becomes its own `git worktree`, which shares the
      #   object database and leaves the caller's tree, index and HEAD exactly as they
      #   were, so "this tool does not write to your repository" is true of the files
      #   *and* of git's own state;
      # * anything else — an export, a copy without git — is refused by name, because
      #   there is no copy here that cannot be confused with the caller's own files and
      #   inventing one is how a tool edits the tree it promised not to.
      #
      # `bundle_env` is where a step's bundles live: inside the run's own directory, under the
      # volume, so a killed step cannot leave a half-installed gemset for the next one to
      # trust. A gemset is evidence, so it is per-run rather than shared the way the gem
      # *cache* is.
      def self.worktree(reference, ref:, home:, run:, reuse: false)
        return kept(reference, ref: ref, home: home) if reuse

        root = File.join(home, "work", key_for(reference, ref), "run-#{run}")
        FileUtils.mkdir_p(File.dirname(root))

        if url?(reference)
          argv = ["git", "clone", "--depth", "1"]
          argv += ["--branch", ref] if ref
          argv += [reference, root]
          run(argv, what: "clone #{reference}")
          return new(root: root, commit: head_of(root), description: reference, home: home)
        end

        where = File.expand_path(reference)
        unless File.directory?(File.join(where, ".git")) || File.file?(File.join(where, ".git"))
          raise Failed, "#{reference} is not a git working tree, and a step needs a copy of " \
                        "your application that cannot be confused with it: pass a git URL, or " \
                        "`git init` the export you want stepped"
        end
        argv = ["git", "-C", where, "worktree", "add", "--detach", root]
        argv += [ref] if ref
        run(argv, what: "worktree add #{reference}")
        new(root: root, commit: head_of(root), description: "#{where} (worktree)", home: home)
      end

      # A working copy the *loop* owns and keeps: one per repository, not one per run.
      #
      # A step leaves the pin moved and its edits applied in the tree it measured, and a walk
      # is a sequence of steps — so a loop that threw the tree away could only ever execute
      # the first rung: the next cycle would read the same base commit again, plan the same
      # move, and find it in the ledger. It would report healthy and mine nothing for ever,
      # which is the miner's "finished and stuck look identical" shape one layer up.
      #
      # So this is a **clone**, not a `git worktree`, and that is deliberate for a local
      # path. A linked worktree shares the caller's object database, and the loop
      # *commits* what a passing step produced — which would write objects into the
      # repository this tool promises not to touch. A clone is ours: the caller's files,
      # refs and object store are all left exactly as they were. What happens to the tree
      # between cycles is `Checkpoint`'s business; this method only decides which
      # directory it is.
      def self.kept(reference, ref:, home:)
        root = File.join(home, "targets", key_for(reference, ref), "tree")
        unless File.directory?(File.join(root, ".git"))
          FileUtils.mkdir_p(File.dirname(root))
          argv = ["git", "clone"]
          argv += ["--depth", "1"] if url?(reference)
          argv += ["--branch", ref] if ref
          argv += [reference, root]
          run(argv, what: "clone #{reference}")
        end
        new(root: root, commit: head_of(root), description: "#{reference} (kept for the walk)", home: home)
      end

      # The key a working copy is filed under: the source and the ref, and nothing else.
      # One function rather than an expression written twice, because a per-run copy and a
      # kept one disagreeing about their key is a loop that re-clones every cycle.
      def self.key_for(reference, ref)
        Digest::SHA256.hexdigest("#{reference}\n#{ref}")[0, 16]
      end

      # What a step's commands run under, so the bundle it installs belongs to this run
      # and the gem downloads it reuses belong to the machine. `GEM_HOME` is the client's
      # own directory; `BUNDLE_PATH` is where the gems actually land.
      #
      # **Outside the working copy**, and that is a correction rather than a preference: it
      # used to be `<root>/.bundle`, which is inside the tree the loop commits (`Checkpoint`),
      # so a walk would have committed an installed gemset — thousands of files, on every
      # step. Keyed by the working copy, so a kept tree keeps its bundle across its own steps
      # (the application is one application, moving forward) while two trees never share one:
      # a gemset is evidence, not an artifact.
      # **Nokogiri is built against the image's own libxml2, and the reason is measured rather than
      # taste.** By default it vendors libxml2 and builds it with libtool, whose install step copies
      # the static library and then `chmod`s it — and on the Docker Desktop share this walker's home
      # is a bind mount of, `/usr/bin/install -c` of a multi-megabyte file answers "setting
      # permissions for .../libxml2.a: Operation not permitted" and exits 1. Measured at the 4.2 rung:
      # the pin *resolved* correctly and then died installing nokogiri 1.9.1, while `cp -r`, `tar` and
      # a plain `chmod` of the same tree into the same share all succeed — it is `install -c` of a
      # large file that does not. The image ships libxml2-dev 2.9.1 and libxslt1-dev 1.1.28, so the
      # flag skips the vendored build entirely and the gem installs.
      # **`BUNDLE_PATH` is per interpreter, because a gemset is evidence rather than an artifact.**
      # The same rule the miner's environments are held to, one layer down, and measured the hard way
      # at the 7.0 rung. The path was keyed by the working copy alone, so the extensions the 2.5 era
      # had built were still in place when the 2.7 era asked for the same tree:
      #
      #     LoadError: libruby.so.2.5: cannot open shared object file: No such file or directory
      #       /agents-fyi/bundles/<key>/gems/strscan-3.1.8/lib/strscan.so
      #
      # — a `.so` built against one libruby, loaded by another — and every era after the first one
      # then fails the machine probe with it, because the probe *is* a `bundle install` and the failure
      # reads as "no interpreter installed the application's bundle". A *gem cache* may be shared: a
      # `.gem` is an artifact the index published a hash for. What may not is the tree the gem is
      # unpacked into and executed from. So the path carries the era, and two eras never share one.
      # `machine:` is required rather than defaulted: a call site that forgot it would silently share
      # again, which is the bug this exists to prevent.
      def bundle_env(machine:)
        { "BUNDLE_PATH" => File.join(home, "bundles", Digest::SHA256.hexdigest(root)[0, 16],
          era_of(machine)),
         "BUNDLE_GEMFILE" => File.join(root, "Gemfile"),
         "BUNDLE_WITHOUT" => "development",
         "BUNDLE_BUILD__NOKOGIRI" => "--use-system-libraries" }
      end

      # The interpreter's own name for the bundle directory. An era is the image a step runs in, which
      # is one ruby, so it is the unit — and a machine that has no era (the host, in `rvm` mode) is
      # named by its interpreter instead. Sanitised because an interpreter string carries spaces
      # (`ruby 2.5.9`) and a path segment may not.
      def era_of(machine)
        named = machine.respond_to?(:era) && !machine.era.to_s.empty? ? machine.era : machine.interpreter
        named.to_s.strip.gsub(/[^A-Za-z0-9._-]/, "-")
      end

      # **The bundles of runs that are over.** A gemset is per-run on purpose — a killed step
      # must not leave a half-installed one for the next run to trust — and the price of that is
      # that nothing ever asks for the directory again: 21 of them, 2.0 GB and 154,560 files
      # under this walker's home, which is the bind mount Docker sets up for *every* step.
      # Measured: one step's `docker run` went from twenty seconds to **five minutes** as that
      # directory grew, and the step that pays for it has not started yet.
      #
      # A run directory's name carries the pid that owns it (`run-<timestamp>-<pid>`), so a run
      # whose process is gone is a run whose bundle is dead weight. A live run's bundle is never
      # touched, and neither is the kept tree's under `targets/` — that one is not a run at all,
      # it is the reuse a walk is built around, and it has no run directory to be judged by.
      def self.prune_bundles(home:, out: nil)
        removed = []
        Dir[File.join(home, "work", "*", "run-*")].each do |root|
          pid = File.basename(root)[/run-\d+-(\d+)\z/, 1]
          next if pid.nil? || Processes.alive?(pid)

          path = File.join(home, "bundles", Digest::SHA256.hexdigest(root)[0, 16])
          next unless File.directory?(path)

          FileUtils.remove_entry(path)
          removed << path
        end
        out&.puts("  pruned #{removed.size} bundle(s) of runs that are over") if removed.any?
        removed
      end

      # The commit, or nil when the source is not a git working tree — which is a
      # fact worth printing rather than a reason to refuse: a person pointing this at
      # an unversioned export still gets the plan they asked for.
      def self.head_of(root)
        output, _err, status = Open3.capture3("git", "-C", root, "rev-parse", "HEAD")
        status.success? ? output.strip : nil
      rescue Errno::ENOENT
        nil
      end

      def self.run(argv, what:)
        _output, err, status = Open3.capture3(*argv)
        return if status.success?

        raise Failed, "#{what} failed (exit #{status.exitstatus}): #{err.strip}"
      rescue Errno::ENOENT
        raise Failed, "#{what} failed: git is not installed"
      end
    end
  end
end
