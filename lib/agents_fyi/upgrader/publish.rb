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
                     report_base: nil)
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
          pushed, pushed_why = push(commit)
          return Result.new(pushed: false, branch: branch, commit: commit, reason: pushed_why) unless pushed

          return Result.new(pushed: true, branch: branch, base: base_branch, commit: commit, reason:
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
        pushed, pushed_why = push(commit)
        return Result.new(pushed: false, branch: branch, commit: commit, reason: pushed_why) unless pushed

        base = base_branch
        request = request_pull_request(
          owner: owner, name: name, head: branch, base: base,
          title: title, body: body
        )
        Result.new(pushed: true, branch: branch, base: base, commit: commit,
          pull_request: request, reason: "")
      rescue GitHub::Refused => e
        Result.new(pushed: false, branch: branch, reason: redact(e.message))
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
        previous = self.class.branch_for(@from_version, pattern: @branch_pattern)
        return previous if remote_has?(previous)

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

      def remote_has?(candidate)
        out, status = git("ls-remote", "--heads", push_url, candidate)
        status&.success? && !out.to_s.strip.empty?
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

      # What a reviewer needs and nothing else: what moved, what established that it works,
      # and what still needs a person. Composed from the record, so the request cannot say
      # something the record does not — and the record is what the corpus holds.
      def body
        lines = ["## What moved", ""]
        lines << "`agents-fyi` walked one rung of the Rails ladder: **#{@from_version} → #{@to_version}**."
        unless @commit.empty?
          lines << ""
          lines << "This branch is the rung's recorded commit `#{@commit[0, 8]}`: the first delivery " \
                   "attempt could not reach the remote, and the rung was not re-walked."
        end
        if @record&.brief
          lines << ""
          lines << "## What the corpus already knew"
          lines << ""
          lines << @record.brief.to_markdown(base: @report_base.empty? ? nil : @report_base)
        end

        if @record
          lines << ""
          lines << "The step's own verdict: `#{@record.verdict}` — #{@record.why}"
          lines << ""
          lines << "## What established it"
          lines << ""
          evidence.each { |line| lines << "- #{line}" }
        end

        # **An accepted decision is not a "needs a decision".** It was answered before the rung ran,
        # its effects were applied before the baseline, and the suite that establishes the rung ran
        # with them in place — so it belongs to what the rung *is*, not to what is still owed. The
        # origin (`decision:<id>`) is the only place that attribution survives into the record.
        if @record
          decided = @record.applied.select do |edit|
            edit.respond_to?(:origin) && edit.origin.to_s.start_with?("decision:")
          end
          unless decided.empty?
            lines << ""
            lines << "## Decisions in force"
            lines << ""
            lines << "These edits come from accepted decisions, applied before the baseline, and the"
            lines << "suite ran with them in place:"
            lines << ""
            decided.group_by(&:origin).each do |origin, edits|
              lines << "### `#{origin}`"
              edits.each do |edit|
                lines << "- `#{edit.path}`:#{edit.line} `#{edit.text.to_s.strip}` → " \
                         "`#{edit.after.to_s.strip}`"
              end
            end
          end
        end

        if @record && !@record.refused.empty?
          lines << ""
          lines << "## Refused edits — the line did not match, so nothing was written"
          lines << ""
          @record.refused.each do |refusal|
            lines << "- `#{refusal.path}`:#{refusal.line} — #{refusal.reason}"
          end
        end

        if @record && !@record.decisions.empty?
          lines << ""
          lines << "## Needs a decision before this is complete"
          lines << ""
          @record.decisions.each do |decision|
            located = [decision.path, decision.line].compact.join(":")
            lines << "- #{located.empty? ? "" : "`#{located}` — "}#{decision.subject}: #{decision.reason}"
          end
        end

        if @record && !@record.applied.empty?
          lines << ""
          lines << "## What the tool wrote"
          lines << ""
          @record.applied.each do |edit|
            lines << "- `#{edit.path}`:#{edit.line} `#{edit.text.to_s.strip}` → `#{edit.after.to_s.strip}`"
          end
        end

        lines << ""
        lines << "---"
        lines << ""
        lines << "Written by `agents-fyi`'s upgrader: the ladder is the service's, every command"
        lines << "and its exit code are in the run's record, and the test suite ran green both"
        lines << "before and after the step (or the record says why it did not). Review the diff"
        lines << "the way you would review a colleague's: the mechanical half is applied, and the"
        lines << "list above is what a machine would not decide."
        lines.join("\n")
      end

      # The evidence lines, from the stages the record actually ran. A line per thing a
      # reviewer would otherwise have to take on trust.
      def evidence
        found = []
        if @record.machine.to_s != ""
          found << "interpreter: `#{@record.interpreter}`#{@record.image.to_s.empty? ? "" : " (#{@record.image})"}"
        end
        @record.stages.each do |stage|
          next unless %w[baseline suite boot].include?(stage.stage)

          found << "#{stage.stage}: `#{stage.command}` — " +
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
