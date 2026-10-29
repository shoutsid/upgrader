# frozen_string_literal: true

module Agents
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
      # about (`NoMethodError`, `UrlGenerationError`) is in the `Caused by:` block. **A failed
      # expectation is the other shape**: no class, and `message` is RSpec's own sentence
      # (`expected "" to match "error=invalid_scope"`), because that is all the failure is.
      Failure = Struct.new(:name, :source, :error, :message, :caused_by, :caused_by_message,
        :frames, keyword_init: true) do
        # **RSpec prefixes an application frame with `./`; Minitest does not.** The two dialects
        # print the same fact in two spellings, and a repair's file is the application's either
        # way. A gem frame (`.../gems/...`) is still not this walk's to write.
        def frame = frames.find { |path, _line| path.start_with?("./", "app/", "test/") }

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
      # **`Class` is a suffix too**, because Ruby's exception names are not all `…Error`:
      # `Psych::DisallowedClass` is the one the YAML-column repair is built from, and a parser that
      # only knew `Error`/`Exception`/`Failure` left its class and its message unread. **`Data` is
      # the third**, measured on ohana-api's 7.1.6 rung: `I18n::MissingTranslationData` is the class
      # Rails 7.1 raises when a spec calls `I18n.t` on an undefined key, and without the suffix the
      # failure read as an anonymous block whose message was the source excerpt. **`Client` is the
      # fourth**, measured on 19wu: `Capybara::Poltergeist::DeadClient` is the browser process
      # dying, and the step reruns a stage whose only failure is that class.
      CLASS_LINE = /\A\s+(?:#\s+)?([A-Z][\w:]*(?:Error|Exception|Failure|Class|Data|Reference|Client)):\s*\z/

      # `     # ./app/views/bids/edit.html.erb:5:in ...` — only the application's own frames are
      # kept; a gem's frame names a library, not a file this walk may write.
      FRAME = /\A\s+#\s+(\S+):(\d+):in /

      SOURCE = /\A\s+Failure\/Error:\s?(.*)\z/

      # **Two dialects, because the applications use two suites.** RSpec prints `Failure/Error:`
      # and a numbered block; Minitest prints `Error:`/`Failure:`, the test's name, the exception
      # and an unnumbered stack. The parser already knew RSpec; the 6.1 rung of volunteer_portal
      # is Minitest, and its `UnknownAttributeReference` failures reached the mechanical repairs
      # with no file, no line and no message because this method saw no `Failure/Error:`.
      def self.parse(text)
        # **The suite's own colors are not part of its grammar.** Minitest and RSpec colorize
        # `Error:`/`Failure/Error:` when the output is a terminal, and a parser that matched only
        # the plain spelling saw no failures at all from the step container while the record's
        # stripped tail looked parseable. The escape sequences are removed before either dialect
        # is read.
        text = text.to_s.gsub(/\e\[[0-9;]*m/, "")
        # **Both dialects are read, rather than choosing one from a string in the output.** A
        # Minitest suite can print an application log line containing `Failure/Error:` (a GraphQL
        # error, a rescued exception), and choosing RSpec because of it made the real Minitest
        # failures invisible to the mechanical repairs. The two parsers return different blocks,
        # and the duplicate key is the name and frame a repair would act on.
        rspec = blocks(text).filter_map { |lines| parse_block(lines) }
        (rspec + minitest(text)).uniq { |failure| [failure.name, failure.file, failure.line] }
      end

      MINITEST_HEADER = /\A(?:Error|Failure):\s*\z/
      MINITEST_CLASS = /\A\s*([A-Z][\w:]*(?:Error|Exception|Failure|Class|Data|Reference)):\s*(.*)\z/
      MINITEST_FRAME = /\A\s+(\S+):(\d+):in /

      def self.minitest(text)
        groups = []
        current = nil
        text.each_line do |line|
          if line.match?(MINITEST_HEADER)
            groups << current unless current.nil?
            current = [line]
          elsif !current.nil?
            current << line
          end
        end
        groups << current unless current.nil?
        groups.filter_map { |lines| parse_minitest(lines) }
      end

      def self.parse_minitest(lines)
        name = lines[1].to_s.chomp.delete_suffix(":").strip
        return nil if name.empty?

        error = message = nil
        frames = []
        lines[2..].to_a.each do |raw|
          line = raw.chomp
          if (found = line.match(MINITEST_CLASS))
            error = found[1]
            message = found[2].strip unless found[2].to_s.strip.empty?
          elsif (found = line.match(MINITEST_FRAME))
            path = found[1]
            frames << [path, found[2].to_i] if path.start_with?("app/", "test/", "./")
          end
        end
        # A Minitest assertion has no exception class: its first explanatory line (`Expected:`
        # or the assertion's own sentence) is the message a repair can read.
        message ||= lines[2].to_s.strip unless error

        Failure.new(name: name, source: nil, error: error, message: message,
          caused_by: nil, caused_by_message: nil, frames: frames)
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
        # **The line after `Failure/Error:` is one of two things.** For an expectation it is the
        # detail the assertion printed; for a raised exception it is the source excerpt, and the
        # exception's own class and message follow below it. The flag is what tells the two apart
        # when the class line arrives, so the excerpt is not left standing as the message.
        excerpt = false

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
            # **An expectation failure prints no class line, and its own sentence is the
            # failure.** RSpec renders `Failure/Error: expect(...)` and then the detail —
            # `expected "" to match "error=invalid_scope"` — with no `SomeError:` above it (a
            # raised exception does print one, and the class branch below takes that case first).
            # Without this the detail was dropped, so a repair could see that an expectation at
            # line 113 failed and not what the expectation said, which is the whole of the evidence
            # a redirect's empty body is repaired from (`RedirectBodies`).
            awaiting = :error
            excerpt = true
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
              # The text read so far was the excerpt above the class, not the exception's message.
              message = nil if excerpt
            end
            excerpt = false
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
