# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "uri"
require "digest"

module Agents
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
    #   guide's rule — so `agents/upgrade-4.1.0` carries the 4.1 rung and nothing else,
    #   and the pull request for it targets the *previous rung's branch*
    #   (`agents/upgrade-4.0.0`) when that branch exists and the repository's default
    #   branch when it does not. That is what makes the requests chain: GitHub shows the
    #   4.1 diff against 4.0, so a reviewer reads one rung's worth of change instead of
    #   every rung at once.
    # * **Only a passing step is published.** The same rule as the checkpoint, one layer
    #   out: a branch is a claim that this rung works, and a `failed`/`unverified` record
    #   has not established that. This class therefore does not decide *whether* to
    #   publish — its caller does, from the verdict — but it re-states the check for the
    #   callers that forget.
    # * **The token is never written down.** It arrives from the caller — `step --publish` reads
    #   `UPGRADER_GITHUB_TOKEN`, and the loop passes the service's short-lived credential — it is
    #   used in the push URL, and every message on the way out has it replaced with `***`.
    #   A token in a record is a token in a corpus, and this record is published beside the
    #   run.
    #
    # **The branch base is the relationship, and GitHub's stack is the association beside it.** A
    # checkpoint's request targets the previous checkpoint's branch, which is what makes each
    # rung's diff reviewable on its own; since October 2026 GitHub also lets the same chain be a
    # first-class *stack*, with a stack map and a merge that lands the layers together. The client
    # asks for the association mechanically after opening the request — create the stack from the
    # previous request and this one, or append this one to the stack the previous request is in —
    # and a refusal from that half is a line in the log, not a failed delivery: the branch and the
    # chain of bases are what the walk needs, and the stack is what a reviewer sees.
    #
    # The delivery record carries the `base` the request actually used, which is how a reader can
    # tell a chained request from one that fell back to the repository's default branch — the
    # visible shape of a chain that broke, including when an earlier request in the stack was closed
    # before this rung was published — and the `stack` it joined when GitHub accepted one.
    #
    # **The stack is the chain, and a link missed once is repaired by the next rung.** A stack was
    # created from the request immediately below and nothing else, so a single refused association
    # - a 409 while GitHub modified the stack, a resolver that answered nothing - left that layer
    # loose for the rest of the walk, and the rung above it started a *second* stack from the loose
    # pair: measured on diaspora, 7.0.10/7.1.6/7.2.4 in stack 11 and 8.0.5.1/8.1.4 in stack 15. The
    # walk now follows the bases down to the first request that is already in a stack and appends
    # every loose layer above it in one call, so one transient refusal is a rung that looks
    # ordinary rather than a walk a reviewer has to merge in two pieces.
    class Publish
      # Where a one-shot step's token comes from. `serve` passes the service's short-lived
      # credential instead; the CLI reads this name for `step --publish`.
      ENV_TOKEN = "UPGRADER_GITHUB_TOKEN"

      # The namespace a branch lives under when the project declares none. Load-bearing for two
      # reasons: a re-run of the same rung updates one branch instead of opening a second one, and
      # `push --force` is only ever used inside a namespace this tool owns. A project may name its
      # own pattern (`Project::Delivery#branch`, with `<release>` substituted), because a fork or a
      # second project should not have to publish into this one's namespace.
      DEFAULT_BRANCH = "agents/upgrade-<release>"

      # What publishing did, in one value. `pushed` and `pull_request` are separate because
      # they fail separately: a branch can reach the remote and the API refuse to open a
      # request for it.
      Result = Struct.new(:pushed, :branch, :base, :commit, :pull_request, :stack, :reason,
        :body_updated, keyword_init: true) do
        def published? = pushed && !pull_request.to_s.empty?

        # **A body that was not written is not a failed delivery.** The branch and the request are
        # the delivery; a guard that declined to overwrite a person's edit says so in `reason` and
        # leaves the delivery successful.
        def body_updated? = body_updated != false

        def to_h
          { "pushed" => pushed, "branch" => branch, "base" => base, "commit" => commit,
            "pull_request" => pull_request, "stack" => stack, "reason" => reason,
            "body_updated" => body_updated? }
        end

        def to_s
          if published?
            "published: #{branch} -> #{pull_request}" \
              "#{stack.to_s.empty? ? "" : " (stack #{stack})"}" \
              "#{body_updated? ? "" : " (body not updated: #{reason})"}"
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
                     report_base: nil, base_ref: nil, chain: true, deploy: [],
                     editorial: nil, expected_body_digest: nil, base: nil)
        @root = root
        @repository = repository.to_s
        @from_version = from_version.to_s
        @to_version = to_version.to_s
        @record = record
        # **The model's lead, when there is one.** The deterministic body is composed first and the
        # editorial is prepended; the evidence sections below it are still the record's. An empty
        # editorial is the no-model path, not a different body shape.
        @editorial = editorial.to_s
        # **The body the publisher last wrote, for a maintenance update.** A republish may only
        # replace a body that still matches this digest; a person's edit is the owner's now.
        @expected_body_digest = expected_body_digest.to_s
        # The base recorded on the delivery, so a body-only update names the same base the first
        # publication did instead of asking the remote a second time.
        @given_base = base.to_s
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
        # project declares `base_ref` (`agents/baseline` for the lighthouse); the first rung has
        # no previous rung's branch to chain to, and falling back to `master` put the baseline's own
        # view fixes into the 4.1 diff. Later rungs still use the previous rung's branch.
        @base_ref = base_ref.to_s
        # **A declaration may turn the chain off.** With `delivery.chain` false every request
        # targets the declared starting ref (or the repository's default), which is the shape a
        # project wants when it reviews one cumulative branch; with it on — the default — each
        # checkpoint stacks on the one below it.
        @chain = chain != false
        # The profile's deploy facts, named for the customer and never run by this tool.
        @deploy = Array(deploy).map(&:to_s).reject(&:empty?)
      end

      # `open_pr: false` is the account's `publish: branch` mode: the branch is the handoff and no
      # request is opened. The push is still the same claim that the rung works.
      def call(open_pr: true)
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

        # **A body-only update never overwrites a person's edit.** The delivery records the digest
        # of the body the walker wrote; if GitHub holds different bytes, someone has taken ownership
        # of the request's prose and this pass leaves it alone. The branch is already delivered, so
        # the result is a successful delivery with `body_updated: false`.
        if @expected_body_digest != ""
          existing = api.pull_request_for(owner: owner, name: name, head: branch)
          if existing && Digest::SHA256.hexdigest(existing["body"].to_s) != @expected_body_digest
            return Result.new(pushed: true, branch: branch,
              base: existing.dig("base", "ref").to_s, commit: @commit,
              pull_request: existing["html_url"].to_s,
              reason: "the pull request body was edited after the delivery, so this republish " \
                      "left it alone", body_updated: false)
          end
        end

        commit = publish_commit
        @publishing_commit = commit
        pushed, pushed_why = push(commit)
        return Result.new(pushed: false, branch: branch, commit: commit, reason: pushed_why) unless pushed

        @base = base_branch
        unless open_pr
          return Result.new(pushed: true, branch: branch, base: @base, commit: commit,
            reason: "branch-only delivery: the account's publish mode is branch")
        end
        request = request_pull_request(
          owner: owner, name: name, head: branch, base: @base,
          title: title, body: body
        )
        @pull_request_url = request["html_url"].to_s
        # **The base the request has, not only the one this asked for.** A stacked request cannot
        # have its base changed, so the record has to carry GitHub's answer rather than the guess.
        actual = request["base"].to_s
        @base = actual unless actual.empty?
        Result.new(pushed: true, branch: branch, base: @base, commit: commit,
          pull_request: @pull_request_url, stack: link_stack, reason: "")
      rescue GitHub::Refused => e
        # **The push can succeed while the request fails, and the retry needs both facts.** The
        # first version returned `pushed: false` with no commit here, so the next cycle re-derived
        # the branch from a tree the caller had already moved on from. The branch and its commit
        # are facts about this attempt even when the pull request never opened.
        Result.new(pushed: false, branch: branch, base: @base,
          commit: @publishing_commit, reason: redact(e.message))
      end

      # **The body without a push.** `Preview` is the caller: a stored record is already the whole
      # evidence, and rendering it should not need a checkout or a token. The method is public so a
      # dry run is an ordinary call rather than a test's `send`.
      def preview_body = body

      def preview_title = title

      # **A maintenance update of an existing request.** The branch and its commit are already on
      # the remote; this finds the request, refuses to replace a body a person edited, and PATCHes
      # the title and body only. It does not commit, push or move a base, which is what makes a
      # presentation apply cheap and safe after the walk has moved on.
      def update_only(current_base: nil, expected_body_digest: nil)
        digest = expected_body_digest.to_s
        digest = @expected_body_digest if digest.empty?
        unless github?
          return Result.new(pushed: true, branch: branch, commit: @commit, body_updated: false,
            reason: "the repository is not on github.com, so there is no pull request to update")
        end
        if @token.empty?
          return Result.new(pushed: true, branch: branch, commit: @commit, body_updated: false,
            reason: "no GitHub token, so the pull request body was not updated")
        end

        existing = api.pull_request_for(owner: owner, name: name, head: branch)
        if existing.nil?
          return Result.new(pushed: true, branch: branch, commit: @commit, body_updated: false,
            reason: "no pull request was found for #{branch}, so there was no body to update")
        end

        base = current_base.to_s
        base = existing.dig("base", "ref").to_s if base.empty?
        @base = base
        if digest != "" && Digest::SHA256.hexdigest(existing["body"].to_s) != digest
          return Result.new(pushed: true, branch: branch, base: base, commit: @commit,
            pull_request: existing["html_url"].to_s, body_updated: false,
            reason: "the pull request body was edited after the delivery, so it was left alone")
        end

        updated = api.settle(owner: owner, name: name, number: existing["number"],
          base: existing.dig("base", "ref").to_s, title: existing["title"].to_s, body: body,
          current: existing.dig("base", "ref").to_s)
        Result.new(pushed: true, branch: branch, base: updated["base"].to_s,
          commit: @commit, pull_request: updated["html_url"].to_s, body_updated: true, reason: "")
      rescue GitHub::Refused => e
        Result.new(pushed: true, branch: branch, commit: @commit, body_updated: false,
          reason: redact(e.message))
      end

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
        return @given_base unless @given_base.empty?
        return configured_base unless @chain

        previous = self.class.branch_for(@from_version, pattern: @branch_pattern)
        return previous if remote_has?(previous)
        return @base_ref if !@base_ref.empty? && remote_has?(@base_ref)

        configured_base
      end

      # The branch a stack starts on: the declared starting ref when the remote has it, and the
      # repository's own default otherwise.
      def configured_base
        return @base_ref if !@base_ref.empty? && remote_has?(@base_ref)

        remote_default_branch || api_default_branch || "main"
      end

      # **The chain gets GitHub's own stack object when the repository supports it.** The base
      # branch is still the relationship — the stack API only associates requests that already
      # point at each other — but the association is what draws the stack map and lets a reviewer
      # land the layers in one merge. Created on the second request and extended on every one
      # after it, because a stack needs two layers to exist. A refusal from this half is a line
      # in the log rather than a failed delivery: the branch and its base are the product.
      # **Retried, and the retry re-reads before it writes.** The association is a network call
      # too, and the one measured failure — diaspora's 8.0.5.1 layer — was a single refusal that
      # cost the walk its stack. Re-reading first is what keeps a retry that follows a *successful*
      # write from creating the second stack this exists to avoid.
      def link_stack
        return "" unless @chain
        # **Only a layer this walker built can sit on another.** `@base` is the previous
        # checkpoint's branch only when the remote had it; a first request, a declared starting
        # ref or a default branch is the bottom of the stack even if an unrelated request happens
        # to have that branch as its head.
        return "" unless @base == self.class.branch_for(@from_version, pattern: @branch_pattern)

        attempts = 0
        begin
          attempts += 1
          link_stack_once
        rescue GitHub::Refused => e
          if attempts < PUSH_ATTEMPTS
            @out&.puts("publish: the stack could not be linked (#{redact(e.message)}) — retrying")
            @pause.call(PUSH_BACKOFF_SECONDS * attempts)
            retry
          end

          @out&.puts("publish: the pull request opened, but GitHub would not stack it: " \
                     "#{redact(e.message)}")
          ""
        end
      end

      def link_stack_once
        number = pull_request_number
        return "" if number.zero?

        current = api.stack_for(owner: owner, name: name, pull_request: number)
        return current["url"].to_s if current

        below, stack = stack_below(number)
        return "" if below.empty? && stack.nil?

        # Bottom to top: every loose layer between the stacked one and this request, then this
        # request. `add` and `create` both take the list that way round.
        layers = below.reverse + [number]
        linked = if stack
          api.add_to_stack(owner: owner, name: name, stack_number: stack["number"],
            pull_requests: layers)
        else
          api.create_stack(owner: owner, name: name, pull_requests: layers)
        end
        linked.is_a?(Hash) ? linked["url"].to_s : ""
      end

      # **Walk the bases down until one of them is in a stack.** The request immediately below is
      # the common answer, but it is not the answer after a link was missed: the layer below this
      # one is loose while the layer below *it* is stacked, and only the whole list rejoins the map
      # in one call. `below` is nearest-first; the caller reverses it, because the API takes a
      # stack bottom-up.
      #
      # The walk stops at the namespace this walker publishes into. A base that is `develop` — or
      # any branch somebody else made — is the bottom of the chain, not an invitation to adopt an
      # unrelated request that happens to sit on it.
      def stack_below(number)
        below = []
        seen = [number]
        head = @base
        prefix = @branch_pattern.split("<release>").first.to_s

        STACK_CHAIN_LIMIT.times do
          request = api.pull_request_for(owner: owner, name: name, head: head)
          break if request.nil? || request["state"] == "closed"

          found = request["number"].to_i
          break if found.zero? || seen.include?(found)

          seen << found
          stack = api.stack_for(owner: owner, name: name, pull_request: found)
          return [below, stack] if stack

          below << found
          head = request.dig("base", "ref").to_s
          break unless !prefix.empty? && head.start_with?(prefix)
        end
        [below, nil]
      end

      def pull_request_number = @pull_request_url.to_s[%r{/pull/(\d+)}, 1].to_i

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
      # the deployment: `agents/upgrade-4.1.0` pushed and opened its pull request, and the next
      # rung's push answered `fatal: unable to access … Could not resolve host: github.com` — the rung
      # *passed*, the branch was never created, and the hole is permanent because the loop never
      # revisits a passed rung (`settled?`). A transient failure clears on a second attempt; a
      # permanent one — no permission, a rejected ref — reports the same reason after the last, so the
      # retry costs two attempts and buys back a rung's delivery.
      PUSH_ATTEMPTS = 3

      # Seconds before the second attempt, doubled for the third. Short: a resolver that was not
      # answering a moment ago is the case this is for, and a walk is not waiting on it.
      PUSH_BACKOFF_SECONDS = 5

      # How much of a single applied edit's text the public record carries. A Gemfile line and a
      # route are well under this; a file a decision wrote is far over it.
      PUBLIC_EDIT_CHARS = 400

      # How many bases the stack walk follows before it gives up. The ladder is thirteen steps and
      # a walk may restart, so this is a guard against a cycle in GitHub's answers rather than a
      # product bound: a chain longer than this is not one this tool built.
      STACK_CHAIN_LIMIT = 25

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
        "Upgrade Rails to #{@to_version} (agents)"
      end

      # **The review brief, not a run log.** A reviewer's questions are: what moved, what established
      # it, what is different in *this* application, what did the tool decide, what is left for me,
      # and is it safe to merge. The run record is below, collapsed, because it is the evidence and
      # not the first thing a person should have to read. Every line is composed from the record, so
      # the request cannot say something the record does not.
      def body
        [@editorial, deterministic_body].reject(&:empty?).join("\n\n")
      end

      # The record's review brief, without the model's lead. Kept separate so a body-only update
      # can compose the same evidence the first publication did and a test can hold the two halves
      # to their own promises.
      def deterministic_body
        sections = [moved_section]
        sections << checks_section
        sections << brief_section if @record&.brief
        sections << changed_section if @record
        sections << decisions_section if @record
        sections << app_update_section if @record
        sections << manual_section if @record
        sections << canary_section if @record
        sections << merge_section
        sections << record_section if @record
        sections.join("\n\n")
      end

      def moved_section
        # The record's `from_version` is the ladder's rung (`4.0.0`); the project's own
        # `from` is the release the repository actually pinned (`4.0.0.rc1`). The body is
        # read as a statement about this repository, so it names the lockfile's release
        # and leaves the rung's normalized number to the ladder.
        from = @record&.project.is_a?(Hash) ? @record.project["from"].to_s : ""
        from = @from_version if from.empty?
        lines = ["## What moved", ""]
        lines << "`agents` walked one rung of the Rails ladder: **#{from} → #{@to_version}**."
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
          result = check_result(check)
          what = check.external? ? check.reason.to_s : "`#{check.command}`"
          # **A pre-existing failure names both runs.** The row says the base commit already
          # failed it, and the reason carries the base exit code, so a reviewer reads which red
          # belongs to whom instead of a bare `failed` under a passed verdict.
          what = "#{what} — #{check.reason}" if check.preexisting? && check.reason
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

      # The one vocabulary the checks table speaks. `external` and `preexisting` are two different
      # reasons a check is not green here, and neither of them is a failure of this rung.
      def check_result(check)
        return "external — not run here" if check.external?
        return "pre-existing — not this rung's" if check.preexisting?

        check.status.tr("_", " ")
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

        # **The pin that succeeded, not the first attempt.** A widening spends a round per
        # conflict: the 4.1 rung's first two pin stages exited 6 and the sixth succeeded,
        # and `find` quoted the failure as *the* pin. A reviewer read a failed command
        # under a `passed` verdict. The last successful stage is the fact; the failed
        # attempts remain in the full run record.
        pins = @record.stages.select { |stage| stage.stage == Record::PIN }
        pin = pins.reverse.find(&:ok?) || pins.last
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
          # The preflight's repairs are the application's own old Gemfile: a dead protocol,
          # a fork that no longer exists, a line a gem's release moved. They are not the
          # service's scan, and the 4.1 body's “30 from the service's scan” read as source
          # edits when every one of them was a dependency line.
          parts << "#{counts['preflight']} from the preflight" if counts["preflight"].positive?
          parts << "#{counts['app_update']} from app:update reconciliation" if counts["app_update"].positive?
          parts << "#{counts['rule']} from this tool's own rules" if counts["rule"].positive?
          parts << "#{counts['companion']} from gems' own upgrades" if counts["companion"].positive?
          parts << "#{counts['']} from the service's scan and routing" if counts[""].positive?
          lines << ""
          # **This sentence is kept word for word**: it is what a reader uses to tell a mechanical
          # rung from one an accepted decision shaped, and the tests hold it.
          lines << "The tool wrote #{@record.applied.length} edit(s): #{parts.join(", ")}. The diff " \
                   "is the complete record; every edit and its reason is in the full record below."
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
          if decision["accepted_by_policy"] == true
            review = decision["review"].is_a?(Hash) ? decision["review"] : {}
            lines << "**Accepted by the account's policy**, not a person. Auto class " \
                     "`#{decision["risk_class"]}`; reviewer `#{review["verdict"]}` " \
                     "(#{review["agent"]}/#{review["model"]}). " \
                     "#{Array(decision["effects"]).length} effect(s) in force."
          else
            lines << "Accepted by `#{decision["accepted_by"]}`; " \
                     "#{Array(decision["effects"]).length} effect(s) in force."
          end
          lines << "The suite ran with them in place."
          lines << ""
        end
        unless decided.empty?
          lines << "The edits these decisions made:"
          lines << ""
          decided.group_by(&:origin).each do |origin, edits|
            lines << "### `#{origin}`"
            edits.each { |edit| lines << "- #{edit_sentence(edit)}" }
          end
        end
        lines.join("\n")
      end

      # **A file a decision wrote is a whole file, not a line to quote.** The first version rendered
      # every edit as `` `before` → `after` ``, which pasted the contents of nine vendored files into
      # diaspora's 8.0.5.1 request: a backtick inside the content closed the span, a newline ended it,
      # and everything after the first file became unreadable markdown. The diff is where content
      # belongs; the body names the file and, for a whole file, its size.
      def edit_sentence(edit)
        before = edit.text.to_s
        after = edit.after.to_s
        name = "`#{edit.path}`"
        location = edit.line.nil? ? name : "#{name}:#{edit.line}"

        return "#{name} — added by the decision (#{after.lines.count} line(s))" if before.strip.empty?
        return "#{location} — rewritten by the decision (#{after.lines.count} line(s))" if
          before.include?("\n") || after.include?("\n")
        return "#{location} — changed (the line itself carries a backtick)" if
          before.include?("`") || after.include?("`")

        "#{location} `#{before.strip}` → `#{after.strip}`"
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
        reconciled = Array(update["reconciled"])
        unless reconciled.empty?
          lines << ""
          lines << "### Reconciled with the application's own"
          lines << ""
          reconciled.first(15).each do |entry|
            lines << "- `#{entry["path"]}` — #{entry["note"]}"
          end
          lines << "- …and #{reconciled.length - 15} more in the run record" if reconciled.length > 15
        end
        # **A generated default is not a migration.** The two files this rung adds most often —
        # `cookies_serializer.rb` (`:json` in a new app) and `secrets.yml` — are written by the
        # release for a new application. The reconciliation above is this application's answer;
        # what remains is the deployment keeping one key across the merge.
        lines << ""
        if reconciled.empty?
          lines << "These are the release's generated defaults, not a migration. An application " \
                   "with a `secret_token.rb` and live cookies must keep the same `secret_key_base` " \
                   "across the deploy and review the cookie serializer transition before merging."
        else
          lines << "The generated defaults above were reconciled with the application's own " \
                   "settings; the deployment must still keep the same `secret_key_base` across " \
                   "the merge, and the next rung completes the cookie serializer transition where " \
                   "this one set up `:hybrid`."
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
                   "They need no edit; the operator's record lists them."
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
      # **The customer's release gate, named rather than claimed.** The walker did not deploy and
      # cannot canary; what it can do is say which parts of the application changed and which
      # declared CI/deploy steps are the customer's to run.
      def canary_section
        paths = Array(@record.applied).filter_map do |edit|
          next nil unless edit.respond_to?(:path)

          text = edit.path.to_s
          text.empty? ? nil : text
        end.uniq
        external = Array(@record.checks).select do |check|
          check.respond_to?(:external?) ? check.external? : check["external"] == true
        end
        return "" if paths.empty? && external.empty? && @deploy.empty?

        groups = Hash.new { |hash, key| hash[key] = [] }
        paths.each do |path|
          group = case path
                  when %r{\Aapp/controllers/}, "config/routes.rb" then "HTTP endpoints"
                  when %r{\Aapp/(jobs|workers)/}, "config/sidekiq.yml" then "background jobs"
                  when %r{\Adb/migrate/} then "database migrations"
                  when "Gemfile", "Gemfile.lock" then "dependencies and native extensions"
                  when %r{\Aconfig/} then "runtime configuration"
                  when %r{\A(app/models|app/services|lib)/} then "domain behavior"
                  else "other application files"
                  end
          groups[group] << path
        end

        lines = ["## What to canary", ""]
        lines << "The agent did not deploy. Your CI, deploy and canary are the release gate."
        lines << ""
        groups.each do |group, list|
          shown = list.first(6).join(", ")
          shown += " (+#{list.length - 6} more)" if list.length > 6
          lines << "- **#{group}** — #{shown}"
        end
        unless external.empty?
          lines << ""
          lines << "Your CI checks (not run here):"
          external.first(10).each do |check|
            name = check.respond_to?(:name) ? check.name : check["name"]
            reason = check.respond_to?(:reason) ? check.reason : check["reason"]
            lines << "- #{name}#{reason.to_s.empty? ? "" : " — #{reason}"}"
          end
        end
        unless @deploy.empty?
          lines << ""
          lines << "Your deploy steps (named by the profile, not run here):"
          @deploy.first(10).each { |step| lines << "- `#{step}`" }
        end
        lines.join("\n")
      end

      def merge_section
        lines = ["## Review and merge", ""]
        lines << "- **Risk:** #{risk}"
        lines << "- **Rollback:** #{rollback}"
        lines << "- **Merge order:** #{merge_order}"
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
          "low for the compatibility change measured here — the suite passed, no additional " \
            "required check is declared, and no manual change was found in this application. " \
            "This is the rung's compatibility verdict, not a production-readiness or security " \
            "review: the target is the ladder's release, and a deployment still has to decide " \
            "what it will run."
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
          "this request targets #{base}; it is the branch this rung builds on. Keep the concern " \
            "commits in the order listed above"
        else
          "this request targets #{base}; it is the branch this rung builds on"
        end
      end

      # **The evidence, collapsed.** A reviewer who wants it can read every stage, every command and
      # the full check list; the brief above is what a person needs first. The patch is deliberately
      # left out: the pull request's diff is the patch, and pasting it into the body would be a
      # second copy that can disagree.
      def record_section
        json = JSON.pretty_generate(scrubbed(public_record))
        if json.length > 24_000
          json = "#{json[0, 24_000]}\n… (truncated; the operator's record has the whole record)"
        end
        lines = ["<details>", "<summary>Full run record</summary>", "",
          "The patch is this pull request's diff and is omitted here. Command and check output,",
          "repair attempt output and repair diffs are omitted from this body — the operator's record",
          "has them, and a pull request does not need to carry a suite's environment.",
          "", "```json", json, "```",
          "", "</details>"]
        lines.join("\n")
      end

      # **The record as a public page may carry it.** A stage's `command` is the machine's wrapper
      # and can contain `-e RAILS_SECRET_TOKEN=…`; its `output_tail` can contain whatever the suite
      # printed. The logical command (`display`) and the exit code are the evidence a reviewer needs,
      # and the operator's record is where the wrapper and the output live. This is a filter, not a promise
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
        # **A whole file is not a line of evidence a pull request can carry.** `applied` includes the
        # `after` of every edit, and a decision's `file` effect is the whole file: diaspora's 8.0.5.1
        # body pasted nine vendored files into its collapsed record, and the content is also what
        # broke the markdown above it. The diff is the content; the record keeps the path and the
        # size, which is what a reader checks the diff against.
        record["applied"] = Array(record["applied"]).map { |edit| public_edit(edit) }
        # **A decision's file effect carries the file too.** The record needs the content to replay
        # the decision; the body does not, and it is what put nine vendored files into the collapsed
        # record even after the visible edit list stopped quoting them.
        record["accepted_decisions"] = Array(record["accepted_decisions"]).map do |decision|
          public_decision(decision)
        end
        # **The project declaration carries the same decisions a second time.** `project` is the
        # queue's own JSON, and its `decisions` list repeats the effects — so scrubbing only
        # `accepted_decisions` left every file in the body under this copy.
        record["project"] = public_project(record["project"])
        record
      end

      def public_project(project)
        return project unless project.is_a?(Hash)

        copy = project.dup
        if copy["decisions"].is_a?(Array)
          copy["decisions"] = copy["decisions"].map { |decision| public_decision(decision) }
        end
        copy
      end

      def public_decision(decision)
        return decision unless decision.is_a?(Hash)

        copy = decision.dup
        copy["effects"] = Array(decision["effects"]).map do |effect|
          next effect unless effect.is_a?(Hash) && effect["payload"].is_a?(Hash)

          payload = effect["payload"].dup
          if payload.key?("content")
            payload["content"] = "[#{payload["content"].to_s.lines.count} line(s); the diff carries it]"
          end
          effect.merge("payload" => payload)
        end
        copy
      end

      # A one-line edit is evidence and stays readable. A multi-line edit — a file a decision wrote
      # or rewrote — is replaced by its size, because the pull request's diff already carries it and
      # a body is not a second copy of a tree.
      def public_edit(edit)
        return edit unless edit.is_a?(Hash)

        copy = edit.dup
        before = copy["text"].to_s
        after = copy["after"].to_s
        return copy unless before.include?("\n") || after.include?("\n") ||
          after.length > PUBLIC_EDIT_CHARS

        copy["text"] = nil
        copy["after"] = "[#{after.lines.count} line(s); the diff carries it]"
        copy
      end

      # A repair's attempts are the failing suite's output and a diff of the fix. The body says a
      # repair happened; the operator's record has the evidence. Keeping the attempt count and the files
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
        # **The compile after the pin is the one that proves the delivered bundle.** The
        # first `assets` stage runs before the pin; listing it alone would repeat the 4.1
        # rung's false positive. The last stage is the post-pin compile, and it is evidence
        # a reviewer needs because the suite does not render assets.
        assets = @record.stages.select { |stage| stage.stage == Record::ASSETS }
        unless assets.empty?
          stage = assets.last
          found << "assets (last compile): `#{public_stage_command(stage)}` — " +
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
        # **The request as GitHub now holds it.** `html_url` is what a delivery records; `base` is
        # the base it *actually* has, which is not always the one asked for: a stacked request's
        # base may not be changed at all (see below), and a caller that recorded its own guess
        # would publish a base the request does not sit on.
        def pull_request(owner:, name:, head:, base:, title:, body:)
          existing = find_open(owner: owner, name: name, head: head)
          if existing
            return settle(owner: owner, name: name, number: existing["number"],
              base: base, title: title, body: body, current: existing.dig("base", "ref").to_s)
          end

          opened = call(:post, "/repos/#{owner}/#{name}/pulls",
            { "title" => title, "body" => body, "head" => head, "base" => base })
          { "html_url" => opened["html_url"].to_s,
            "base" => opened.dig("base", "ref").to_s }
        end

        # **A stacked request refuses the `base` field even when it names the base it already has.**
        # Measured: republishing diaspora's 8.0.5.1 request answered `422 Validation Failed — Cannot
        # change the base branch because the pull request is part of a stack`, and the walk lost the
        # title and body it came to rewrite. The field is sent only when the base is really moving;
        # if the stack still refuses it, the request's own base wins and the caller records that.
        def settle(owner:, name:, number:, base:, title:, body:, current:)
          payload = { "title" => title, "body" => body }
          payload["base"] = base if base.to_s != current
          begin
            updated = call(:patch, "/repos/#{owner}/#{name}/pulls/#{number}", payload)
          rescue Refused => e
            raise unless payload.key?("base") && e.message.include?("part of a stack")

            payload.delete("base")
            updated = call(:patch, "/repos/#{owner}/#{name}/pulls/#{number}", payload)
          end
          { "html_url" => updated["html_url"].to_s, "base" => updated.dig("base", "ref").to_s }
        end

        # The request whose head is the lower layer's branch. Open first, because a stack is a
        # chain of requests still under review; a closed one is still a fact about the branch and
        # is the last resort rather than the first answer.
        def pull_request_for(owner:, name:, head:)
          rows = Array(call(:get, "/repos/#{owner}/#{name}/pulls", nil,
            { "head" => "#{owner}:#{head}", "state" => "all", "per_page" => 100 }))
          found = rows.grep(Hash)
          open = found.select { |row| row["state"] == OPEN }
          (open.empty? ? found : open).max_by { |row| row["number"].to_i }
        end

        # The stack a pull request belongs to, or nil. The endpoint is a list because a stack is
        # read either by its own number or by one of its pull requests; the filter returns the one
        # containing this request.
        def stack_for(owner:, name:, pull_request:)
          rows = Array(call(:get, "/repos/#{owner}/#{name}/stacks", nil,
            { "pull_request" => pull_request }))
          rows.find { |row| row.is_a?(Hash) }
        end

        # Bottom to top. Each request's base must be the previous request's head, which is exactly
        # how this client opened them.
        def create_stack(owner:, name:, pull_requests:)
          call(:post, "/repos/#{owner}/#{name}/stacks", { "pull_requests" => pull_requests })
        end

        def add_to_stack(owner:, name:, stack_number:, pull_requests:)
          call(:post, "/repos/#{owner}/#{name}/stacks/#{stack_number}/add",
            { "pull_requests" => pull_requests })
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

        # **GitHub puts the actionable sentence in `errors`, not in `message`.** `message` is
        # "Validation Failed" for every refusal, and the reason a caller can act on — "Cannot change
        # the base branch because the pull request is part of a stack" — is one level down. A retry
        # keyed on the visible text could not see it.
        def sentence(body, code, path)
          message = body.is_a?(Hash) ? body["message"].to_s : ""
          details = body.is_a?(Hash) ? Array(body["errors"]).filter_map { |error|
            error.is_a?(Hash) ? error["message"].to_s : nil
          }.reject(&:empty?) : []
          "#{@api}#{path} answered #{code}" \
            "#{message.empty? ? "" : ": #{message}"}" \
            "#{details.empty? ? "" : " (#{details.join(";")})"}"
        end
      end
    end
  end
end
