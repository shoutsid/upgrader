# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # **A red suite's failures, as data rather than as a page of text.**
    #
    # The record keeps a suite's tail because a human reads it. A repair needs the same text in a
    # shape it can ask questions of: which application file raised, on which line, with which
    # exception and which keys the route helper was missing. Parsing here rather than inside a
    # repair keeps the dialect (RSpec's `Failures:` block today) in one place, so a second suite
    # dialect is a second parser and not a second copy of every rule.
    #
    # **`source` is the line the example printed, and it is not trusted as the file's line.** The
    # applier compares the line it is about to write against the file, so a repair built from a
    # stale or ellipsised `Failure/Error` is refused rather than written — which is the behaviour
    # wanted: a suite that elides the source line cannot be repaired from it.
    module SuiteFailures
      # `path`/`line` are the first *application* frame (`./app/...`), which is the template the
      # exception came out of rather than the gem frame above it. `error`/`message` are the
      # outermost exception; `caused_by`/`caused_by_message` the one underneath it, because RSpec
      # wraps a template's exception in `ActionView::Template::Error` and the class a repair cares
      # about (`NoMethodError`, `UrlGenerationError`) is in the `Caused by:` block.
      Failure = Struct.new(:name, :source, :error, :message, :caused_by, :caused_by_message,
        :frames, keyword_init: true) do
        def frame = frames.find { |path, _line| path.start_with?("./") }

        def file = frame && frame.first.delete_prefix("./")

        def line = frame && frame.last

        # Both spellings a repair may match on, outermost first: the wrapper's message is the one
        # a reader sees, the cause's is the one a rule can act on.
        def messages = [message, caused_by_message].compact

        def classes = [error, caused_by].compact
      end

      # RSpec numbers its failures `  1) Name`, and an example name may itself contain a number.
      # The leading whitespace is what separates it from the `Failed examples:` list, whose lines
      # begin with the formatter's own name.
      BLOCK = /\A\s{1,4}(\d+)\)\s+(.+?)\s*\z/

      # `     ActionView::Template::Error:` at the top, `     # NoMethodError:` inside the cause.
      CLASS_LINE = /\A\s+(?:#\s+)?([A-Z][\w:]*(?:Error|Exception|Failure)):\s*\z/

      # `     # ./app/views/bids/edit.html.erb:5:in ...` — only the application's own frames are
      # kept; a gem's frame names a library, not a file this walk may write.
      FRAME = /\A\s+#\s+(\S+):(\d+):in /

      SOURCE = /\A\s+Failure\/Error:\s?(.*)\z/

      def self.parse(text)
        blocks(text.to_s).filter_map { |lines| parse_block(lines) }
      end

      def self.blocks(text)
        groups = []
        current = nil
        text.each_line do |line|
          if BLOCK.match?(line)
            groups << current unless current.nil?
            current = [line]
          elsif !current.nil? && (line.strip.empty? || line.start_with?(" "))
            current << line
          elsif !current.nil?
            groups << current
            current = nil
          end
        end
        groups << current unless current.nil?
        groups
      end

      def self.parse_block(lines)
        name = BLOCK.match(lines.first)&.[](2).to_s
        source = nil
        error = message = caused = caused_message = nil
        frames = []
        caused_by = false
        awaiting = nil

        lines.each do |raw|
          # The line's terminator is the file's, not the failure's: matching `\A…\z` against text
          # that still carries it is how `source` came back nil while every other field parsed.
          line = raw.chomp
          if line.include?("--- Caused by: ---")
            caused_by = true
            awaiting = nil
            next
          end
          if (found = line.match(SOURCE))
            source = found[1].to_s.rstrip
            next
          end
          if (found = line.match(FRAME))
            frames << [found[1], found[2].to_i] if found[1].start_with?("./")
            next
          end
          if (found = line.match(CLASS_LINE))
            if caused_by
              caused = found[1]
              awaiting = :cause
            else
              error = found[1]
              awaiting = :error
            end
            next
          end

          next if awaiting.nil?

          # A cause's lines are printed behind the formatter's `# ` gutter; the top-level
          # failure's are not. The gutter is punctuation, not part of the sentence.
          text = line.sub(/\A\s+#\s*/, "").strip
          next if text.empty?

          if awaiting == :error && message.nil?
            message = text
          elsif awaiting == :cause && caused_message.nil?
            caused_message = text
          end
          awaiting = nil
        end

        Failure.new(name: name, source: source, error: error, message: message, caused_by: caused,
          caused_by_message: caused_message, frames: frames)
      end
    end
  end
end
