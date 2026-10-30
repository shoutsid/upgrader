# frozen_string_literal: true

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
          blocks(text).filter_map { |gem, lines| derivation(gem, lines) }.first(MAX_CONFLICTS)
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

          {
            "gem" => gem,
            "requirements" => requirements,
            "summary" => summary(gem, requirements)
          }
        end

        def summary(gem, requirements)
          parts = requirements.first(3).map do |row|
            via = row["via"].empty? ? "the Gemfile" : row["via"].join(" -> ")
            "#{row['requirement']} (via #{via})"
          end
          "#{gem} is required as #{parts.join(' and as ')}"[0, MAX_SUMMARY]
        end
      end
    end
  end
end
