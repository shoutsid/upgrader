# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "openssl"
require "uri"

module AgentsFyi
  module Upgrader
    # The facts the service cannot read for itself, fetched by the side that can.
    #
    # A routing answer is only as good as the facts behind it, and the facts come from an
    # index — `https://index.rubygems.org/info/<gem>` — that this container can reach and the
    # service cannot. That split is the product's, not an accident: whoever can reach the
    # network fetches, and the service decides what the reading *means*. So the upgrader is a
    # researcher as well as a walker, and this class is the one place it writes something to
    # the corpus that is not a record of its own work.
    #
    # Three rules carry it:
    #
    # * **The document is parsed here and the service stores the meaning.** The service keeps
    #   `ruby_requirement` and `dependencies` per release; this class turns a compact-index
    #   line into those two fields and nothing else. A second interpretation of a gem release
    #   in the service would be a second place for the two to disagree.
    # * **Bounded, and the bound is stated.** One pass fetches at most `MAX_GEMS` gems and
    #   posts the *pinned* release plus the newest `RECENT_VERSIONS` of each — not the whole
    #   history: routing needs the pin to decide and the recent releases to find a target, and
    #   a walk that posted every release of every gem would spend its cycle on facts it will
    #   never read. What was skipped is in the result, not implied by a short list.
    # * **A gem the index will not answer is skipped with its reason**, and a gem whose
    #   document was already fetched recently is read from the cache. A walk over a lockfile
    #   asks about the same gems at every rung, and re-fetching all of them per rung is the
    #   cost this exists to avoid.
    class Research
      # Where a gem's declared facts come from. The compact index rather than the versions
      # API: the latter has `ruby_version` per release and no dependencies at all.
      INDEX = "https://index.rubygems.org/info/%s"

      # How many gems one pass fetches. A lockfile pins a few hundred; the *unknown* ones are
      # what a pass is for, and a pass that spent an hour on the long tail would not leave the
      # rung any closer to moving.
      MAX_GEMS = 60

      # How many releases per gem are posted: the pin, and the newest this many. A target for
      # a move is looked for among the newest recorded releases, so posting a gem's 2012
      # history buys nothing a routing answer reads.
      RECENT_VERSIONS = 40

      # How long a cached document is reused. The same six hours the miner's own readers use,
      # and for the same reason: a gem's next release is what a walk is waiting for, and a
      # cache that never expired would not see it.
      MAX_AGE = 6 * 3600

      # The request's ceiling, the miner's number: an index that accepts a connection and then
      # says nothing is the failure this bounds.
      TIMEOUT = 30

      NETWORK_ERRORS = [SocketError, SystemCallError, IOError, Timeout::Error,
                        Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError].freeze

      Result = Struct.new(:researched, :skipped, :reason, keyword_init: true) do
        def to_s
          "researched #{researched.size} gem(s)#{skipped.empty? ? "" : ", #{skipped.size} skipped"}" \
            "#{reason.to_s.empty? ? "" : " — #{reason}"}"
        end

        def details
          skipped.map { |skip| "#{skip[:gem]}: #{skip[:reason]}" }
        end
      end

      def initialize(corpus:, cache: nil, fetcher: nil, out: nil)
        @corpus = corpus
        @cache = cache
        @fetcher = fetcher
        @out = out
      end

      # Fetch and record what the pins' releases declare. `pins` is `[[name, version], ...]`;
      # the gems a pass looks at are the ones it was given, and nothing else.
      def run(pins)
        wanted = Array(pins).map { |name, version| [name.to_s, version.to_s] }.uniq
        researched = []
        skipped = []
        wanted.first(MAX_GEMS).each do |name, version|
          facts = facts_for(name, version)
          if facts.nil?
            skipped << { gem: name, reason: "the index answered nothing this reader could use" }
            next
          end

          record(name, facts)
          researched << name
          @out.puts("  research: #{name} — #{facts.size} release(s) recorded") if @out
        end
        if wanted.length > MAX_GEMS
          skipped << { gem: "#{wanted.length - MAX_GEMS} more",
                       reason: "one pass fetches at most #{MAX_GEMS} gems; the rest wait for " \
                               "the next pass" }
        end
        Result.new(researched: researched, skipped: skipped, reason: "")
      end

      # The facts to post for one gem: every release the index declares, narrowed to the pin
      # and the newest `RECENT_VERSIONS`. Each fact is `version`, `ruby_requirement` and
      # `dependencies` — the three fields the service stores — and the pinned release is
      # always among them even when it is years behind the newest.
      def facts_for(name, version)
        document = document_for(name)
        return nil if document.nil?

        parsed = self.class.parse(document)
        return nil if parsed.empty?

        # The document is written oldest-first, so the newest are its tail. The pinned
        # release is taken whatever its age: it is the one the routing verdict is about.
        chosen = [version, *parsed.keys.last(RECENT_VERSIONS)].uniq.select { |release| parsed.key?(release) }
        chosen.map do |release|
          {
            "version" => release,
            "ruby_requirement" => parsed[release]["ruby_requirement"],
            "dependencies" => parsed[release]["dependencies"]
          }
        end
      end

      # **The compact index's format, as one parser.** Each line is
      #
      #     <version> <name>:<requirement>,<name>:<requirement>|<key>:<value>,<key>:<value>
      #
      # where the version may carry a platform suffix (`1.16.0-x86_64-linux`), a release with
      # no dependencies has an empty section before the pipe, and a requirement with several
      # clauses joins them with `&` (`railties:< 5&>= 3.2.6`) — which is why the *dependency*
      # list can be split on commas at all. A `---` header line opens the document.
      def self.parse(document)
        document.to_s.each_line.with_object({}) do |line, facts|
          line = line.strip
          next if line.empty? || line.start_with?("---")

          left, right = line.split("|", 2)
          release, dependencies = left.to_s.split(" ", 2)
          next if release.to_s.empty?

          requirements = (right || "").split(",").filter_map do |pair|
            key, value = pair.split(":", 2)
            [key, value] if key && value
          end.to_h
          facts[release] = {
            "ruby_requirement" => requirements["ruby"],
            "dependencies" => (dependencies || "").split(",").filter_map do |pair|
              dep_name, dep_requirement = pair.split(":", 2)
              next if dep_name.nil? || dep_name.empty?

              { "name" => dep_name, "requirement" => dep_requirement.to_s.empty? ? nil : dep_requirement }
            end
          }
        end
      end

      private

      def record(name, facts)
        @corpus.record_facts(library: name, facts: facts)
      end

      # The document, from the cache when it is fresh. A fetch that fails is nil rather than an
      # exception: the caller's answer for every failure is the same — skip this gem and say
      # so — and the record of the walk is where that belongs.
      def document_for(name)
        cached = read_cache(name)
        return cached if cached

        document = @fetcher ? @fetcher.call(INDEX % name) : fetch(INDEX % name)
        write_cache(name, document) if document
        document
      rescue StandardError => e
        # Everything, not only the network errors: a document whose shape this reader cannot
        # follow is the same answer to a walk as an unreachable index — skip the gem and say
        # so — and a step that died on a gem's malformed line would lose the rung for a fact
        # it did not need.
        @out.puts("  research: #{name} could not be fetched: #{e.class}: #{e.message}") if @out
        nil
      end

      def fetch(url)
        uri = URI.parse(url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
          open_timeout: TIMEOUT, read_timeout: TIMEOUT) { |http| http.get(uri.request_uri) }
        return nil unless response.is_a?(Net::HTTPSuccess)
        return nil if response.body.to_s.strip.empty?

        response.body
      rescue *NETWORK_ERRORS
        nil
      end

      def read_cache(name)
        return nil if @cache.to_s.empty?

        path = File.join(@cache, "#{name}.index")
        return nil unless File.file?(path) && (Time.now - File.mtime(path)) < MAX_AGE

        File.read(path, encoding: "utf-8")
      end

      def write_cache(name, document)
        return if @cache.to_s.empty?

        FileUtils.mkdir_p(@cache)
        File.write(File.join(@cache, "#{name}.index"), document, encoding: "utf-8")
      end
    end
  end
end
