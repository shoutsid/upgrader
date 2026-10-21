# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "uri"

module AgentsFyi
  module Upgrader
    # One branch per passed rung, and a pull request chained to the rung before it.
    #
    # This is the delivery half of a walk, and it is deliberately the *only* thing in this
    # tool that writes anywhere but a copy it owns: everything before it produces a patch
    # and a record, and a walk without this is a pile of patches nobody has a branch for.
    #
    # Three decisions shape it:
    #
    # * **A branch per rung rather than one branch for the walk.** The point of walking one
    #   minor release at a time is that each rung is reviewable on its own — Rails' own
    #   guide's rule — so `agents-fyi/upgrade-4.1.0` carries the 4.1 rung and nothing else,
    #   and the pull request for it targets the *previous rung's branch*
    #   (`agents-fyi/upgrade-4.0.0`) when that branch exists and the repository's default
    #   branch when it does not. That is what makes the requests chain: GitHub shows the
    #   4.1 diff against 4.0, so a reviewer reads one rung's worth of change instead of
    #   every rung at once.
    # * **Only a passing step is published.** The same rule as the checkpoint, one layer
    #   out: a branch is a claim that this rung works, and a `failed`/`unverified` record
    #   has not established that. This class therefore does not decide *whether* to
    #   publish — its caller does, from the verdict — but it re-states the check for the
    #   callers that forget.
    # * **The token is never written down.** It arrives from `UPGRADER_GITHUB_TOKEN`, it is
    #   used in the push URL, and every message on the way out has it replaced with `***`.
    #   A token in a record is a token in a corpus, and this record is published beside the
    #   run.
    class Publish
      # Where the token comes from. Named here and read by no other file: the container sets
      # it as an environment variable and the CLI never mentions it.
      ENV_TOKEN = "UPGRADER_GITHUB_TOKEN"

      # The namespace a branch lives under when the project declares none. Load-bearing for two
      # reasons: a re-run of the same rung updates one branch instead of opening a second one, and
      # `push --force` is only ever used inside a namespace this tool owns. A project may name its
      # own pattern (`Project::Delivery#branch`, with `<release>` substituted), because a fork or a
      # second project should not have to publish into this one's namespace.
      DEFAULT_BRANCH = "agents-fyi/upgrade-<release>"

      # What publishing did, in one value. `pushed` and `pull_request` are separate because
      # they fail separately: a branch can reach the remote and the API refuse to open a
      # request for it.
      Result = Struct.new(:pushed, :branch, :base, :commit, :pull_request, :reason,
        keyword_init: true) do
        def published? = pushed && !pull_request.to_s.empty?

        def to_h
          { "pushed" => pushed, "branch" => branch, "base" => base, "commit" => commit,
            "pull_request" => pull_request, "reason" => reason }
        end

        def to_s
          if published?
            "published: #{branch} -> #{pull_request}"
          elsif pushed
            "published: #{branch} pushed, and no pull request was opened: #{reason}"
          else
            "not published: #{reason}"
          end
        end
      end

      def self.branch_for(version, pattern: DEFAULT_BRANCH)
        pattern.to_s.gsub("<release>", version.to_s)
      end

      # **Whether a repository has a pull request to open at all.** A plain git remote is a delivered
      # branch with no request, and that is a complete delivery rather than a failure — the caller
      # needs to tell the two apart to know whether to retry.
      def self.github?(repository)
        repository.to_s.match?(%r{\A(https://|http://|git://|git@)github\.com[:/]})
      end

      def initialize(root:, repository:, from_version:, to_version:, record: nil, token: nil,
                     out: nil, api: nil, git: nil, pause: nil, branch_pattern: nil, commit: nil,
                     report_base: nil, base_ref: nil)
        @root = root
        @repository = repository.to_s
        @from_version = from_version.to_s
        @to_version = to_version.to_s
        @record = record
        # nil asks the environment; anything else, including "", is what the caller said —
        # a test that pinned nothing would otherwise publish with the developer's own token.
        @token = (token.nil? ? ENV[ENV_TOKEN] : token).to_s
        @out = out
        @api = api
        # The one command surface this class has, injectable so the suite can drive a push
        # and a rejected lease without a network: [output, status], the shape
        # `Checkpoint`'s own `git` returns.
        @git = git
        # How a retry waits, injectable so a test drives three attempts without sleeping through
        # them. See `push` for why a push is retried at all.
        @pause = pause || ->(seconds) { sleep(seconds) }
        # The project's branch pattern, or this tool's own namespace: the one place a branch name is
        # built, so a chain's base and its branch can never be spelled by two rules.
        @branch_pattern = branch_pattern.to_s.empty? ? DEFAULT_BRANCH : branch_pattern.to_s
        # **The commit to publish, when the step is not the one publishing it.** A delivery retry
        # carries the commit the first attempt produced: the tree has moved on, and re-committing a
        # clean tree would publish a different fact than the one the suite established.
        @commit = commit.to_s
        # **Where a reviewer can open a report.** The walker's API base is often an internal
        # hostname (`http://service:8001`); a link built from it in a pull request is unopenable.
        # The deployment names the public base, and no base means the report is named rather than
        # linked.
        @report_base = report_base.to_s.chomp("/")
        # **The first rung's base is the walk's starting ref, not the repository's default.** A
        # project declares `base_ref` (`agents-fyi/baseline` for the lighthouse); the first rung has
        # no previous rung's branch to chain to, and falling back to `master` put the baseline's own
        # view fixes into the 4.1 diff. Later rungs still use the previous rung's branch.
        @base_ref = base_ref.to_s
      end

      def call
        if @record && !@record.passed?
          return Result.new(pushed: false, branch: branch, reason:
            "the step's verdict is #{@record.verdict}, and a branch is a claim that this rung " \
            "works: publish only what established that")
        end

        # A plain git remote — an operator's mirror, a test's bare clone — needs no
        # credential to push to, and refusing it for a missing *GitHub* token would make the
        # token an obligation of the wrong thing. The token is required exactly where there
        # is an API to call.
        unless github?
          commit = publish_commit
          @publishing_commit = commit
          @base = base_branch
          pushed, pushed_why = push(commit)
          return Result.new(pushed: false, branch: branch, commit: commit, reason: pushed_why) unless pushed

          return Result.new(pushed: true, branch: branch, base: @base, commit: commit, reason:
            "#{@repository} is not a github.com repository, so there is nowhere to open a pull " \
            "request: the branch is on origin, and the patch and the record are the product " \
            "for anything else")
        end

        if @token.empty?
          return Result.new(pushed: false, branch: branch, reason:
            "no GitHub token: set #{ENV_TOKEN} to push a branch and open a pull request, or " \
            "keep working from the patch this step left behind")
        end

        commit = publish_commit
        @publishing_commit = commit
        pushed, pushed_why = push(commit)
        return Result.new(pushed: false, branch: branch, commit: commit, reason: pushed_why) unless pushed

        @base = base_branch
        request = request_pull_request(
          owner: owner, name: name, head: branch, base: @base,
          title: title, body: body
        )
        Result.new(pushed: true, branch: branch, base: @base, commit: commit,
          pull_request: request, reason: "")
      rescue GitHub::Refused => e
        Result.new(pushed: false, branch: branch, reason: redact(e.message))
      end

      # **The body without a push.** `Preview` is the caller: a stored record is already the whole
      # evidence, and rendering it should not need a checkout or a token. The method is public so a
      # dry run is an ordinary call rather than a test's `send`.
      def preview_body = body

      private

      # **The request is the network too, and a push that retries while the request beside it does not
      # leaves the same hole.** Measured on the clean re-run: `api.github.com` answered `getaddrinfo: No
      # address associated with hostname` once at 18:22:28, the rung had already been pushed and settled,
      # and 7.0.0 kept a branch with no pull request for the rest of the walk — and a settled rung is
      # never revisited, so the hole was permanent. Same attempts and backoff as the push, for the same
      # reason; what the caller finally reads is one sentence rather than a resolver's backtrace.
      def request_pull_request(attempt: 1, **arguments)
        api.pull_request(**arguments)
      rescue GitHub::Refused => e
        raise if attempt >= PUSH_ATTEMPTS

        @out&.puts("publish: the pull request could not be opened (#{redact(e.message)}) — retrying")
        @pause.call(PUSH_BACKOFF_SECONDS * (2**(attempt - 1)))
        request_pull_request(attempt: attempt + 1, **arguments)
      end

      def branch = self.class.branch_for(@to_version, pattern: @branch_pattern)

      # The previous rung's branch when the remote has it, and the repository's own default
      # branch when it does not — the first rung of a walk targets the branch the
      # repository already develops on, which is what makes the chain start where a
      # reviewer expects it to.
      #
      # The default branch is asked of the *remote* first (`ls-remote --symref HEAD`), which
      # needs no credential and works for a plain git remote; the API is the fallback for a
      # remote that will not answer that way, and `main` is the last resort because a pull
      # request needs a base and refusing to open one over a naming guess is worse than
      # saying which guess was made — the branch and the request are both in the record.
      def base_branch
        previous = self.class.branch_for(@from_version, pattern: @branch_pattern)
        return previous if remote_has?(previous)
        return @base_ref if !@base_ref.empty? && remote_has?(@base_ref)

        remote_default_branch || api_default_branch || "main"
      end

      def remote_default_branch
        out, status = git("ls-remote", "--symref", push_url, "HEAD")
        return nil unless status&.success?

        out.to_s[/ref:\s+refs\/heads\/(\S+)\s+HEAD/, 1]
      end

      def api_default_branch
        return nil unless github?

        api.default_branch(owner: owner, name: name)
      rescue GitHub::Refused
        nil
      end

      # The commit a delivery publishes: the retry's recorded one when it has it, and otherwise
      # the step's changes as one commit, with a message that names the move. `Checkpoint`'s
      # message is reused rather than written again: a branch and a kept tree are two copies
      # of the same rung, and `git log` on either should read the same.
      def publish_commit
        return @commit unless @commit.empty?

        Checkpoint.commit(@root, from: @from_version, to: @to_version, out: @out)
      end

      # **A push is retried, because the failure a walk actually meets is the network.** Measured on
      # the deployment: `agents-fyi/upgrade-4.1.0` pushed and opened its pull request, and the next
      # rung's push answered `fatal: unable to access … Could not resolve host: github.com` — the rung
      # *passed*, the branch was never created, and the hole is permanent because the loop never
      # revisits a passed rung (`settled?`). A transient failure clears on a second attempt; a
      # permanent one — no permission, a rejected ref — reports the same reason after the last, so the
      # retry costs two attempts and buys back a rung's delivery.
      PUSH_ATTEMPTS = 3

      # Seconds before the second attempt, doubled for the third. Short: a resolver that was not
      # answering a moment ago is the case this is for, and a walk is not waiting on it.
      PUSH_BACKOFF_SECONDS = 5

      def push(commit)
        reason = ""
        PUSH_ATTEMPTS.times do |attempt|
          out, status = git("push", "--quiet", "--force", push_url, "#{commit}:refs/heads/#{branch}")
          return [true, ""] if status&.success?

          reason = "the branch could not be pushed to #{@repository}: #{redact(out.to_s.strip)}"
          next if attempt == PUSH_ATTEMPTS - 1

          @out.puts("publish: #{reason} — retrying") if @out
          @pause.call(PUSH_BACKOFF_SECONDS * (attempt + 1))
        end
        [false, reason]
      end

      # The origin URL with a token in it. GitHub's own convention for an app token is the
      # `x-access-token` user, which works for fine-grained tokens as well as classic ones.
      #
      # A local path — the shape a test and an operator's own mirror both take — is pushed
      # to as it stands, because a path is somewhere git can push without a credential.
      def push_url
        return @repository unless github?

        "https://x-access-token:#{@token}@github.com/#{owner}/#{name}.git"
      end

      # **A remote that could not be asked is not a branch that is absent.** The base chain is the
      # previous rung's branch; a transient DNS failure on the `ls-remote` used to answer "no", the
      # base fell back to the repository default, and the PR chain broke at that rung (measured on
      # the 6.0 request: its base became `master` while every neighbour pointed at 5.2). Retried like
      # the push; only a successful answer with no ref is a "no".
      def remote_has?(candidate)
        PUSH_ATTEMPTS.times do |attempt|
          out, status = git("ls-remote", "--heads", push_url, candidate)
          return !out.to_s.strip.empty? if status&.success?

          next if attempt == PUSH_ATTEMPTS - 1

          @out&.puts("publish: the remote could not be asked about #{candidate} — retrying")
          @pause.call(PUSH_BACKOFF_SECONDS * (attempt + 1))
        end
        false
      end

      def git(*argv)
        return @git.call(@root, *argv) if @git

        Open3.capture2e("git", "-C", @root, *argv)
      rescue Errno::ENOENT
        ["git is not installed", nil]
      end

      def api
        @api ||= GitHub.new(token: @token)
      end

      def github? = self.class.github?(@repository)

      # `owner` and `name` out of every spelling GitHub is cloned by:
      # `https://github.com/owner/name(.git)` and `git@github.com:owner/name(.git)`.
      def owner
        @owner ||= @repository[%r{github\.com[:/]([^/]+)/}, 1].to_s
      end

      def name
        @name ||= @repository[%r{github\.com[:/][^/]+/([^/]+?)(\.git)?\z}, 1].to_s
      end

      def title
        "Upgrade Rails to #{@to_version} (agents-fyi)"
      end

      # **The review brief, not a run log.** A reviewer's questions are: what moved, what established
      # it, what is different in *this* application, what did the tool decide, what is left for me,
      # and is it safe to merge. The run record is below, collapsed, because it is the evidence and
      # not the first thing a person should have to read. Every line is composed from the record, so
      # the request cannot say something the record does not.
      def body
        sections = [moved_section]
        sections << checks_section
        sections << brief_section if @record&.brief
        sections << changed_section if @record
        sections << decisions_section if @record
        sections << app_update_section if @record
        sections << manual_section if @record
        sections << merge_section
        sections << record_section if @record
        sections.join("\n\n")
      end

      def moved_section
        lines = ["## What moved", ""]
        lines << "`agents-fyi` walked one rung of the Rails ladder: **#{@from_version} → #{@to_version}**."
        if @record
          lines << ""
          lines << "The step's own verdict: `#{@record.verdict}` — #{@record.why}"
        end
        lines << ""
        lines << "- base commit: `#{short(base_commit)}`" unless base_commit.empty?
        lines << "- base branch: `#{@base}`" unless @base.to_s.empty?
        lines << "- delivered head: `#{short(delivered_head)}`" unless delivered_head.to_s.empty?
        unless @commit.empty? || @publishing_commit == @commit
          lines << ""
          lines << "This branch is the rung's recorded commit `#{@commit[0, 8]}`: the first delivery " \
                   "attempt could not reach the remote, and the rung was not re-walked."
        end
        lines.join("\n")
      end

      # The gate, one row per check. **An external check is never green here**: the walk did not run
      # it, and the application's CI owns the answer. The suite is the first row because it is the
      # test check; `checks` is what the suite alone was hiding.
      def checks_section
        unless @record
          return "## Checks\n\nThe run record is not available on this delivery retry, so no check " \
                 "result is claimed here. The branch carries the commit the first attempt produced."
        end

        lines = ["## Checks", "", "| Check | Result | What ran |", "|---|---|---|"]
        lines << suite_row
        style_row = style_check_row
        lines << style_row if style_row
        @record.checks.each do |check|
          result = check.external? ? "external — not run here" : check.status.tr("_", " ")
          what = check.external? ? check.reason.to_s : "`#{check.command}`"
          required = check.required ? "" : " (optional)"
          lines << "| #{check.label}#{required} | #{result} | #{escape_cell(what)} |"
        end
        if @record.checks.empty? && style_row.nil?
          if @record.project.nil?
            lines << "| other checks | not recorded | this record carries no check results; the " \
                     "suite is the only gate it names |"
          else
            lines << "| other checks | none declared | the suite is the gate the project declares |"
          end
        end
        external = @record.checks.count(&:external?)
        if external.positive?
          lines << ""
          lines << "**#{external} check(s) are external and were not run by this walk.** They are " \
                   "listed with where they run; this pull request does not report them as green."
        end
        toolchain = toolchain_note
        lines << "" << toolchain if toolchain
        lines << ""
        lines << "## What established it"
        lines << ""
        evidence.each { |line| lines << "- #{line}" }
        lines.join("\n")
      end

      def suite_row
        result =
          if @record.suite.nil?
            @record.project.nil? ? "not recorded" : "not declared"
          elsif !@record.suite.ran
            "did not run"
          elsif @record.suite.ok? && @record.baseline&.ok?
            "passed"
          elsif !@record.baseline&.ok?
            "unverified — the baseline was not green"
          else
            "failed"
          end
        what =
          if @record.suite
            "`#{@record.suite.command}` (baseline: #{status_word(@record.baseline)}; " \
              "after: #{status_word(@record.suite)})"
          elsif @record.project.nil?
            "the record does not carry a suite stage"
          else
            "no suite was found"
          end
        "| suite | #{result} | #{escape_cell(what)} |"
      end

      def style_check_row
        stage = @record.stages.find { |entry| entry.stage == Record::STYLE }
        return nil if stage.nil?

        result = stage.ok? ? "passed" : (stage.ran ? "failed" : "did not run")
        "| style | #{result} | #{escape_cell("`#{stage.readable}`")} |"
      end

      def status_word(command)
        return "not run" if command.nil?
        return "did not run" unless command.ran

        command.ok? ? "exit 0" : "exit #{command.exit_code}"
      end

      # **The declared toolchain beside the one that ran.** Ruby is measurable here — the record
      # carries the interpreter — and a mismatch is a parity failure a reviewer should see. Node,
      # PostgreSQL, extensions and native libraries are declared facts; this record does not
      # measure them, and it says so rather than implying they were checked.
      def toolchain_note
        facts = @record.toolchain
        return nil if facts.nil? || facts.empty?

        parts = []
        parts << "Ruby `#{facts["ruby"]}`" unless facts["ruby"].to_s.empty?
        parts << "Node `#{facts["node"]}`" unless facts["node"].to_s.empty?
        parts << "PostgreSQL `#{facts["postgres"]}`" unless facts["postgres"].to_s.empty?
        parts << "extensions #{Array(facts["extensions"]).join(", ")}" if Array(facts["extensions"]).any?
        parts << "apt #{Array(facts["apt"]).join(", ")}" if Array(facts["apt"]).any?
        return nil if parts.empty?

        note = "Declared toolchain: #{parts.join(", ")}."
        declared_ruby = facts["ruby"].to_s
        if !declared_ruby.empty? && !@record.interpreter.to_s.include?(declared_ruby)
          note += " This run executed on `#{@record.interpreter}`, which is not the declared Ruby: " \
                  "the record cannot claim the application's CI parity."
        end
        note += " The non-Ruby facts are declarations, not measurements of this run."
        note
      end

      def brief_section
        lines = ["## What the corpus already knew", ""]
        lines << @record.brief.to_markdown(base: @report_base.empty? ? nil : @report_base)
        lines.join("\n")
      end

      # What changed, by concern. The commits are made where the tree changes, so this list is the
      # branch's own review order; the diff is still the whole rung against the base.
      def changed_section
        lines = ["## What changed", ""]
        if @record.commits.any?
          lines << "The branch is a series of concern-sized commits:"
          lines << ""
          @record.commits.each do |commit|
            lines << "- `#{short(commit["commit"])}` — #{commit["message"]}"
          end
        elsif delivered_head.to_s != @commit.to_s
          lines << "- the rung's changes are in `#{short(delivered_head)}`"
        else
          lines << "- this record does not carry a concern-commit series"
        end

        pin = @record.stages.find { |stage| stage.stage == Record::PIN }
        if pin
          lines << "- Rails pin: `#{public_stage_command(pin)}` — " \
                   "#{pin.ok? ? "exit 0" : "exit #{pin.exit_code}"}"
        end

        if @record.app_update
          update = @record.app_update
          lines << "- `app:update`: #{Array(update["adopted"]).length} file(s) adopted, " \
                   "#{Array(update["conflicts"]).length} conflict(s), " \
                   "#{Array(update["skipped"]).length} skipped by policy"
        end

        if @record.applied.any?
          counts = Hash.new(0)
          @record.applied.each do |edit|
            origin = edit.respond_to?(:origin) ? edit.origin.to_s : ""
            counts[origin] += 1
          end
          decided = counts.select { |origin, _| origin.start_with?("decision:") }.values.sum
          parts = []
          parts << "#{decided} from an accepted decision" if decided.positive?
          parts << "#{counts['rule']} from this tool's own rules" if counts["rule"].positive?
          parts << "#{counts['companion']} from gems' own upgrades" if counts["companion"].positive?
          parts << "#{counts['']} from the service's scan" if counts[""].positive?
          lines << ""
          # **This sentence is kept word for word**: it is what a reader uses to tell a mechanical
          # rung from one an accepted decision shaped, and the tests hold it.
          lines << "The tool wrote #{@record.applied.length} edit(s): #{parts.join(", ")}. The diff " \
                   "is the complete record; every edit and its reason is on the run's page."
        end
        lines.join("\n")
      end

      # **An accepted decision is not a "needs a decision".** It was answered before the rung ran,
      # its effects were applied before the baseline, and the suite that establishes the rung ran
      # with them in place — so it belongs to what the rung *is*, not to what is still owed. The
      # question and answer are what a reviewer reads; the patch is the implementation.
      def decisions_section
        decided = @record.applied.select do |edit|
          edit.respond_to?(:origin) && edit.origin.to_s.start_with?("decision:")
        end
        return "" if @record.accepted_decisions.empty? && decided.empty?

        lines = ["## Decisions in force", ""]
        @record.accepted_decisions.each do |decision|
          lines << "### `#{decision["id"]}` — #{decision["question"]}"
          lines << ""
          lines << "**Answer.** #{decision["answer"]}"
          lines << ""
          lines << "Accepted by `#{decision["accepted_by"]}`; " \
                   "#{Array(decision["effects"]).length} effect(s) in force. " \
                   "The suite ran with them in place."
          lines << ""
        end
        unless decided.empty?
          lines << "The edits these decisions made:"
          lines << ""
          decided.group_by(&:origin).each do |origin, edits|
            lines << "### `#{origin}`"
            edits.each do |edit|
              lines << "- `#{edit.path}`:#{edit.line} `#{edit.text.to_s.strip}` → " \
                       "`#{edit.after.to_s.strip}`"
            end
          end
        end
        lines.join("\n")
      end

      # `app:update` gets its own section because it is the stage a reviewer asks about separately:
      # which generated files arrived, which were kept as the application's own, and whether the
      # framework defaults were adopted or left alone.
      def app_update_section
        update = @record.app_update
        if update.nil?
          return "## app:update\n\nThis record does not carry an `app:update` section — it was " \
                 "written before that section existed, or by a client that did not send one. " \
                 "That is not the same as saying the stage did not run."
        end

        defaults = update["load_defaults"].to_s.empty? ? "" :
          " (the application declares `config.load_defaults #{update["load_defaults"]}`)"
        lines = ["## app:update", "",
          "- adoption: `#{update["adopt"]}` — a file the application already owns keeps its version",
          "- framework defaults: `#{update["framework_defaults"]}`#{defaults}"]
        adopted = Array(update["adopted"])
        unless adopted.empty?
          lines << ""
          lines << "### Files adopted"
          lines << ""
          adopted.first(15).each { |path| lines << "- `#{path}`" }
          lines << "- …and #{adopted.length - 15} more in the run record" if adopted.length > 15
        end
        conflicts = Array(update["conflicts"])
        unless conflicts.empty?
          lines << ""
          lines << "### Conflicts kept as the application's own"
          lines << ""
          conflicts.first(15).each { |path| lines << "- `#{path}`" }
          lines << "- …and #{conflicts.length - 15} more in the run record" if conflicts.length > 15
        end
        skipped = Array(update["skipped"])
        unless skipped.empty?
          lines << ""
          lines << "### Skipped by the project's policy"
          lines << ""
          skipped.first(15).each do |entry|
            lines << "- `#{entry["path"]}` — #{entry["reason"]}"
          end
          lines << "- …and #{skipped.length - 15} more in the run record" if skipped.length > 15
        end
        lines.join("\n")
      end

      # **Only what is new for this rung.** The carried guide entries are a number, not a list; the
      # call sites this application has are the work. The full list is in the record below.
      def manual_section
        lines = []
        # **A call site an earlier rung already located is not new work.** The service says so in
        # the decision's own reason, and the count is carried rather than the list: a 4.x
        # application at 5.1 has dozens of `belongs_to` rows that are the 5.0 rung's work, and a
        # reviewer who reads them as this rung's debt has been given the wrong list.
        earlier = @record.decisions.select { |decision| carried_earlier?(decision) }
        located = @record.decisions.reject do |decision|
          decision.path.to_s.empty? || carried_earlier?(decision)
        end
        carried = @record.decisions.count { |decision| decision.path.to_s.empty? }
        unless located.empty?
          lines << "## Manual changes found in this application"
          lines << ""
          located.first(20).each do |decision|
            where = [decision.path, decision.line].compact.join(":")
            lines << "- `#{where}` — #{decision.subject}: #{decision.reason}"
          end
          lines << "- …and #{located.length - 20} more in the run record" if located.length > 20
          lines << ""
        end
        if carried.positive?
          lines << "## Manual changes the rung carries"
          lines << ""
          lines << "#{carried} change(s) this rung documents that this application does not use. " \
                   "They need no edit; the run's page lists them."
          lines << ""
        end
        if earlier.any?
          lines << "## Earlier-rung call sites"
          lines << ""
          lines << "#{earlier.length} call site(s) this application has were already located by an " \
                   "earlier rung. They are not this rung's new work; the full run record carries them."
          lines << ""
        end
        unless @record.refused.empty?
          lines << "## Edits the tool could not write"
          lines << ""
          lines << "The line did not match what the scan read, so nothing was written:"
          lines << ""
          @record.refused.first(12).each do |refusal|
            lines << "- `#{refusal.path}`:#{refusal.line} — #{refusal.reason}"
          end
          if @record.refused.length > 12
            lines << "- …and #{@record.refused.length - 12} more in the run record"
          end
          lines << ""
        end
        lines << "Nothing else is left for a person on this rung." if lines.empty?
        lines.join("\n").strip
      end

      # The reviewer's last question: is it safe, how do I undo it, and what merges first.
      def merge_section
        lines = ["## Review and merge", ""]
        lines << "- **Risk:** #{risk}"
        lines << "- **Rollback:** #{rollback}"
        lines << "- **Merge order:** #{merge_order}"
        url = run_url
        lines << "- **Run record:** #{url}" if url
        lines.join("\n")
      end

      def risk
        unless @record
          return "the run record is not available on this retry; review the commit the first " \
                 "attempt produced"
        end
        unless @record.verdict == Record::PASSED
          return "the rung is `#{@record.verdict}` — #{@record.why}. The record's own verdict is " \
                 "the risk statement; read the sections above before treating it as a merge signal"
        end
        if @record.suite.nil?
          return "the record does not carry a suite result, so this preview cannot claim the gate " \
                 "passed; read the commands and the refusals before trusting the verdict"
        end
        if @record.baseline.nil?
          return "the record does not carry a baseline, so the suite's green cannot be attributed " \
                 "to the move; read the commands before treating the verdict as a merge signal"
        end
        unless @record.suite.ok? && @record.baseline.ok?
          return "the record's suite and baseline disagree with its `#{@record.verdict}` verdict; " \
                 "read the checks above before treating it as a merge signal"
        end

        located = @record.decisions.count do |decision|
          !decision.path.to_s.empty? && !carried_earlier?(decision)
        end
        earlier = @record.decisions.count { |decision| carried_earlier?(decision) }
        external = @record.checks.count(&:external?)
        parts = []
        if located.positive?
          parts << "#{located} new manual change(s) found in this application and not applied"
        end
        parts << "#{earlier} earlier-rung call site(s) still open" if earlier.positive?
        unless @record.refused.empty?
          parts << "#{@record.refused.length} edit(s) refused because the line moved"
        end
        parts << "#{external} external check(s) that this walk did not run" if external.positive?
        if parts.empty?
          "low — the suite and every declared required check passed, and no manual change was " \
            "found in this application"
        else
          "medium — #{parts.join("; ")}. The diff is the mechanical half; read the sections above " \
            "before merging"
        end
      end

      def rollback
        base = base_commit
        head = delivered_head.to_s
        if !base.empty? && !head.empty? && base != head
          "before merge, `git reset --hard #{short(base)}` discards the rung; after merge, " \
            "`git revert --no-commit #{short(base)}..#{short(head)} && git commit` reverts every " \
            "concern commit in one revert"
        elsif !head.empty?
          "`git revert #{short(head)}`"
        else
          "revert the branch's commit, or reset the branch to its base"
        end
      end

      def merge_order
        base =
          if !@base.to_s.empty?
            "`#{@base}`"
          elsif !@base_ref.to_s.empty?
            "`#{@base_ref}` (the declared starting point)"
          else
            "the repository's default branch"
          end
        if @record&.commits.to_a.length > 1
          "this request targets #{base}; merge it after that branch, and keep the concern commits " \
            "in the order listed above"
        else
          "this request targets #{base}; merge that branch first"
        end
      end

      def run_url
        return nil if @report_base.empty?

        id = @record&.run_id.to_s
        if id.empty?
          "#{@report_base}/site_admin/upgrade_runs"
        else
          "#{@report_base}/site_admin/upgrade_runs/#{id}"
        end
      end

      # **The evidence, collapsed.** A reviewer who wants it can read every stage, every command and
      # the full check list; the brief above is what a person needs first. The patch is deliberately
      # left out: the pull request's diff is the patch, and pasting it into the body would be a
      # second copy that can disagree.
      def record_section
        json = JSON.pretty_generate(scrubbed(public_record))
        if json.length > 24_000
          json = "#{json[0, 24_000]}\n… (truncated; the run's page has the whole record)"
        end
        lines = ["<details>", "<summary>Full run record</summary>", "",
          "The patch is this pull request's diff and is omitted here. Command and check output,",
          "repair attempt output and repair diffs are omitted from this body — the run's page",
          "has them, and a public pull request does not need to carry a suite's environment.",
          "", "```json", json, "```",
          "", "</details>"]
        lines.join("\n")
      end

      # **The record as a public page may carry it.** A stage's `command` is the machine's wrapper
      # and can contain `-e RAILS_SECRET_TOKEN=…`; its `output_tail` can contain whatever the suite
      # printed. The logical command (`display`) and the exit code are the evidence a reviewer needs,
      # and the run's page is where the wrapper and the output live. This is a filter, not a promise
      # that the record is safe in general: a project's own values never enter the body.
      def public_record
        record = @record.to_h.reject { |key, _| key == "patch" }
        record["stages"] = Array(record["stages"]).map { |stage| public_command(stage) }
        %w[baseline suite].each do |key|
          record[key] = public_command(record[key]) if record[key].is_a?(Hash)
        end
        # **A check's output is command output too.** `Checks::Result#to_h` carries the tail, and a
        # failing suite's tail is exactly where the application's environment shows up.
        record["checks"] = Array(record["checks"]).map do |check|
          check.is_a?(Hash) ? check.reject { |key, _| key == "output_tail" } : check
        end
        record["repairs"] = public_repairs(record["repairs"])
        record
      end

      # A repair's attempts are the failing suite's output and a diff of the fix. The body says a
      # repair happened; the run's page has the evidence. Keeping the attempt count and the files
      # is enough for a reviewer, and it cannot leak a suite's environment.
      def public_repairs(repairs)
        Array(repairs).map do |repair|
          next repair unless repair.is_a?(Hash)

          copy = repair.dup
          # The failure is the failing suite's output (`Repair::Outcome#failure` is
          # `subject.output_tail`), so it is command output like the attempts' tails.
          copy.delete("failure")
          copy.delete("diff")
          # A real outcome carries an attempt *count*; a hand-built or older record may carry the
          # attempt objects. Keep the count as it is, and sanitize only the list form.
          if repair["attempts"].is_a?(Array)
            copy["attempts"] = repair["attempts"].map do |attempt|
              if attempt.respond_to?(:to_h)
                # A `Struct#to_h` has symbol keys; the JSON that follows has strings. Compare the
                # name, not the key's class, or the tail survives the filter under `:output_tail`.
                attempt.to_h.reject { |key, _| %w[output_tail diff].include?(key.to_s) }
              else
                # An attempt that came back through JSON is a string (a Struct is not a hash), and
                # that string is the Struct's inspect form — which contains the tail. Drop it rather
                # than publish it.
                "[attempt output omitted]"
              end
            end
          end
          copy
        end
      end

      def public_command(command)
        copy = command.dup
        copy["command"] =
          if copy["display"].to_s != ""
            copy["display"]
          else
            redact_environment(copy["command"])
          end
        copy.delete("output_tail")
        copy
      end

      # A stage's command as a public body may print it: the application's own argv when the record
      # kept one, and otherwise the recorded command with every `-e KEY=VALUE` value removed. The
      # suite's environment is the case this exists for; a container id is not a secret.
      def public_stage_command(stage)
        display = stage.respond_to?(:display) ? stage.display.to_s : ""
        return display unless display.empty?

        redact_environment(stage.respond_to?(:command) ? stage.command : stage.to_s)
      end

      def redact_environment(command)
        command.to_s.gsub(/(?<=\s)-e\s+([A-Z][A-Z0-9_]*)=\S+/, '-e \1=***')
      end

      def scrubbed(value)
        case value
        when String then value.scrub
        when Hash then value.transform_values { |item| scrubbed(item) }
        when Array then value.map { |item| scrubbed(item) }
        else value
        end
      end

      def delivered_head
        @publishing_commit.to_s.empty? ? @commit.to_s : @publishing_commit.to_s
      end

      # The commit the rung arrived at. A delivery retry has no record and no base it can name —
      # the branch is already the produced commit — so it says nothing rather than calling the
      # head the base.
      def base_commit
        @record.nil? ? "" : @record.commit.to_s
      end

      def short(commit) = commit.to_s[0, 8]

      # The service writes this sentence into a decision it located for a rung this application has
      # not crossed. It is the only field that separates "this rung's work" from "the residue of an
      # earlier one", and the PR must not present the second as the first.
      def carried_earlier?(decision)
        decision.reason.to_s.include?("carried by an earlier rung")
      end

      # A markdown table cell cannot carry an unescaped pipe; a command with one would split the row.
      def escape_cell(text) = text.to_s.gsub("|", "\\|")

      # The evidence lines, from the stages the record actually ran. A line per thing a
      # reviewer would otherwise have to take on trust.
      def evidence
        found = []
        if @record.machine.to_s != ""
          found << "interpreter: `#{@record.interpreter}`#{@record.image.to_s.empty? ? "" : " (#{@record.image})"}"
        end
        @record.stages.each do |stage|
          next unless %w[baseline suite boot].include?(stage.stage)

          # **The logical command, not the machine's wrapper.** `display` is the application's own
          # argv; `command` carries the container, the environment and — for the suite — the
          # application's secret. A pull request is public, so the body reads the display, and an
          # old record without one still gets its `-e KEY=VALUE` pairs redacted.
          found << "#{stage.stage}: `#{public_stage_command(stage)}` — " +
            (stage.ran ? "exit #{stage.exit_code} in #{stage.seconds.round(1)}s" : "did not run")
        end
        found.empty? ? ["no stage evidence was recorded"] : found
      end

      # Every message on its way out, with the token taken out of it. Git's own errors
      # quote the remote URL, and the remote URL carries the token.
      def redact(message)
        return message if @token.empty?

        message.to_s.gsub(@token, "***")
      end

      # The GitHub half, as one method: open a pull request for a branch, or update the one
      # that is already open for it.
      #
      # Idempotence is the point rather than a nicety. A rung walked twice — a re-run after
      # a fixed repair, a force-push after a rebase — must not fail with "already exists"
      # and must not open a second request for the same branch, so a 422 whose body says a
      # request exists is read as "find it and update it".
      class GitHub
        API = "https://api.github.com"
        OPEN = "open"

        class Refused < StandardError; end

        def initialize(token:, http: Net::HTTP, api: API)
          @token = token
          @http = http
          @api = api
        end

        def default_branch(owner:, name:)
          body = call(:get, "/repos/#{owner}/#{name}")
          body["default_branch"].to_s.empty? ? "main" : body["default_branch"].to_s
        end

        # Returns the pull request's URL.
        def pull_request(owner:, name:, head:, base:, title:, body:)
          existing = find_open(owner: owner, name: name, head: head)
          if existing
            updated = call(:patch, "/repos/#{owner}/#{name}/pulls/#{existing["number"]}",
              { "title" => title, "body" => body, "base" => base })
            return updated["html_url"].to_s
          end

          opened = call(:post, "/repos/#{owner}/#{name}/pulls",
            { "title" => title, "body" => body, "head" => head, "base" => base })
          opened["html_url"].to_s
        end

        private

        def find_open(owner:, name:, head:)
          found = call(:get, "/repos/#{owner}/#{name}/pulls",
            nil, { "head" => "#{owner}:#{head}", "state" => OPEN })
          Array(found).find { |row| row.is_a?(Hash) }
        end

        def call(method, path, payload = nil, query = nil)
          uri = URI.parse("#{@api}#{path}")
          uri.query = URI.encode_www_form(query) if query
          request = case method
          when :post then Net::HTTP::Post.new(uri)
          when :patch then Net::HTTP::Patch.new(uri)
          else Net::HTTP::Get.new(uri)
          end
          request["Accept"] = "application/vnd.github+json"
          request["Authorization"] = "Bearer #{@token}"
          if payload
            request["Content-Type"] = "application/json"
            request.body = JSON.generate(payload)
          end

          response = @http.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.request(request)
          end
          body = parse(response.body)
          code = response.code.to_i
          return body if code >= 200 && code < 300

          raise Refused, sentence(body, code, path)
        rescue SocketError, SystemCallError, Timeout::Error => e
          raise Refused, "could not reach #{@api}: #{e.class}: #{e.message}"
        end

        def parse(body)
          JSON.parse(body.to_s)
        rescue JSON::ParserError
          nil
        end

        def sentence(body, code, path)
          message = body.is_a?(Hash) ? body["message"].to_s : ""
          "#{@api}#{path} answered #{code}" \
            "#{message.empty? ? "" : ": #{message}"}"
        end
      end
    end
  end
end
