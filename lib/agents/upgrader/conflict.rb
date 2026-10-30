# frozen_string_literal: true

require "rubygems"

module Agents
  module Upgrader
    # **A failed resolve, as the constraints that cannot hold together.**
    #
    # Bundler's message already names the gem it could not place and nests the branches that
    # constrain it. The sentence a person needs is the minimal set at the leaves: one requirement
    # per branch, each with the requirers that introduced it — not the first line of a message
    # whose blocks are every one of them true and only some of them the cause.
    #
    # **This reads the resolver's answer; it does not resolve.** A second resolver in the walker
    # would disagree with Bundler the first time it learned a metadata shape this one had not, and
    # the corpus already records the resolver's own verdict. What was missing was the structure:
    # `evidence.conflict` is the derivation, and `evidence.conflicts` keeps every block when the
    # resolve named more than one. A block with fewer than two distinct requirements is not an
    # incompatibility — it is a release nobody could find, and it stays an ordinary failure.
    #
    # **The set is the smallest one that cannot hold, and the sentence says which it is.** A branch
    # Bundler printed is evidence, not necessarily a cause: `< 2.0` and `~> 1.6` are both satisfied
    # by 1.6.x, so claiming they conflict would send a maintainer looking for a release that does
    # not exist. Where the printed requirements are provably incompatible the derivation keeps the
    # cardinality-minimal subset (`proven` true, `minimal` filled); where they are satisfiable
    # together it keeps the whole set and says so, because the cause is then a release the resolver
    # could not place rather than two constraints that exclude each other. That is decided by
    # interval arithmetic over the clauses — a lower bound, an upper bound, exclusions — not by
    # choosing a version, so this stays a reader of the resolver's answer.
    module Conflict
      # A resolve's message is a few kilobytes of nested branches. Bounding these keeps one
      # pathological output from turning a question's evidence into a second copy of the log.
      MAX_CONFLICTS = 4
      MAX_REQUIREMENTS = 8
      MAX_SUMMARY = 600

      HEADER = /could not find compatible versions for gem (?:"([^"]+)"|([\w.-]+))/
      RESOLVED = /^(\s*)(\S.*?)\s+was resolved to\s+([^\s,]+)/

      class << self
        # Every conflict the message names that has more than one requirement, first four.
        def derive(text)
          found = blocks(text).filter_map { |gem, lines| derivation(gem, lines) }
          found << requested_conflict(text)
          found.compact.first(MAX_CONFLICTS)
        end

        private

        # The message's conflict blocks, as `[gem, lines]`, split where Bundler starts a new one.
        # A non-indented line after a block is the next section of the output, not the block.
        def blocks(text)
          result = []
          current = nil
          text.to_s.each_line do |line|
            if (match = HEADER.match(line))
              result << current if current
              current = [match[1] || match[2], []]
            elsif current
              break if !line.strip.empty? && !line.match?(/\A\s/)

              current[1] << line
            end
          end
          result << current if current
          result
        end

        def derivation(gem, lines)
          stack = []
          found = []
          lines.each do |line|
            text = line.strip
            next if text.empty? || text.start_with?("In Gemfile:")

            indent = line[/\A\s*/].length
            if (match = RESOLVED.match(line))
              # A sibling branch is shallower than the one that just ended, so the path to this
              # requirer is popped before it is pushed; a deeper line keeps its parent.
              stack.pop while stack.any? && stack.last[0] >= indent
              name = match[2].sub(/\s*\([^)]*\)\z/, "").strip
              stack << [indent, "#{name} #{match[3]}"]
              next
            end

            next unless text.start_with?(gem)

            rest = text[gem.length..]
            next unless rest.empty? || rest.match?(/\A\s+\([^)]*\)\z/)

            requirement = rest[/\(([^)]*)\)/, 1].to_s.strip
            next if requirement.empty?

            found << { "requirement" => requirement, "via" => stack.map(&:last) }
          end

          requirements = found.uniq { |row| [row["requirement"], row["via"]] }
                              .first(MAX_REQUIREMENTS)
          # One requirement is a missing release, not two constraints in conflict. Reporting it
          # as a derivation would tell a maintainer a gem was incompatible with itself.
          return nil if requirements.map { |row| row["requirement"] }.uniq.length < 2

          assembled(gem, requirements)
        end

        # **The other shape, and it has no "could not find compatible versions" header.** A
        # digest declaration the lock does not satisfy is answered with "You have requested:" and
        # the version the lock holds — two constraints on one gem, which is the same minimal set as
        # a version conflict even though Bundler spells it as an instruction rather than a failure.
        def requested_conflict(text)
          requested = text.to_s[/You have requested:\s*\n((?:[ \t]+.+\n?)+)/, 1].to_s
          locked = /The bundle currently has ([\w.-]+) locked at ([\w.]+?)(?:\.(?=\s|\z)|\s|\z)/.match(text.to_s)
          return nil if requested.empty? || locked.nil?

          gem = locked[1]
          requirement = requested.lines.filter_map do |line|
            match = /\A\s*#{Regexp.escape(gem)}\s+\(?([^)\n]+?)\)?\s*\z/.match(line)
            match && match[1].strip
          end.first
          return nil if requirement.to_s.empty?

          requirements = [
            { "requirement" => requirement, "via" => ["the Gemfile"] },
            { "requirement" => "= #{locked[2]}", "via" => ["Gemfile.lock"] }
          ]
          assembled(gem, requirements)
        end

        # One shape for both spellings, so a caller reads `minimal` whether Bundler wrote a
        # conflict block or an instruction about the lock.
        def assembled(gem, requirements)
          smallest = minimal(requirements)
          proven = !smallest.empty?
          {
            "gem" => gem,
            "requirements" => requirements,
            "proven" => proven,
            "minimal" => smallest,
            "summary" => summary(gem, proven ? smallest : requirements, proven: proven)
          }
        end

        # **The smallest subset that cannot hold, by trying every subset from one row upward.**
        # Eight rows at most, so the exhaustive search is 255 tests of a parse and a comparison
        # and needs no cleverness; a smaller set is a better answer than a greedy one, and a row
        # that holds alongside the rest is dropped rather than presented as a cause.
        #
        # Empty means "not proven", not "satisfiable": a requirement RubyGems cannot parse, or one
        # whose exclusion can only be settled against a real candidate list, leaves the caller with
        # every row Bundler named and the honest sentence that the resolver could not place one.
        def minimal(requirements)
          indices = (0...requirements.length).to_a
          holds = {}
          decision = lambda do |subset|
            holds.fetch(subset) do
              holds[subset] = satisfiable?(subset.map { |index| requirements[index]["requirement"] })
            end
          end
          return [] unless decision.call(indices) == false

          (1..indices.length).each do |size|
            indices.combination(size) do |subset|
              return subset.map { |index| requirements[index] } if decision.call(subset) == false
            end
          end
          []
        end

        # **Whether these requirements can hold together, decided without choosing a release.**
        # Each clause is a bound or an exclusion, so the conjunction is satisfiable when the
        # tightest lower bound lies below the tightest upper bound, or on it with both inclusive
        # and the point not excluded. `~>` is the same pair of bounds RubyGems reads it as.
        #
        # A prerelease is treated as comparable to its release line here, which makes the interval
        # permissive rather than strict — the direction that can only withhold a conflict claim,
        # never invent one.
        def satisfiable?(texts)
          parsed = texts.map { |text| parse_requirement(text) }
          return nil if parsed.any?(&:nil?)

          lowers = []
          uppers = []
          excluded = []
          parsed.each do |requirement|
            requirement.requirements.each do |operator, version|
              case operator
              when ">", ">=" then lowers << [version, operator == ">="]
              when "<", "<=" then uppers << [version, operator == "<="]
              when "="
                lowers << [version, true]
                uppers << [version, true]
              when "~>"
                lowers << [version, true]
                uppers << [version.bump, false]
              when "!=" then excluded << version
              else return nil
              end
            end
          end
          interval_holds?(lowers, uppers, excluded)
        end

        def interval_holds?(lowers, uppers, excluded)
          low, low_inclusive = edge(lowers, :max)
          high, high_inclusive = edge(uppers, :min)
          return true if low.nil? || high.nil?
          return false if low > high
          return true if low < high
          return false unless low_inclusive && high_inclusive

          excluded.none? { |version| version == low }
        end

        # The tightest bound, exclusive if either bound on that version is.
        def edge(bounds, direction)
          return [nil, false] if bounds.empty?

          chosen = bounds.map(&:first).public_send(direction)
          [chosen, bounds.select { |version, _| version == chosen }.all? { |_, inclusive| inclusive }]
        end

        def parse_requirement(text)
          clauses = text.to_s.split(",").map(&:strip).reject(&:empty?)
          return nil if clauses.empty?

          Gem::Requirement.new(clauses)
        rescue Gem::Requirement::BadRequirementError, ArgumentError
          nil
        end

        def summary(gem, requirements, proven:)
          parts = requirements.first(3).map do |row|
            via = row["via"].empty? ? "the Gemfile" : row["via"].join(" -> ")
            "#{row['requirement']} (via #{via})"
          end
          verdict = proven ? " — the smallest set that cannot hold together" :
                             " — the resolver could not place a release against them"
          "#{gem} is required as #{parts.join(' and as ')}#{verdict}"[0, MAX_SUMMARY]
        end
      end
    end
  end
end
