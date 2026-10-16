# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module AgentsFyi
  module Upgrader
    # The service, as a client: the ladder, the call sites a move crosses, the queue of
    # repositories worth walking, and the two writes one run produces — its record, and a
    # report when the run failed.
    #
    # It is two clients in one file, and the key is the seam. `plan` and the scan read
    # anonymous routes and write nothing, so they work with no account at all. The queue
    # read, the run record and the report are an operator's work and carry an operator's
    # key. That key comes from the environment rather than from every call site, because
    # four places construct a `Corpus` — `plan`, `step`, `serve` and the tests — and a
    # client that required each of them to pass it is a client whose fourth forgot.
    #
    # No retries anywhere: a plan is asked for by a person who is watching, and a retry
    # loop in front of a slow refusal is how a tool hides that the service is down.
    class Corpus
      # Where the operator's key comes from. Named here and read by no other file: the
      # container sets it as an environment variable and the CLI never mentions it.
      ENV_KEY = "AGENTS_FYI_KEY"

      # The service refused this, and its sentence is the whole answer: it says which
      # direction this ladder reads, which release it has no chapter for, or what in the
      # request it would not take. A client that replaces that sentence with "request
      # failed" has thrown away the only part of the response that could change what the
      # caller does next.
      class Refused < StandardError; end

      # The corpus already knows this, and here is what it said.
      #
      # A sibling of `Refused` rather than a case inside it, because exactly one caller
      # treats it differently and every other one should still read the sentence:
      # `create_report` hands the body back, since "somebody already recorded this" is
      # the ordinary outcome of filing rather than a failure of it.
      class Duplicate < Refused
        def initialize(message, payload = nil)
          super(message)
          @payload = payload
        end

        attr_reader :payload
      end

      # The service could not be reached, or answered with something that is neither the
      # thing that was asked for nor a refusal — a 500, a body that is not JSON, a
      # connection that never opened, a 200 that is not a plan or a queue.
      class Unreachable < StandardError; end

      DEFAULT_TIMEOUT = 25.0

      # How much of the queue one read asks for. A request rather than a demand: the
      # route clamps it and serves back the bound it applied, and this reads what it was
      # served. The miner asked for more than its route allowed for as long as that method
      # existed, was answered 422 every time, and had its caller read the refusal as "the
      # service has no queue" — so a short page here is a short page.
      DEFAULT_TARGET_LIMIT = 100

      def initialize(base:, timeout: DEFAULT_TIMEOUT, key: nil)
        @base = base.to_s.chomp("/")
        @timeout = timeout
        @key = key.nil? ? ENV.fetch(ENV_KEY, "").to_s : key.to_s
      end

      attr_reader :base

      # The steps from one Rails release to another, as the service writes them.
      def upgrade(from:, to:)
        call(:get, "/rails/upgrade", params: { from_version: from, to_version: to })
      end

      # The call sites a move crosses, in the files the caller sent.
      #
      # A read that keeps nothing — the source is the caller's private code — and it is
      # the route here that sends a body, so it is the one where a `413` is a thing that
      # can happen: the caller bounds what it sends, and `MAX_SCAN_BYTES` in `step.rb` is
      # that bound. A 413 is reported as the service's own answer rather than retried
      # smaller, because silently scanning less would turn "nothing found" into a claim
      # about files nobody read.
      def scan(from:, to:, files:)
        call(:post, "/rails/scan",
          body: {
            from_version: from, to_version: to,
            files: files.map { |path, text| { path: path, text: text } }
          })
      end

      # The queue: which repositories the service thinks are worth walking, best first.
      #
      # Empty is a real answer — nothing is queued — and it is deliberately not the only
      # one. A queue the service is *not serving* is reported as an error rather than as
      # an empty list, because the two want opposite responses from a loop: `AGENTS.md`
      # records what the mining queue taught this repository about a paused list read as
      # an empty one, and this is the same surface one ecosystem over.
      #
      # Rows the loop cannot walk are dropped rather than handed on, and that is a
      # deliberate narrowing of what "the queue" means: an entry with no `repo_url` is not
      # work, and a caller iterating it would clone nothing and call it a cycle.
      def targets(limit: DEFAULT_TARGET_LIMIT)
        payload = call(:get, "/upgrades/targets", params: { limit: limit })
        unless payload.is_a?(Hash) && payload["targets"].is_a?(Array)
          raise Unreachable, "#{@base} answered the queue with a 200 that carries no list of `targets`"
        end
        raise Unreachable, queue_paused_sentence(payload) if payload["paused"]

        payload["targets"].select { |row| row.is_a?(Hash) && !row["repo_url"].to_s.empty? }
      end

      # One step, as the service files it: the verdict, the commands with their exit
      # codes, the refusals, and the patch.
      def record_run(payload)
        call(:post, "/upgrades/runs", body: payload)
      end

      # Whether a draft is new, and what it is close to if it is not.
      def precheck(payload)
        call(:post, "/reports/precheck", body: payload)
      end

      # File one report.
      #
      # A duplicate is an answer rather than a failure: the corpus deciding that this is
      # already recorded is precisely what the precheck is for, and for a failure somebody
      # else has already hit it is the ordinary outcome. The sentence still travels, so a
      # caller that only wanted to know why nothing was written has it.
      def create_report(payload)
        call(:post, "/reports", body: payload)
      rescue Duplicate => e
        {
          "duplicate" => true,
          "detail" => e.message,
          "error" => (e.payload.is_a?(Hash) ? e.payload["error"] : nil)
        }
      end

      private

      # One request, and the one place a response becomes a value or an error.
      #
      # The key is sent only when there is one: an anonymous read carrying an empty
      # `X-API-Key` is a request that looks signed in and is not, and the routes that need
      # no account should not be handed a credential nobody has.
      def call(method, path, params: nil, body: nil)
        uri = URI.parse("#{@base}#{path}")
        uri.query = URI.encode_www_form(params) if params
        respond(fetch(uri, request_for(method, uri, body)))
      end

      def request_for(method, uri, body)
        request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
        request["Accept"] = "application/json"
        if body
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body)
        end
        request["X-API-Key"] = @key unless @key.empty?
        request
      end

      def queue_paused_sentence(payload)
        reason = payload["paused_reason"].to_s.strip
        advice = payload["next_step"].to_s.strip
        sentence = "the upgrade queue is not being served: " +
                   (reason.empty? ? "no reason was recorded" : reason)
        advice.empty? ? sentence : "#{sentence}. #{advice}"
      end

      def fetch(uri, request)
        Net::HTTP.start(
          uri.hostname,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: @timeout,
          read_timeout: @timeout
        ) { |http| http.request(request) }
      rescue StandardError => e
        raise Unreachable, "could not reach #{@base}: #{e.class}: #{e.message}"
      end

      def respond(response)
        payload = parse(response.body)
        code = response.code.to_i
        if code == 200
          # A 200 is only an answer when the body is one. A proxy's HTML page — a login
          # portal, a block notice — arrives with a 200 often enough that reading it as
          # "no changes" would tell a caller the ladder has nothing for this move when
          # nothing was answered at all. Every route this client reads answers with a
          # JSON object; anything else is an outage that happens to have a good status
          # code.
          return payload if payload.is_a?(Hash)

          raise Unreachable, "#{@base} answered HTTP 200 with a body that is not a plan"
        end
        # A collision is its own answer before it is a refusal, and only a write can
        # produce one: the one caller here that writes a report reads it as "the corpus
        # already knows this". Everything else in the 4xx range is the service reading the
        # request and declining it, sentence and all.
        raise Duplicate.new(sentence(payload, code), payload) if code == 409
        raise Refused, sentence(payload, code) if code >= 400 && code < 500

        raise Unreachable, "#{@base} answered HTTP #{code} instead of a plan#{hint(payload)}"
      end

      def parse(body)
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        nil
      end

      # The service's own words, out of the one envelope every failure here uses:
      # `{"error": {"type": ..., "message": ...}}`.
      def sentence(payload, code)
        message = payload.is_a?(Hash) ? payload.dig("error", "message") : nil
        return message.to_s if message && !message.to_s.empty?

        "#{@base} refused the request (HTTP #{code}) without saying why."
      end

      def hint(payload)
        payload.is_a?(Hash) ? "" : ", and a body that is not JSON"
      end
    end
  end
end
