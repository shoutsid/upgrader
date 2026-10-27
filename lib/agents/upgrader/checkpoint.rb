# frozen_string_literal: true

require "fileutils"
require "open3"

module Agents
  module Upgrader
    # What happens to the working copy a walk keeps, between two of its steps.
    #
    # A `step` run by hand leaves its product in a patch and is finished with the tree.
    # A *walk* is the other shape: the same tree is measured, moved, and then measured
    # again from where it arrived, and this module is the two things that decides —
    # commit a step that passed, so the next cycle's base is a real commit; reset one
    # that did not, so the next cycle retries the same rung from the same base instead
    # of building on a half-applied move.
    #
    # It is a module of commands rather than a class holding a tree, because it has no
    # state: the tree is the loop's, the verdict is the record's, and everything here is
    # `git` on a path with an exit code.
    #
    # Two rules are load-bearing:
    #
    # * **Only a passing step is committed.** A `failed`, `refused` or `unverified` step
    #   leaves a tree that *looks* moved — the pin is rewritten, `app:update` has run —
    #   and committing it would make the next cycle plan from a release nobody has shown
    #   to work. The ladder is walked on evidence, so a step that produced none advances
    #   nothing.
    # * **A reset is `reset`, `checkout` and `clean`, never `clean -x`.** Ignored files are
    #   deliberately left alone: the installed bundle, `tmp/`, `log/` and the vendored
    #   caches are the expensive half of the tree and none of them is part of a step's
    #   result. Only tracked modifications and untracked *additions* — which is exactly
    #   what a step makes — are put back. The `reset` is the first of the three and not a
    #   flourish: the record's own patch is built with `git add --intent-to-add --all`
    #   (`Step#patch`), which is an *index* entry, and `clean -fd` removes untracked paths
    #   only — measured on the 6.0 rung, where `app:update`'s
    #   `config/initializers/new_framework_defaults_6_0.rb` and an ActiveStorage migration
    #   survived a "back at its base commit" reset and the next attempt's patch refused to
    #   apply over them.
    module Checkpoint
      # **Build outputs belong to the run, not to the step.** `assets:precompile`,
      # `yarn install` and the test suite's own caches write paths a fresh tree does not
      # have, and a step's `git add --all` has no way to tell them from the application's
      # source. Measured on the 4.1 rung: the pre-pin `assets:precompile` wrote
      # `public/assets`, and the “apply mechanical rules” commit carried 29,758 generated
      # lines — a generated jQuery/jQuery UI bundle, its `.gz` siblings, and a manifest
      # whose CSS references files that were not in the commit. They are ignored through
      # `.git/info/exclude` rather than the application's `.gitignore`: the rule belongs to
      # this working copy, not to the application's history, and the file it writes must
      # never appear in the diff it is protecting.
      BUILD_OUTPUTS = %w[
        public/assets
        public/packs
        public/packs-test
        public/vite
        public/vite-dev
        app/assets/builds
        node_modules
        tmp
        log
        coverage
        storage
      ].freeze

      # The local exclude is idempotent and deliberately never committed. A path already
      # in the application's `.gitignore` is written again here; git does not mind, and a
      # step that runs in a clone the application's ignore file does not cover is the case
      # this exists for.
      def self.ignore_build_outputs(root)
        directory = File.join(root.to_s, ".git")
        return unless File.directory?(directory)

        info = File.join(directory, "info")
        FileUtils.mkdir_p(info)
        path = File.join(info, "exclude")
        existing = File.file?(path) ? File.read(path) : ""
        present = existing.lines.map(&:strip)
        patterns = BUILD_OUTPUTS.map { |output| "/#{output}/" }
        missing = patterns.reject { |pattern| present.include?(pattern) }
        return if missing.empty?

        File.open(path, "a") do |file|
          file.puts unless existing.empty? || existing.end_with?("\n")
          file.puts("# agents upgrader: generated build outputs, never part of a step")
          missing.each { |pattern| file.puts(pattern) }
        end
      end

      # The message a checkpoint carries, and it names the move rather than this tool:
      # `git log` on the tree is how an operator reads what a kept repository has been
      # through, and "checkpoint" says nothing about that.
      #
      # **A concern is a commit a reviewer can read on its own.** The default is the whole
      # step, and it is kept for the caller that has nothing finer to say — `serve`'s settle,
      # a tree a killed run left, a `step` by hand. A step that commits as it goes passes the
      # concern ("pin Rails and move gems", "run app:update") and the branch becomes a series
      # rather than one opaque commit.
      def self.message(from:, to:, concern: nil)
        base = "agents upgrader: the #{from} -> #{to} step"
        concern.to_s.empty? ? "#{base}, as this tool made it" : "#{base} — #{concern}"
      end

      def self.dirty?(root)
        ignore_build_outputs(root)
        output, _status = git(root, "status", "--porcelain")
        !output.strip.empty?
      end

      # **The commit a kept tree is being walked from, persisted outside the commits themselves.**
      # A concern commit moves HEAD; a process killed after one leaves a *clean* tree sitting on a
      # half-move, so `dirty?` cannot tell the next cycle that the tree needs putting back. The
      # marker lives under `.git` — never committed, never part of the patch — and is updated only
      # when a rung passes (`Serve#settle`) or when a tree first becomes the loop's.
      BASE_MARKER = "agents-base"

      def self.base(root)
        path = File.join(root.to_s, ".git", BASE_MARKER)
        File.file?(path) ? File.read(path).strip : nil
      end

      # **Where this walk began, which is not where it last passed.** `base` moves with every
      # passing rung, so it is the right answer for "what does the next step start from" and the
      # wrong one for "put this repository back to the release its project is on". The two were
      # the same commit until the first rung passed, and telling them apart is what a reconnect
      # needs (see `Step#rewind_to_declared`): a project connected again starts at the release the
      # application is on, while the kept tree sits at the top of the previous walk.
      #
      # The commit is found rather than recorded: every commit this tool makes says so in its
      # subject, so the parent of the oldest one is the clone point — and a tree the loop has not
      # stepped in yet is already there. `git log` rather than the shallow boundary, because a
      # local path's kept clone is not shallow and its repository's own first commit is not where
      # this walk started.
      TOOL_PREFIX = "agents upgrader: "

      def self.origin(root)
        found, status = git(root, "log", "--reverse", "--format=%H", "--grep=#{TOOL_PREFIX}")
        oldest = status&.success? ? found.lines.map(&:strip).find { |line| !line.empty? } : nil
        if oldest
          parent, parent_status = git(root, "rev-parse", "--verify", "--quiet", "#{oldest}^")
          return parent.strip if parent_status&.success?
        end

        start = head(root).first.to_s.strip
        start.empty? ? nil : start
      end

      def self.remember_base(root, commit)
        return if commit.to_s.empty?

        directory = File.join(root.to_s, ".git")
        return unless File.directory?(directory)

        File.write(File.join(directory, BASE_MARKER), "#{commit}\n")
      end

      # Everything the step changed, as one commit, and the commit it made. A step that
      # changed nothing (`app:update` found nothing, the scan had no edits, the pin was
      # already there) has nothing to commit — that is a pass that moved the tree
      # nowhere, and the existing HEAD *is* the base for the next step, so it is returned
      # rather than raised about.
      def self.commit(root, from:, to:, out: $stdout, concern: nil)
        ignore_build_outputs(root)
        git(root, "add", "--all")
        output, status = git(root, "-c", "user.email=upgrader@agents.test",
          "-c", "user.name=agents upgrader",
          "commit", "--quiet", "-m", message(from: from, to: to, concern: concern))
        unless status.success? || output.match?(/nothing to commit|nothing added to commit/)
          # Said rather than swallowed: a checkpoint that did not happen means the next
          # cycle re-measures the same rung, and the operator should hear it from the
          # loop rather than infer it from a repeated line.
          out.puts("  checkpoint: the step's tree could not be committed: #{output.strip}")
        end

        head(root).first
      end

      # Back to the base commit: the caller's files restored, the step's added files
      # removed, ignored files (the bundle, `tmp`, `log`) left where they are. The index
      # goes back to HEAD first, so a path the patch machinery marked intent-to-add is a
      # file this can remove — see the rule above.
      #
      # **A step that commits its concerns has moved HEAD, so the base is named.** `to:` is the
      # commit the rung started from; a hard reset to it restores tracked files and leaves
      # ignored ones alone, and `clean -fd` (never `-x`) removes the step's added files. Without
      # it, a failed step that had already committed a phase would leave the next cycle planning
      # from that half-move, which is the trap this module exists to prevent.
      def self.reset(root, to: nil)
        if !to.to_s.empty? && resolvable?(root, to)
          git(root, "reset", "--hard", "--quiet", to)
        else
          # A commit a caller named but this copy does not hold is a label rather than an
          # object (a test's double, a tree rebuilt elsewhere). Resetting to HEAD is the
          # honest fallback: it still restores tracked files and removes the step's additions.
          git(root, "reset", "--quiet")
          git(root, "checkout", "--", ".")
        end
        git(root, "clean", "-fd", "--quiet")
      end

      def self.resolvable?(root, commit)
        _output, status = git(root, "rev-parse", "--verify", "--quiet", "#{commit}^{commit}")
        status&.success? == true
      end

      def self.head(root)
        output, status = git(root, "rev-parse", "HEAD")
        [output.strip, status]
      end

      def self.git(root, *argv)
        Open3.capture2e("git", "-C", root, *argv)
      rescue Errno::ENOENT
        ["git is not installed", nil]
      end
    end
  end
end
