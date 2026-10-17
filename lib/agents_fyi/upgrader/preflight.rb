# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # What an old application's Gemfile needs *before* anything can be installed.
    #
    # A step begins by installing the application's bundle, and an application from 2013
    # often cannot be installed at all: its sources use a protocol GitHub no longer
    # speaks (`git://`, accepted until 2022), a fork it pinned has been deleted, a gem
    # it declares cannot sit beside the framework it is moving to, or a branch pin
    # stands in for a release that has since shipped. None of those are facts about the
    # move the ladder asked for; they are facts about the *application's own choices*,
    # and the install failure that reports them is the same failure for all four.
    #
    # So the preflight runs first and has two halves:
    #
    # * **General repairs**, which need no knowledge of gems: a `git://` remote rewritten
    #   to `https://` in the Gemfile *and* the lockfile, because Bundler reads the
    #   protocol out of the lockfile's own `remote:` lines and rewriting one file leaves
    #   the other pointing at GitHub's refusal.
    # * **Digest repairs**, from `GET /gems/migrations`: the curated, attributed moves a
    #   machine may make without reading the application's code. `mechanical` is the
    #   whole of what this class will act on; every other entry becomes a decision, because
    #   a Gemfile line it cannot rewrite alone is one a person or an agent has to look at.
    #
    # Three rules carry the weight, and each is a line somebody's Gemfile is on the other
    # side of:
    #
    # * **A declaration this class does not fully understand is not rewritten.** A
    #   declaration spanning several lines, one carrying a comment, one carrying an option
    #   that changes behaviour rather than sourcing (`require:`, `platforms:`) — each is
    #   skipped with the reason recorded. Rewriting what it cannot parse is how a
    #   preflight breaks an application quietly; a preflight that skipped something says
    #   so, and the install that follows is the same failure it would have been.
    # * **A gem the application does not declare is not the application's line.** An entry
    #   whose gem is in the lockfile but pulled in by something else becomes a decision
    #   naming that fact, rather than an edit to a line nobody wrote.
    # * **An unreadable digest narrows the preflight; it does not stop it.** A deployment
    #   whose service is older than this route refuses with a 404, and the record says the
    #   digest was not consulted. The general repairs still run — they are facts about the
    #   protocol rather than about an index — and the sentence says which half was skipped
    #   rather than leaving a short repair list to read as a clean Gemfile.
    class Preflight
      # The two files a protocol repair touches. Both, and deliberately: see above.
      SOURCES = %w[Gemfile Gemfile.lock].freeze

      # A declaration, with its indentation and its name. The name is captured so a
      # lookup by name cannot match a longer one — `gem "cancan"` is not `gem
      # "cancancan"` — and the indentation is kept so a rewritten line stays where the
      # application put it.
      DECLARATION = /\A(\s*)gem\s+["']([^"']+)["']/

      # The options that name *where* a gem comes from, and so may be dropped when the
      # digest says which release to declare instead. Anything else on the line
      # (`require:`, `platforms:`, `group:`) changes what the application does and makes
      # the declaration one this class will not rewrite.
      SOURCE_OPTIONS = %w[git github branch ref tag path source submodules glob].freeze

      # One repair that was written: the line before, the line after, and the gem it is
      # about. The field names are `Applier::Applied`'s so a record can show a preflight
      # repair and a scanned edit the same way.
      Repair = Struct.new(:path, :line, :text, :after, :subject, :note, keyword_init: true)

      # Nothing here is an application.
      class NotAnApplication < StandardError; end

      # Everything the preflight did, in the two lists a record already has places for
      # and the sentences that say what it could not do.
      Result = Struct.new(:repairs, :decisions, :notes, keyword_init: true) do
        def empty? = repairs.empty? && decisions.empty?

        # The one-line summary the `preflight:` stage carries, and the mode prints.
        def summary
          "#{repairs.size} repair(s), #{decisions.size} decision(s)" \
            "#{notes.empty? ? "" : ", #{notes.size} note(s)"}"
        end

        # The details, one per line, in the record's bounded tail.
        def details
          lines = repairs.map do |repair|
            "#{repair.path}:#{repair.line} `#{repair.text.strip}` -> `#{repair.after.strip}` " \
              "(#{repair.subject})"
          end
          lines += decisions.map do |decision|
            "decide #{decision.subject}: #{decision.reason}"
          end
          lines + notes
        end

        def to_h
          {
            "repairs" => repairs.map { |repair|
              { "path" => repair.path, "line" => repair.line, "text" => repair.text,
                "after" => repair.after, "subject" => repair.subject, "note" => repair.note }
            },
            "decisions" => decisions.map { |decision|
              { "path" => decision.path, "line" => decision.line, "subject" => decision.subject,
                "reason" => decision.reason, "kind" => decision.kind,
                "replacement" => decision.replacement, "source" => decision.source }
            },
            "notes" => notes
          }
        end

        def to_s
          lines = ["preflight: #{summary}"]
          details.each { |line| lines << "  #{line}" }
          lines.join("\n")
        end
      end

      def initialize(root:, corpus: nil)
        @root = File.expand_path(root)
        @corpus = corpus
      end

      def run
        unless File.file?(File.join(@root, "Gemfile")) || File.file?(File.join(@root, "Gemfile.lock"))
          raise NotAnApplication,
            "#{@root} has neither a Gemfile nor a Gemfile.lock, so there is nothing to " \
            "preflight — this tool moves Rails applications"
        end

        repairs = git_protocol_repairs
        decisions = []
        notes = []
        digest(notes).each do |entry|
          digest_repair(entry, repairs, decisions, notes)
        end
        Result.new(repairs: repairs, decisions: decisions, notes: notes)
      end

      private

      # `git://` was accepted until GitHub turned it off in 2022, and every 2013 Gemfile
      # that pinned a fork carries one. The rewrite is a scheme swap and nothing else:
      # the host and the path are the application's, and only the protocol is dead.
      def git_protocol_repairs
        repairs = []
        SOURCES.each do |name|
          path = File.join(@root, name)
          next unless File.file?(path)

          lines = File.binread(path).split("\n", -1)
          changed = false
          lines.each_with_index do |line, index|
            next unless line.include?("git://")

            after = line.gsub("git://", "https://")
            lines[index] = after
            changed = true
            repairs << Repair.new(
              path: name, line: index + 1, text: line, after: after, subject: "git://",
              note: "GitHub stopped accepting the git:// protocol in 2022; https:// is the " \
                    "same source over the protocol it still speaks"
            )
          end
          File.binwrite(path, lines.join("\n")) if changed
        end
        repairs
      end

      # How many names one digest question may carry. Mirrored from the route
      # (`Upgrade::Migrations::GEMS_LIMIT`) rather than discovered by being refused, and
      # pinned to it by a test: two components, one bound, and a client that sent a prefix
      # silently would be asking an incomplete question that reads as a complete answer.
      DIGEST_GEMS_LIMIT = 300

      # The digest, bounded to the gems this application can be asked about: the ones it
      # declares, plus the ones it merely locked so the answer can say that a move exists
      # and belongs to another gem's line.
      def digest(notes)
        names = declared_gems + (locked_gems - declared_gems)
        if names.size > DIGEST_GEMS_LIMIT
          notes << "#{names.size} gem name(s) would have to be asked about and this client " \
                   "sends at most #{DIGEST_GEMS_LIMIT}: the declared ones and the first of the " \
                   "rest were asked, so a migration for a gem further down the lockfile may " \
                   "not appear here"
          names = names.first(DIGEST_GEMS_LIMIT)
        end

        payload = client.gem_migrations(gems: names)
        payload.fetch("migrations", [])
      rescue Corpus::Unreachable, Corpus::Refused => e
        notes << "the gem-migrations digest was not read (#{e.message}), so only the general " \
                 "preflight repairs were applied; an install that fails may be failing for a " \
                 "reason the digest knows about"
        []
      end

      def client
        @client ||= @corpus || Corpus.new(base: nil)
      end

      # One digest entry, against the application's own Gemfile.
      #
      # The order of the checks is the decision: whether the gem is declared at all comes
      # first (an entry for a gem nobody declared has no line to rewrite), then whether
      # the move is mechanical, then whether the declaration is one this class can
      # rewrite. `declaration_index` finds the line once, so the skip reasons and the
      # rewrite name the same line.
      def digest_repair(entry, repairs, decisions, notes)
        name = entry["gem"].to_s
        found = declaration(name)
        if found.nil?
          return unless locked_gems.include?(name)

          decisions << decision(entry, path: "Gemfile.lock", line: nil,
            reason: "#{name} is in the lockfile but not declared in the Gemfile, so whatever " \
                    "pulls it in is the gem whose line moves: #{entry["note"]}")
          return
        end

        index, line = found
        unless entry["mechanical"] == true
          decisions << decision(entry, path: "Gemfile", line: index + 1, reason: entry["note"])
          return
        end

        skip = unrewritable(line, kind: entry["kind"].to_s)
        if skip
          notes << "Gemfile:#{index + 1} declares #{name} as `#{line.strip}`, which #{skip}; " \
                   "#{entry["note"]}"
          return
        end

        after = rewrite(entry, line)
        if after.nil?
          notes << "the digest says #{name} becomes #{entry["replacement"] || "nothing"}; " \
                   "this tool has no rewrite for that"
          return
        end
        # Already what the digest asks for — a second preflight over the same tree, or a
        # declaration the application updated itself. Nothing changed, so there is nothing
        # to record: a repair list is the lines that moved.
        return if after == line

        lines = File.binread(File.join(@root, "Gemfile")).split("\n", -1)
        if after.empty?
          lines.delete_at(index)
        else
          lines[index] = after
        end
        File.binwrite(File.join(@root, "Gemfile"), lines.join("\n"))
        repairs << Repair.new(path: "Gemfile", line: index + 1, text: line, after: after,
          subject: name, note: entry["note"])
      end

      # The line the Gemfile declares this gem on, or nil. `DECLARATION` matches the whole
      # line, so a gem whose name is a prefix of another's is never found by the other's
      # name — and a declaration this cannot read (old hash syntax, an unquoted name) is
      # not found either, which is a skip and not a wrong edit.
      def declaration(name)
        path = File.join(@root, "Gemfile")
        return nil unless File.file?(path)

        File.binread(path).split("\n", -1).each_with_index do |line, index|
          match = DECLARATION.match(line)
          return [index, line] if match && match[2] == name
        end
        nil
      end

      # Whether this declaration is one the digest repair may touch, and why not when it is
      # not. The kind matters: a *removal* takes the whole line, so what the line's options
      # say does not change what happens to it, while a *rewrite* has to leave the gem where
      # the application put it — which is why an option that changes behaviour (`require:`,
      # `platforms:`, `group:`) makes the declaration one this class will not rewrite.
      # A declaration spanning several lines is skipped either way: the one line this class
      # sees is not the whole of it, and half a removal is a syntax error.
      def unrewritable(line, kind:)
        return "spans several lines, so the one line this class sees is not the whole" if line.rstrip.end_with?(",")
        return nil if kind == "removed"
        return "carries a comment this class will not risk rewriting around" if line.match?(/\s#/)

        # The option names, with quoted values removed first so a URL's `https:` is not
        # read as an option called `https`.
        tokens = line.sub(DECLARATION, "").gsub(/"[^"]*"|'[^']*'/, "\"\"")
                     .scan(/([a-z_]+):/).flatten.uniq
        extra = tokens - SOURCE_OPTIONS
        return nil if extra.empty?

        "carries #{extra.sort.join(", ")}, which changes what the application does rather " \
          "than where the gem comes from"
      end

      # The new declaration: the gem the digest names, the requirement it gives for this
      # era, and the application's own indentation. No requirement means the resolver
      # chooses, which is the honest instruction when the digest has no reason to name
      # one. No trailing newline — the file's own line terminator is the file's business,
      # and a rewrite that carried one would add a blank line to the application's Gemfile.
      def rewrite(entry, line)
        indent = DECLARATION.match(line)&.[](1).to_s
        case entry["kind"].to_s
        when "replaced", "updated"
          replacement = entry["replacement"].to_s
          return nil if replacement.empty?

          requirement = entry["requirement"].to_s
          if requirement.empty?
            %(#{indent}gem "#{replacement}")
          else
            %(#{indent}gem "#{replacement}", "#{requirement}")
          end
        when "removed"
          # Nothing where the declaration was: the line goes, and the file's own shape
          # (a group block, a comment above) keeps working without it.
          ""
        end
      end

      def declared_gems
        return @declared_gems unless @declared_gems.nil?

        path = File.join(@root, "Gemfile")
        @declared_gems =
          if File.file?(path)
            File.binread(path).split("\n").filter_map do |line|
              match = DECLARATION.match(line)
              match && match[2]
            end.map { |name| name.force_encoding(Encoding::UTF_8) }.uniq
          else
            []
          end
      end

      def locked_gems
        @locked_gems ||= begin
          Lockfile.read(@root).specs.map { |spec| spec.first.to_s }.uniq
        rescue Lockfile::Missing, Lockfile::Unreadable
          []
        end
      end

      def decision(entry, path:, line:, reason:)
        Record::Decision.new(
          path: path, line: line, subject: entry["gem"].to_s,
          reason: reason.to_s, kind: entry["kind"],
          replacement: entry["replacement"], source: entry["source"]
        )
      end
    end
  end
end
