# frozen_string_literal: true

require "fileutils"

module AgentsFyi
  module Upgrader
    # **The new defaults, stepped one at a time and judged by the suite.**
    #
    # A rung's `app:update` writes `config/initializers/new_framework_defaults_<version>.rb`, and
    # Rails generates it *commented out* on purpose: the guide's advice is to turn the defaults on
    # one by one and read what each does. A walker can do better than reading — it can run the
    # application's own suite after each toggle — and that is what this class is for: enable one,
    # keep it if the suite is green, put it back if it is not, and record which is which.
    #
    # Two properties make it safe rather than clever:
    #
    # * **It runs only against a green suite.** `Step` calls it after the move's own suite passed, so
    #   a red run here is about the toggle and never about the move — which is what makes "revert
    #   this one" the right answer instead of a guess.
    # * **It leaves the file, and a decision, when a toggle will not pass.** The file is what a
    #   reviewer (or an agent) needs: each toggle with its own comment, and the failure in the
    #   record beside it. Nothing is dropped silently.
    #
    # The last step is the guide's own: once every toggle is on, the file is deleted and
    # `config.load_defaults <version>` is written into `config/application.rb` — the two are the same
    # statement, and the line is the one that survives. That edit is a *deliberate* one to a file the
    # application owns (the applier would refuse it, correctly, as a merge), so it is made here, is
    # recorded as a stage of its own, and is followed by one more suite run.
    class Defaults
      # One toggle: the line it is on, the setting it names, and the comment above it — which is
      # Rails' own sentence about what the default changes, and the reason a reader can judge it.
      Toggle = Struct.new(:line, :text, :setting, :note, keyword_init: true) do
        def to_s = "#{setting} (#{note.to_s.empty? ? "no note" : note})"
      end

      # The setting shape Rails writes: `Rails.application.config.<a.b.c> = <value>`.
      TOGGLE = /\A#\s*(Rails\.application\.config\.[A-Za-z0-9_.\[\]"':]+)\s*=\s*(.+?)\s*\z/

      # The line `config.load_defaults` goes after, and the shape of the statement itself.
      APPLICATION_CLASS = /^\s*class\s+Application\s*<\s*Rails::Application\s*$/
      LOAD_DEFAULTS = /^\s*#?\s*config\.load_defaults\s/

      attr_reader :path, :root

      # The file this rung's `app:update` wrote, or nil. Newest first, because a walk that has
      # crossed several rungs has one per rung and the newest is the one this step is about.
      def self.file_in(root)
        Dir[File.join(root, "config", "initializers", "new_framework_defaults_*.rb")]
          .max_by { |path| File.mtime(path) }
      end

      def initialize(path:, root:)
        @path = path
        @root = root
      end

      # The toggles still commented out, in the file's own order — which is the order the guide
      # lists them and the order they are stepped in, because a reader comparing the two should not
      # have to sort anything.
      def toggles
        lines = File.read(@path, encoding: "utf-8").lines
        lines.each_with_index.filter_map do |text, index|
          found = TOGGLE.match(text)
          next if found.nil?

          Toggle.new(line: index + 1, text: text, setting: found[1],
            note: note_above(lines, index))
        end
      end

      # Uncomment one toggle, and put it back. Both rewrite the one line rather than the file, so a
      # walk killed between them leaves the file it had.
      def enable(toggle) = write(toggle.line, toggle.text.sub(/\A#\s?/, ""))

      def disable(toggle) = write(toggle.line, "# #{toggle.text.sub(/\A#\s?/, "")}")

      # The guide's last step, and the only edit here to a file the application owns. A
      # `config/application.rb` whose class line this does not recognise is left alone: the
      # alternative is guessing where the statement belongs, and a config line in the wrong place is
      # a file that does not load.
      def load_defaults!(version)
        path = File.join(@root, "config", "application.rb")
        return nil unless File.file?(path)

        lines = File.read(path, encoding: "utf-8").lines
        return nil if lines.any? { |line| line.match?(LOAD_DEFAULTS) }

        index = lines.index { |line| line.match?(APPLICATION_CLASS) }
        return nil if index.nil?

        # **The minor, and the caller does not have to know it.** The guide's statement is
        # `config.load_defaults 4.1` for a move to 4.1.0 — the line names a *release family*, not a
        # patch — and a rule that lives here is a rule a caller cannot get wrong.
        line = "config.load_defaults #{version.to_s.split(".").first(2).join(".")}"
        lines.insert(index + 1, "    #{line}\n")
        File.write(path, lines.join)
        line
      end

      def drop! = FileUtils.rm_f(@path)

      def exists? = File.file?(@path)

      private

      # The prose directly above a toggle, which is Rails' own sentence about it. A blank line or
      # another toggle ends the search: the note belongs to the toggle it sits on top of.
      def note_above(lines, index)
        notes = []
        cursor = index - 1
        while cursor >= 0
          text = lines[cursor].to_s.strip
          break unless text.start_with?("#")
          break if text.match?(TOGGLE)

          notes.unshift(text.sub(/\A#\s?/, ""))
          cursor -= 1
        end
        notes.reject(&:empty?).last.to_s
      end

      def write(line, text)
        lines = File.read(@path, encoding: "utf-8").lines
        return false if lines[line - 1].nil?

        lines[line - 1] = "#{text}\n"
        File.write(@path, lines.join)
        true
      end
    end
  end
end
