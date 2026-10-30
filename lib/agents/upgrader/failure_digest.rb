# frozen_string_literal: true

module Agents
  module Upgrader
    # **The suite's failures as groups, not as the last eighty lines.**
    #
    # A repair prompt that ends with the tail of a log is whichever failures happened to be
    # printed last. Measured on brimir's 5.2.8.1 suite, 55 errors and the tail was Coveralls
    # output, so the model spent its whole deadline reading the tree; 46 of those errors were
    # one test calling a controller method that had become private. The same suite grouped by
    # exception and the first frame is a handful of lines, and it names the one test that
    # caused most of them.
    #
    # The parser reads the two dialects the corpus's suites speak (RSpec's numbered failure
    # blocks and Minitest's `Error:`/`Failure:` blocks) rather than a third format invented
    # here. Anything it cannot parse falls back to the tail, because a digest that silently
    # says nothing is worse than the log it replaced.
    class FailureDigest
      MAX_GROUPS = 8
      MAX_TITLES = 3
      MAX_FRAMES = 6

      Example = Struct.new(:title, :exception, :message, :frame, :frames, keyword_init: true)
      Group = Struct.new(:exception, :frame, :examples, keyword_init: true) do
        def count = examples.size
      end

      ANSI = /\e\[[0-9;]*m/
      # `NoMethodError`, `ActiveRecord::StatementInvalid`, `ActionView::Template::Error`, …
      # **The last component may be the suffix itself.** `ActionView::Template::Error` has no
      # prefix before `Error`, and a pattern that requires one misses every namespaced exception
      # whose final segment is the suffix — measured on brimir's two view failures, which the
      # first version of this class silently dropped.
      EXCEPTION = /\A\s*((?:[A-Z][A-Za-z0-9_]*::)*(?:[A-Z][A-Za-z0-9_]*)?
        (?:Error|Exception|Invalid|Violation|NotFound|Failure))\s*:\s*(.*)\z/x
      # RSpec frames carry a leading `#`; Minitest frames are the bare path and line.
      RSPEC_FRAME = /\A\s*#\s+(.+?):(\d+)(?::in\s+[`'].*)?\s*\z/
      MINITEST_FRAME = /\A\s+([^\s#].+?):(\d+):in\s+[`'].*\z/
      MINITEST_HEADER = /\A\s*(?:Error|Failure):\s*\z/
      RSPEC_HEADER = /\A\s*(\d+)\)\s+(.+?)\s*\z/
      # **The line every RSpec failure carries, and the one an expectation has instead of a
      # class.** `expected to find text …` prints no exception name, so a parser that only
      # reads named exceptions dropped seven of 19wu's sixteen failures and told the model the
      # suite had nine. RSpec raises `ExpectationNotMetError` for that shape; an unnamed
      # failure of another shape is grouped as exactly that, not guessed into a class.
      RSPEC_FAILURE = /\A\s+Failure\/Error:/

      def initialize(text)
        @text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub.gsub(ANSI, "")
      end

      def empty? = examples.empty?

      def render
        return fallback if examples.empty?

        groups = grouped
        lines = ["#{examples.size} failing example(s) in #{groups.size} group(s), " \
                 "grouped by exception and the first frame:"]
        groups.first(MAX_GROUPS).each_with_index do |group, index|
          lines << "#{index + 1}. #{group.count} × #{group.exception}" \
                   "#{group.frame.to_s.empty? ? "" : " at #{group.frame}"}"
          message = group.examples.first.message.to_s.strip
          lines << "   #{message}" unless message.empty?
          titles = group.examples.map(&:title).compact.reject(&:empty?).uniq.first(MAX_TITLES)
          lines << "   e.g. #{titles.join(" | ")}" unless titles.empty?
        end
        if groups.size > MAX_GROUPS
          lines << "…and #{groups.size - MAX_GROUPS} more group(s), in the full log."
        end
        representative = groups.max_by(&:count)
        lines << ""
        lines << "The largest group's first failure:"
        lines.concat(representative_lines(representative.examples.first))
        lines.join("\n")
      end

      private

      def examples
        @examples ||= begin
          found = rspec_examples
          found = minitest_examples if found.empty?
          found
        end
      end

      def grouped
        examples.group_by { |example| [example.exception, example.frame] }
          .map { |(exception, frame), list| Group.new(exception: exception, frame: frame, examples: list) }
          .sort_by { |group| [-group.count, group.exception.to_s, group.frame.to_s] }
      end

      def rspec_examples
        blocks = []
        current = nil
        @text.each_line do |line|
          if (match = line.match(RSPEC_HEADER)) && !line.include?("rspec ./")
            blocks << current if current
            current = { title: match[2].strip, lines: [] }
          elsif current
            break if line.start_with?("Finished in ")

            current[:lines] << line
          end
        end
        blocks << current if current
        blocks.filter_map { |block| example_from(block[:title], block[:lines]) }
      end

      def minitest_examples
        blocks = []
        current = nil
        @text.each_line do |line|
          if line.match?(MINITEST_HEADER)
            blocks << current if current
            current = []
          elsif current
            break if line.match?(/\A\d+ runs, /)

            current << line
          end
        end
        blocks << current if current
        blocks.filter_map do |lines|
          title = lines.first.to_s.strip.delete_suffix(":")
          example_from(title, lines.drop(1))
        end
      end

      # One failure's exception, message and frames. The message continues until a frame, a
      # blank line or the next exception; a backtrace is what follows. An exception the parser
      # cannot name is not a group — guessing one would put unrelated failures together.
      def example_from(title, lines)
        exception = nil
        message = +""
        frames = []
        failure_line = nil
        lines.each_with_index do |raw, index|
          # **The parser reads lines, not terminators.** `\z` in the patterns is the end of the
          # line; a trailing newline made every exception and every Minitest frame miss, which is
          # how the first version returned one example out of three.
          line = raw.chomp
          if exception.nil? && (match = line.match(EXCEPTION))
            exception = match[1]
            message << match[2].to_s.strip
            lines[(index + 1)..].to_a.each do |following|
              following = following.chomp
              break if following.match?(RSPEC_FRAME) || following.match?(MINITEST_FRAME)
              break if following.match?(EXCEPTION)
              break if following.strip.empty?

              message << " " << following.strip
            end
          elsif (match = line.match(RSPEC_FRAME) || line.match(MINITEST_FRAME))
            frames << [match[1], match[2].to_i]
          elsif failure_line.nil? && line.match?(RSPEC_FAILURE)
            failure_line = index
          end
        end
        if exception.nil?
          # A block with no named exception is still a failure when RSpec printed its own
          # `Failure/Error:` line; returning nil here is what made the count a lie.
          return nil if failure_line.nil?

          text = lines[(failure_line + 1)..].to_a.map(&:chomp).find do |following|
            !following.strip.empty? && !following.match?(RSPEC_FRAME) && !following.match?(MINITEST_FRAME)
          end.to_s.strip
          exception = if text.start_with?("expected")
            "RSpec::Expectations::ExpectationNotMetError"
          else
            "an unnamed failure"
          end
          message << text
        end

        Example.new(title: title, exception: exception, message: message.strip,
          frame: app_frame(frames), frames: frames)
      end

      # **The application's own frame is the grouping key when there is one.** A failure that
      # only has gem frames (caturday's Grape router) groups on the first of those, because
      # "the same library call" is still a better key than the exception alone.
      def app_frame(frames)
        chosen = frames.find { |path, _line| path.include?("/tree/") || path.start_with?("./") }
        chosen ||= frames.find { |path, _line| !path.include?("/gems/") }
        chosen ||= frames.first
        chosen && normalize_frame(*chosen)
      end

      def normalize_frame(path, line)
        path = path.to_s.sub(%r{\A.*?/tree/}, "").delete_prefix("./")
        "#{path}:#{line}"
      end

      def representative_lines(example)
        lines = ["- #{example.title}", "  #{example.exception}: #{example.message}"]
        example.frames.first(MAX_FRAMES).each do |path, line|
          lines << "  #{normalize_frame(path, line)}"
        end
        lines
      end

      def fallback
        tail = @text.lines.last(80).join
        "The failure could not be grouped; the tail of the output follows:\n#{tail}"
      end
    end
  end
end
