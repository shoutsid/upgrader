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
    # * **Digest repairs**, from `GET /api/gems/migrations`: the curated, attributed moves a
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

      # Bundler's `github:` shorthand. It is the *second* spelling of the dead protocol and
      # the one this class nearly missed: Bundler 1.x expands `github: "owner/name"` to
      # `git://github.com/owner/name.git`, which is why every 2013 Gemfile that pinned a fork
      # broke at once — and why rewriting only the literal `git://` left the first real
      # application's install stuck cloning over a protocol GitHub stopped accepting.
      GITHUB_OPTION = /github:\s*(["'])([^"']+)\1/

      # One repair that was written: the line before, the line after, and the gem it is
      # about. The field names are `Applier::Applied`'s so a record can show a preflight
      # repair and a scanned edit the same way.
      Repair = Struct.new(:path, :line, :text, :after, :subject, :note, keyword_init: true)

      # A Gemfile `ruby` directive, with the indentation, the quote the application used and
      # whatever follows the version. The rest is kept out of the rewrite: an `engine:` names a
      # different interpreter, and a comment is a sentence this class has no business editing.
      RUBY_DIRECTIVE = /\A(\s*)ruby\s+(["'])([^"']+)\2(.*)\z/

      # Nothing here is an application.
      class NotAnApplication < StandardError; end

      # Everything the preflight did, in the two lists a record already has places for
      # and the sentences that say what it could not do. `deferred` is the third list and
      # deliberately not an outcome: an entry scoped to the rung cannot be applied while the
      # Gemfile still names the release the move starts from, so it travels to the caller that
      # rewrites the pin (`Step#declare_for_the_rung`).
      Result = Struct.new(:repairs, :decisions, :notes, :deferred, keyword_init: true) do
        def empty? = repairs.empty? && decisions.empty?

        # The one-line summary the `preflight:` stage carries, and the mode prints. The held
        # entries are `entry(ies)` rather than `declaration(s)` because both kinds travel this way
        # now: a `declared` entry adds a line, and a rewrite moves one the application declared.
        def summary
          later = deferred.to_a.empty? ? "" : ", #{deferred.size} entry(ies) held for the pin"
          "#{repairs.size} repair(s), #{decisions.size} decision(s)#{later}" \
            "#{notes.empty? ? "" : ", #{notes.size} note(s)"}"
        end

        # The details, one per line, in the record's bounded tail.
        def details
          lines = repairs.map do |repair|
            # **An addition has no line to quote.** A declaration the digest asks for is a line
            # the application does not have, so `text` is nil and there is nothing to render
            # before the arrow — and a renderer that called `.strip` on nil would turn a repair
            # into a crash in the one place a record is being written.
            if repair.text.nil?
              "#{repair.path}: `#{repair.after.strip}` declared (#{repair.subject})"
            else
              "#{repair.path}:#{repair.line} `#{repair.text.strip}` -> `#{repair.after.strip}` " \
                "(#{repair.subject})"
            end
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
            "notes" => notes,
            # **What was *not* done here, and who will do it.** A rung-scoped declaration is
            # applied by the step after the pin is rewritten, so a record of this stage that
            # did not name it would read as "the digest had nothing for this application".
            "deferred" => deferred.to_a.map { |entry| entry["gem"] }
          }
        end

        def to_s
          lines = ["preflight: #{summary}"]
          details.each { |line| lines << "  #{line}" }
          lines.join("\n")
        end
      end

      # `ruby` is the interpreter the move will run on, as far as the caller knows it — the
      # *lowest* one the rung allows, because this stage runs before the machine is chosen (the
      # choice is itself a `bundle install`, so the Gemfile has to be installable first). It is
      # what a digest entry's `when` is evaluated against, and a caller that cannot name one is
      # told which entries it therefore could not apply rather than being served them silently.
      def initialize(root:, corpus: nil, ruby: nil, rails: nil)
        @root = File.expand_path(root)
        @corpus = corpus
        @ruby = ruby.to_s.strip
        # The release the move *ends at*, which is what makes an entry rung-scoped. Nil in the
        # standalone `preflight` mode, which is asked about a repository rather than about a move —
        # and a rung condition this cannot evaluate is a note at the call site, not a guess.
        @rails = rails.to_s.strip
      end

      def run
        unless File.file?(File.join(@root, "Gemfile")) || File.file?(File.join(@root, "Gemfile.lock"))
          raise NotAnApplication,
            "#{@root} has neither a Gemfile nor a Gemfile.lock, so there is nothing to " \
            "preflight — this tool moves Rails applications"
        end

        repairs = protocol_repairs + ruby_pin_repairs + ruby_removal_repairs +
          framework_removal_repairs
        decisions = []
        notes = []
        deferred = []
        digest(notes).each do |entry|
          digest_repair(entry, repairs, decisions, notes, deferred)
        end
        Result.new(repairs: repairs, decisions: decisions, notes: notes, deferred: deferred)
      end

      # **The rung-scoped entries this stage could not apply, because the Gemfile and the pin did
      # not agree yet.** Each entry already passed `holds?` when it was deferred, so it is applied
      # here rather than re-evaluated: `Step#rewrite` calls this after the Rails pin is rewritten
      # and before the pin's resolve, which is the one place a rung-scoped entry is both true of
      # the Gemfile and not yet contradicted by it. Both kinds travel this way, and they are
      # applied by the two halves the preflight already has: a `declared` entry adds a line the
      # application does not have, and every other kind rewrites the line it declares.
      def declare_deferred(entries)
        repairs = []
        decisions = []
        notes = []
        Array(entries).each do |entry|
          name = entry["gem"].to_s
          found = declaration(name)
          if entry["kind"].to_s == "declared"
            declare(entry, found, repairs, decisions, notes)
          elsif found
            rewrite_declared(entry, found, repairs, notes)
          else
            notes << "the digest's entry for #{name} was held for the pin, but the Gemfile " \
                     "declares no line of its own for it: #{entry["note"]}"
          end
          # **A companion's stage follows its entry's clause, and this is the rung-scoped stage.** The
          # preflight applies an interpreter-scoped entry's companion beside its line, because the
          # baseline that needs it runs before the pin; a rung-scoped entry's line moves *here*, after the
          # pin, so its edits belong here too. Measured at the 7.2 rung: `factory_girl_rails`'s rename is
          # scoped by `rails_at_least 7.2`, and the application's 93 `FactoryGirl` call sites have to move
          # with the line or the suite the pin leaves behind cannot load.
          apply_companion(entry, repairs, notes)
        end
        Result.new(repairs: repairs, decisions: decisions, notes: notes, deferred: [])
      end

      private

      # **An exact interpreter pin names a patch the matrix may not have.** The walk's matrix is one
      # image per era — 2.7 is Ruby 2.7.8 — and a Gemfile saying `ruby "2.7.5"` is a statement Bundler
      # enforces, so every era but the exact patch is refused before the bundle is read. That is a fact
      # about the application's deployment note, not about the move: patch releases of a minor are
      # compatible, and the application's own CI keeps running 2.7.5. The repair is the *floor* the
      # application meant, `>= 2.7.5`, rather than a pessimistic `~>`: a `~>` would block the later
      # rungs whose interpreter is a newer minor, which is the one thing a walk exists to cross.
      #
      # A line carrying an `engine:`, an `engine_version:` or a comment is not touched: the first two
      # name a different interpreter, and the last is a sentence whose meaning this class cannot read.
      def ruby_pin_repairs
        path = File.join(@root, "Gemfile")
        return [] unless File.file?(path)

        lines = File.binread(path).split("\n", -1)
        changed = false
        repairs = lines.each_with_index.filter_map do |line, index|
          after = relaxed_ruby_pin(line)
          next if after.nil?

          lines[index] = after
          changed = true
          Repair.new(path: "Gemfile", line: index + 1, text: line, after: after, subject: "ruby",
            note: "the application pins an exact interpreter patch; patch releases of a minor are " \
                  "compatible, and a floor keeps the minimum without refusing the rung's newer era")
        end
        File.binwrite(path, lines.join("\n")) if changed
        repairs
      end

      # One `ruby` line made a floor, or nil when it is already a requirement or carries an option
      # this class will not rewrite. Only a bare numeric requirement is exact enough to relax; a
      # range, a `~>`, a comment or an engine is a different statement.
      def relaxed_ruby_pin(line)
        match = RUBY_DIRECTIVE.match(line)
        return nil unless match

        indent, quote, version, rest = match.captures
        return nil unless rest.to_s.strip.empty?
        return nil unless version.match?(/\A\d+(?:\.\d+)*\z/)

        %(#{indent}ruby #{quote}>= #{version}#{quote})
      end

      # `git://` was accepted until GitHub turned it off in 2022, and every 2013 Gemfile that
      # pinned a fork carries it — literally, or through Bundler's `github:` shorthand. Both
      # spellings are repaired here, in both files: the lockfile's own `remote:` lines carry
      # the expanded URL, and the Gemfile carries whichever spelling the application wrote.
      # **A method the rung's interpreter removed, in a file the application loads before anything
      # else.** Measured at the 7.2 rung, the first on the 3.2 era: every stage after the install dies
      # the same way — `config/boot.rb:4:in '<top (required)>': undefined method 'exists?' for
      # File:Class (NoMethodError)` — and `config/boot.rb` is loaded by `bin/rails` itself, so
      # `app:update` (the command that would replace that generated file) cannot run either. That makes
      # it the preflight's business rather than a later stage's: the baseline, the database and the
      # suite all read this file.
      #
      # **Only the receivers whose method was removed.** `File.exists?`, `Dir.exists?` and
      # `FileTest.exists?` became `exist?` in Ruby 3.2 and mean exactly the same thing, so the rewrite
      # is not a choice. `Model.exists?` is a different method on a different receiver and is left
      # alone — a rewrite that dropped the receiver would break every ActiveRecord query in the tree.
      REMOVED_RUBY_METHODS = {
        "File.exists?" => "File.exist?",
        "Dir.exists?" => "Dir.exist?",
        "FileTest.exists?" => "FileTest.exist?"
      }.freeze

      # **A method the *framework* removed, which the release itself names the successor of.** The
      # interpreter's removals above are unconditional because the interpreter is the era's; a
      # framework's are the *rung's*, because the successor may not exist below it — so each entry
      # carries the same `when` clauses a digest entry does, and `holds?` reads them.
      #
      # Measured at the 7.2 rung: activerecord 7.1 has both `check_pending!` and `check_all_pending!`
      # and 7.2 has only the second, so the application's own `spec/spec_helper.rb:20` and
      # `test/test_helper.rb:6` die with `undefined method `check_pending!'` — and the *baseline*
      # cannot see it, because the baseline runs on the release the application is leaving. The
      # rewrite is the framework's own prescription rather than a guess: 7.1's body reads "This is
      # deprecated in favor of +check_all_pending!+".
      FRAMEWORK_REMOVALS = [
        {
          "from" => "ActiveRecord::Migration.check_pending!",
          "to" => "ActiveRecord::Migration.check_all_pending!",
          "when" => { "rails_at_least" => "7.2" }
        },
        # **A predicate the release removed, whose matcher the application's specs spell the old way.**
        # Measured at the 6.0 rung: every failing example there is a controller spec asserting
        # `expect(response).to be_success` — RSpec's `be_success` is a dynamic predicate matcher, so it
        # asks the object for `success?`, and `ActionDispatch::TestResponse#success?` was deprecated in
        # 5.2 and removed in 6.0 (`successful?` comes from `Rack::Response::Helpers`). The ladder carries
        # no change for it at all, so this is a fact about the release rather than about a rung's
        # documented change — and the rewrite is the release's own: the matcher for the new predicate is
        # `be_successful`.
        {
          "from" => "be_success",
          "to" => "be_successful",
          "when" => { "rails_at_least" => "6.0" }
        }
      ].freeze

      # The application's own Ruby, which is what a rung can be blamed for. `vendor` and
      # `node_modules` are somebody else's code and are not walked.
      RUBY_SOURCE_GLOBS = %w[config/**/*.rb app/**/*.rb lib/**/*.rb spec/**/*.rb test/**/*.rb *.rb
        Rakefile].freeze

      def ruby_removal_repairs
        removal_repairs(REMOVED_RUBY_METHODS) do |from, to|
          "#{from} is `#{to}` in this interpreter and means the same thing; the application's own " \
            "file is loaded before any stage that could repair it, so it is repaired here"
        end
      end

      # The framework's removals, scoped by the rung: an entry whose clause this move does not meet is
      # not a repair at all, which is why the table is filtered before the walk rather than inside it.
      def framework_removal_repairs
        table = FRAMEWORK_REMOVALS.select { |each| holds?(each) }
          .to_h { |each| [each["from"], each["to"]] }
        return [] if table.empty?

        removal_repairs(table) do |from, to|
          "#{from} is `#{to}` in the release this rung moves to — the successor that release names — " \
            "and the baseline cannot see it, because the baseline runs on the release the application " \
            "is leaving"
        end
      end

      # **The line-rewriting half, shared, because two kinds of fact move a name the same way.** The
      # `from` is a whole method path rather than a bare word on purpose: `Model.exists?` is a
      # different method on a different receiver, and a rewrite that dropped it would change every
      # query in the tree.
      #
      # **And a name is rewritten only where it *ends*, because one of these names is a prefix of
      # another.** `be_success` is a prefix of `be_successful`, so a plain `gsub` would turn a line the
      # application had already migrated into `be_successfulful` — and a rewrite that has to be applied
      # before another one to be safe is not a rewrite but an ordering. The lookahead says "this name
      # and no more name after it", which is also what keeps `File.exists?` matching: `?` is not a word
      # character, so the guard asks about the character after it and `File.exists?(x)` passes.
      def removal_repairs(table)
        patterns = table.map { |from, to| [/#{Regexp.escape(from)}(?![A-Za-z0-9_])/, from, to] }
        repairs = []
        RUBY_SOURCE_GLOBS.each do |glob|
          Dir.glob(File.join(@root, glob)).sort.each do |full|
            next unless File.file?(full)

            name = full.sub("#{@root}/", "")
            lines = File.binread(full).split("\n", -1)
            changed = false
            lines.each_with_index do |line, index|
              after = line.dup
              removed = nil
              patterns.each do |pattern, from, to|
                next unless after.match?(pattern)

                removed = from
                after = after.gsub(pattern, to)
              end
              next if removed.nil?

              lines[index] = after
              changed = true
              repairs << Repair.new(path: name, line: index + 1, text: line, after: after,
                subject: removed, note: yield(removed, table.fetch(removed)))
            end
            File.binwrite(full, lines.join("\n")) if changed
          end
        end
        repairs
      end

      def protocol_repairs
        repairs = []
        revisions = git_revisions
        SOURCES.each do |name|
          path = File.join(@root, name)
          next unless File.file?(path)

          lines = File.binread(path).split("\n", -1)
          changed = false
          lines.each_with_index do |line, index|
            after, subject, note = protocol_line(line, revisions)
            next if after.nil?

            lines[index] = after
            changed = true
            repairs << Repair.new(path: name, line: index + 1, text: line, after: after,
              subject: subject, note: note)
          end
          File.binwrite(path, lines.join("\n")) if changed
        end
        repairs
      end

      # One line, repaired for the protocol, or nil when it needs nothing.
      #
      # The two spellings become one answer: an explicit `git:` remote over `https://`. The
      # shorthand is *expanded* rather than swapped, because there is no scheme to swap — and
      # the line's own quoting and every other option it carries (a `branch:`, most often)
      # are kept exactly as written; only the source is rewritten.
      #
      # **A shorthand with no branch or ref is pinned to the commit the lockfile names.** The
      # shorthand's implicit branch is `master`, and a 2013 repository's default branch has long
      # since become `main` — so `bundle update`, which re-reads the Gemfile, asked for `master`,
      # found nothing and failed with `Revision master does not exist`. Measured at the 4.0.13
      # checkpoint of the first real application: the install succeeded from the lock and the
      # pin, which is the stage that moves Rails, died on the shorthand it had just rewritten.
      def protocol_line(line, revisions = {})
        if line.include?("git://")
          return [line.gsub("git://", "https://"), "git://",
            "GitHub stopped accepting the git:// protocol in 2022; https:// is the same " \
            "source over the protocol it still speaks"]
        end
        return [nil, nil, nil] unless line.include?("github:")

        pinned = false
        after = line.sub(GITHUB_OPTION) do
          quote = Regexp.last_match(1)
          remote = Regexp.last_match(2).strip.delete_suffix(".git")
          url = "https://github.com/#{remote}.git"
          revision = revisions[normalize_remote(url)]
          pinned = !revision.to_s.empty? && !line.match?(/\b(?:branch|ref|tag):/)
          ref = pinned ? ", ref: #{quote}#{revision}#{quote}" : ""
          %(git: #{quote}#{url}#{quote}#{ref})
        end
        return [nil, nil, nil] if after == line

        note = "Bundler expands github: to git://github.com/... — the same protocol GitHub " \
          "stopped accepting in 2022 — so the shorthand becomes the git: remote it stands " \
          "for, over https://"
        if pinned
          note += ", pinned to the revision the lockfile names, because the shorthand's " \
            "implicit `master` branch no longer exists on every repository"
        end
        [after, "github:", note]
      end

      # The revision each git source is locked at, keyed by its remote without a scheme.
      #
      # The lockfile is the only place a 2013 Gemfile records which commit its shorthand meant;
      # reading it before a rewrite is why the pin can name that commit rather than a branch the
      # repository renamed out from under it.
      def git_revisions
        path = File.join(@root, "Gemfile.lock")
        return {} unless File.file?(path)

        revisions = {}
        remote = nil
        File.binread(path).each_line do |line|
          case line
          when /\A  remote: (\S+)/ then remote = normalize_remote(Regexp.last_match(1))
          when /\A  revision: (\S+)/ then revisions[remote] = Regexp.last_match(1) if remote
          when /\A[A-Z]/ then remote = nil
          end
        end
        revisions
      end

      def normalize_remote(url)
        url.to_s.strip.sub("git://", "https://").delete_suffix(".git")
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
      def digest_repair(entry, repairs, decisions, notes, deferred = [])
        name = entry["gem"].to_s
        # **A condition guards every kind, not only a declaration.** A digest entry is a fact about an
        # era, and the era is not always the one being walked: measured at the 4.2 rung, the digest's
        # `devise ~> 3.0.0` is the line 4.0 and 4.1 need and the wrong one at 4.2. The entry that does
        # not apply says so rather than being applied blind.
        unless holds?(entry)
          notes << "the digest's entry for #{name} was not applied: #{why_not(entry)} " \
                   "(#{condition_sentence(entry)}) — #{entry["note"]}"
          return
        end

        # **A declaration for a gem the application only carries transitively is written only
        # where the lock says it carries it.** Measured at the 7.1 rung: the digest's
        # `database_cleaner ~> 2.1` moves the meta-gem, 2.1.0's requirement on
        # `database_cleaner-active_record` is `>= 2, < 3`, and the conservative resolve keeps the
        # locked 2.0.1 — whose `SchemaMigration.table_name` the rung removed. The component's line
        # is the repair, and the application declares no line of its own, so it is a declaration;
        # `only_if_locked` is what keeps that declaration off an application that does not use the
        # gem at all. Read from the lockfile rather than from the caller, because the lockfile is
        # the one fact that says whether the gem is installed.
        if entry["only_if_locked"] == true && !locked_gems.include?(name)
          notes << "the digest's entry for #{name} was not applied: the application's lockfile " \
                   "does not hold it, and a declaration is only written where the gem is already " \
                   "installed — #{entry["note"]}"
          return
        end

        # **A digest's line is a floor, and a newer application is not moved down to it.** The
        # curated entries were measured on applications that pinned an older release; the same
        # entry met a modern Gemfile on the second lighthouse — `json ~> 1.8` against a locked
        # json 2.19.3, `carrierwave ~> 0.9.0` against 3.1.2 — and the preflight wrote the
        # downgrade, which the resolver then refused for conflicting with a dev gem. A line the
        # application already sits above is not a repair; it is a regression waiting for a bundle
        # resolve to notice.
        # **A lockfile this cannot read is not an application with nothing locked.** The reader
        # below used to be a bare `Bundler::LockfileParser`, and a tree that vendors a gem
        # (`remote: vendor/gems/…`, which is how diaspora pins `js_image_paths`) makes that raise
        # `Bundler::GemfileNotFound` when the process is not standing in the application — the
        # rescue turned it into `{}`, the guard read "nothing is newer", and the 8.1 rung was
        # handed `carrierwave ~> 0.9.0` over a locked 3.1.2, `json ~> 2.6.0` over 2.19.3 and
        # `thor ~> 1.2.0` beside a `foreman` that requires `~> 1.4`. The pin then exited 6 on
        # `version solving has failed`, and every stage after it measured a bundle that would
        # not resolve. A version this cannot see is a reason not to take the move.
        if locked_versions.nil?
          notes << "the digest's entry for #{name} was not applied: the Gemfile.lock beside " \
                   "#{@root} could not be read, so whether #{entry["requirement"]} is a " \
                   "downgrade is unknown — a curated line is not applied blind"
          return
        end

        if newer_than_entry?(name, entry)
          notes << "the digest's entry for #{name} was not applied: the application has " \
                   "#{name} #{locked_version(name)} locked, newer than #{entry["requirement"]}, " \
                   "so the move would be a downgrade"
          return
        end

        if entry["kind"].to_s == "declared"
          # **A declaration waits until the Gemfile and the pin agree.** A `declared` entry is
          # about a gem the *framework being moved to* brings in, and its requirement is a fact
          # about that framework: measured at the 4.2 rung, declaring `responders ~> 2.0` beside
          # `rails 4.1.0` makes every era's `bundle install` fail on `railties (< 5, >=
          # 4.2.0.alpha)` against `railties (= 4.1.0)`, so no interpreter is chosen and the step
          # is unverified. This stage runs *before* the pin is rewritten — it has to, because the
          # machine choice is itself a `bundle install` — so a declaration scoped to the rung is
          # deferred to `Step#declare_for_the_rung`, which runs after the pin and before its
          # resolve. A declaration scoped only by the interpreter is applied here: it is about
          # the machine rather than about the release the Gemfile names.
          if rung_scoped?(entry)
            deferred << entry
            notes << "the digest's declaration for #{name} waits for the pin: it is scoped by " \
                     "#{condition_sentence(entry)}, and the Gemfile still names the release this " \
                     "step starts from — the declaration is applied once the pin is rewritten"
            return
          end

          return declare(entry, declaration(name), repairs, decisions, notes)
        end

        # **A gem's own upgrade can need an edit to the application's code, and which stage it belongs
        # to is the entry's clause.** A companion is that rule (see `Companions`), and the two
        # timings are the same two the digest's own entries have: an entry scoped by the *interpreter*
        # is a fact about the machine, so its gem has already moved by the time the baseline runs and
        # the suite the baseline measures is the one that needs the edits; an entry scoped by the
        # *rung* moves at the pin, so its edits belong at the gems stage, after the baseline and
        # before the pin's resolve — `Step#apply_companions`, keyed to the route's own move, which is
        # why nothing is done for one here.
        apply_companion(entry, repairs, notes) unless rung_scoped?(entry)

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

        # **A rewrite scoped to the rung waits for the pin, exactly as a declaration does.** The
        # line the digest names is a fact about the framework being moved to — actionpack 6.0 asks
        # `loofah (~> 2.2, >= 2.2.2)` — and beside the release the Gemfile still names it is not
        # merely early, it is wrong: measured at the 6.0 rung, moving `loofah ~> 2.0.3` to the line
        # the rung states let the bundle stage's own conservative update take loofah 2.21.1 while
        # nokogiri stayed at the 1.9.1 the 5.2 stack needs, and the 5.2 baseline died on
        # `uninitialized constant Nokogiri::HTML4` — a green baseline turned red by a line that rung
        # had not asked for yet. Interpreter-scoped entries are the other half and stay here: those
        # are facts about the *machine*, and the install that chooses it has to see them.
        if rung_scoped?(entry)
          deferred << entry
          notes << "the digest's entry for #{name} waits for the pin: it is scoped by " \
                   "#{condition_sentence(entry)}, and the line it rewrites is a fact about that " \
                   "release rather than about the one the Gemfile still names"
          return
        end

        rewrite_declared(entry, found, repairs, notes)
      end

      # **The rule of a gem's own upgrade, applied where the entry's clause says it belongs.** The
      # digest moves a line and `Companions` holds the edits a gem's own release forces on the
      # application's files; both are the same fact seen twice, and the companion is keyed to the
      # digest's own requirement so the two cannot drift.
      #
      # Only an entry a machine may act on has a companion applied: `mechanical` is the digest's
      # statement that the line moves, and a companion is the code edits *of that move* — applied
      # beside a line nobody moved, they would be edits for a gem state the application is not in.
      # The edits go through the applier, so they are line-checked and recorded exactly as every other
      # edit this tool makes, and a refusal is a note rather than a silent nothing.
      def apply_companion(entry, repairs, notes)
        return unless entry["mechanical"] == true

        companion = Companions.for(entry["gem"], entry["requirement"])
        return if companion.nil?

        edits = Companions.edits(companion, root: @root)
        if edits.empty?
          # **An empty list is two facts and the record has to tell them apart.** The file already
          # carries the insert (a move a person finished, and no note is owed) or no file here carries
          # its anchor — and that second one is a suite that will stay red with nothing in the record
          # saying why, which is the failure this whole stage exists to prevent.
          unless Companions.placed?(companion, root: @root)
            notes << "the companion for #{entry["gem"]} had nothing to apply: none of " \
                     "#{Array(companion.inserts).map(&:path).join(", ")} carries the anchor its edits " \
                     "go beside, so #{companion.note}"
          end
          return
        end

        result = Applier.new(@root).apply(edits.map(&:to_h))
        repairs.concat(result.applied)
        result.refused.each do |refusal|
          notes << "the companion for #{entry["gem"]} refused an edit at #{refusal.path}:" \
                   "#{refusal.line} — #{refusal.reason}"
        end
      end

      # **One mechanical rewrite of a line the application already declares.** The digest names the
      # release or the requirement; this writes the line. Two things are refused rather than guessed:
      # a declaration it cannot parse in full (`unrewritable`) and a kind it has no rewrite for. A
      # line that already reads the way the digest asks is not an edit — a second pass over a tree,
      # or a line the application moved itself, is a repair list with nothing in it.
      def rewrite_declared(entry, found, repairs, notes)
        name = entry["gem"].to_s
        index, line = found
        skip = unrewritable(line, kind: entry["kind"].to_s)
        if skip
          notes << "Gemfile:#{index + 1} declares #{name} as `#{line.strip}`, which #{skip}; " \
                   "#{entry["note"]}"
          return nil
        end

        after = rewrite(entry, line)
        if after.nil?
          notes << "the digest says #{name} becomes #{entry["replacement"] || "nothing"}; " \
                   "this tool has no rewrite for that"
          return nil
        end
        return nil if after == line

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

      # **A declaration is the repair, and it is for a gem the application does not hold yet.**
      # The kind exists because the hold the pin keeps cannot see this case: a gem that *arrives*
      # with the framework has no earlier version in the lock to be put back, so the resolver takes
      # its newest — and on an old interpreter that newest can be a release whose code needs a
      # nokogiri the interpreter cannot install. Measured at the 4.2 rung: Rails 4.2 brings in
      # `rails-html-sanitizer`, which brings in loofah 2.21.1, whose code needs `Nokogiri::HTML4`
      # while Ruby 2.1 caps nokogiri at 1.9.1, and `rails:update` died on the constant.
      #
      # The application's own line is the application's: a gem it already declares is left alone
      # (the digest is not asked about a line it did not write). And a condition that cannot be
      # evaluated is a *note*, not a silent pass — the honest half of this is saying which
      # declarations were not applied and why.
      def declare(entry, found, repairs, decisions, notes)
        name = entry["gem"].to_s
        return if found

        unless entry["mechanical"] == true
          decisions << decision(entry, path: "Gemfile", line: nil, reason: entry["note"])
          return
        end

        line = %(gem "#{name}", "#{entry["requirement"]}")
        gemfile = File.join(@root, "Gemfile")
        text = File.binread(gemfile)
        separator = text.empty? || text.end_with?("\n") ? "" : "\n"
        File.binwrite(gemfile, "#{text}#{separator}#{line}\n")
        repairs << Repair.new(path: "Gemfile", line: nil, text: nil, after: line,
          subject: name, note: entry["note"])
      end

      # Whether the entry's condition holds for the interpreter this move will run on. The one
      # condition the digest states so far is a Ruby floor, and no interpreter means the condition
      # cannot be evaluated at all — which is `false` here and a note at the call site.
      # **Whether an entry's condition holds for this move, clause by clause, and every clause must.**
      # The vocabulary is small on purpose — a digest entry is a fact about an era, and an era is named
      # by the two things a move knows about itself:
      #
      # * `ruby_below` / `ruby_at_least` — the interpreter the move will run on, which this stage
      #   knows as the rung's floor (see `initialize`: the machine is chosen after this, and the
      #   choice is a `bundle install`);
      # * `rails_below` / `rails_at_least` — the release the move ends at, which is what lets a gem
      #   have to move twice in one walk.
      #
      # A clause this stage cannot evaluate makes the whole entry inapplicable: an unnamed interpreter,
      # a rung in a mode that was not told one, or a clause this build does not know. The call site
      # says which, so a skipped entry is visible rather than silent.
      def holds?(entry)
        condition = entry["when"]
        return true unless condition.is_a?(Hash)

        condition.all? { |clause, value| clause_holds?(clause.to_s, value.to_s.strip) }
      end

      # The clauses this build knows. Named once, because the evaluator and the sentence that says
      # *why* an entry did not apply have to agree about the vocabulary — an unknown clause is a note,
      # not a silent skip. Each fact has both a floor and a ceiling: a gem can be too new for an old
      # interpreter (`ruby_below`, where the *newest* installable release is the problem) or too old
      # for a new one (`ruby_at_least`, where the release's own C source does not compile — measured
      # on the 5.0 rung, json 1.7.7's `rb_str_new` call against Ruby 2.2's variadic macro).
      KNOWN_CLAUSES = %w[ruby_below ruby_at_least rails_below rails_at_least].freeze

      # The two clauses that name the *rung* rather than the machine. A `declared` entry scoped
      # by one of them is about the framework the gem arrives with, so it is deferred until the
      # Gemfile names that framework (`digest_repair`).
      RUNG_CLAUSES = %w[rails_below rails_at_least].freeze

      def rung_scoped?(entry)
        condition = entry["when"]
        condition.is_a?(Hash) && condition.keys.any? { |clause| RUNG_CLAUSES.include?(clause.to_s) }
      end

      def clause_holds?(clause, value)
        return true if value.empty?
        return false unless KNOWN_CLAUSES.include?(clause)

        named = clause.start_with?("ruby") ? @ruby : @rails
        return false if named.empty?

        if clause.end_with?("_at_least")
          Gem::Version.new(named) >= Gem::Version.new(value)
        else
          Gem::Version.new(named) < Gem::Version.new(value)
        end
      end

      # **Why an entry did not apply, in the cases that differ.** A condition this move does not meet,
      # a clause this build does not know, and a clause whose fact this stage was never told (no
      # interpreter in a mode that has no machine, no rung in a mode asked about a repository) are
      # three different reasons, and a sentence that said "did not apply" for all of them would hide
      # the one a caller can act on — telling the walker the rung, or the digest author the clause.
      def why_not(entry)
        condition = entry["when"]
        return "this move does not meet it" unless condition.is_a?(Hash)

        unknown = condition.keys.reject { |clause| KNOWN_CLAUSES.include?(clause.to_s) }
        return "it states #{unknown.join(", ")}, which this build does not know" if unknown.any?

        unnamed = condition.keys.select { |clause| (clause.to_s.start_with?("ruby") ? @ruby : @rails).empty? }
        if unnamed.any?
          return "it is scoped by #{unnamed.join(", ")}, and this stage was not told " \
                 "#{unnamed.map { |clause| clause.to_s.start_with?("ruby") ? "the interpreter" : "the rung" }.uniq.join(" or ")}"
        end

        "this move does not meet it"
      end

      # The condition as a reader can check it, for the note that says why an entry did not apply.
      def condition_sentence(entry)
        condition = entry["when"]
        return "none stated" unless condition.is_a?(Hash)

        condition.map { |clause, value| "#{clause} #{value}" }.join(", ")
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
        if kind == "require_false"
          # A line that already names its own `require:` has made this decision for itself —
          # either it is already `require: false` (nothing to do) or it asks for something
          # this class will not second-guess. And the option-token check below deliberately
          # does not apply to this kind: the rewrite *appends* an option, so a `group:` or a
          # version on the line is kept, not dropped.
          return "already states its own require:" if line.match?(/require:/)
          return "carries a comment this class will not risk rewriting around" if line.match?(/\s#/)

          return nil
        end
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
        when "require_false"
          # The gem stays where the application put it and gains one option: Bundler still
          # installs it, and nothing requires it at boot. Appended rather than rebuilt, so a
          # line carrying a `group:` or a version keeps both.
          "#{line.rstrip}, require: false"
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

      # **What the application has locked, for the one question the digest cannot answer by
      # itself.** The entry's `when` names an era; it cannot name the application's own release
      # of the gem, and a modern app is not the one the entry was measured on.
      def locked_version(name)
        locked_versions[name.to_s]
      end

      # **`nil`, not `{}`, when the lockfile cannot be read.** "This application locks nothing"
      # and "this cannot tell what it locks" are different answers, and only the first is safe to
      # read as "no version is newer than the digest's line".
      #
      # Read through `Lockfile`, not a second bare `Bundler::LockfileParser`: a vendored gem makes
      # the parser resolve its relative `remote:` against Bundler's root, and a step runs in a
      # container whose cwd is not the application. `Lockfile` anchors that root at the lockfile
      # (its own docstring says why); a second reader here was a second answer, and on a tree that
      # vendors `js_image_paths` it was the wrong one.
      def locked_versions
        return @locked_versions if defined?(@locked_versions)

        @locked_versions =
          begin
            Lockfile.read(@root).specs
          rescue Lockfile::Missing
            {}
          rescue Lockfile::Unreadable
            nil
          end
      end

      # The version a requirement stops before: the `~>` bump, or a `<` clause. An `=` pin is
      # deliberate (mimemagic is the case) and has no upper bound here — the guard protects
      # against a line that is *behind* the application, not against a pin the digest means.
      def upper_bound(requirement)
        parsed = Gem::Requirement.new(requirement.to_s)
        op, version = parsed.requirements.first
        return version.bump if op == "~>"
        return version if %w[< <=].include?(op)

        nil
      rescue ArgumentError
        nil
      end

      # **A forced entry is the one case where below the application is the repair.** The guard
      # above exists because a curated line was measured on an application from an older era, and
      # moving a newer application down to it is a regression the resolver will notice. `forced`
      # is the digest saying the opposite: the *rung* cannot carry the line the application wrote
      # — Rails 7.2 caps `minitest` below 6 while an application pinned 6.0.3 — so the move back is
      # the only resolution there is. Measured on diaspora's 7.2 rung: the pin exited 6 with
      # `version solving has failed`, before any stage could measure anything else.
      def newer_than_entry?(name, entry)
        return false if entry["forced"] == true

        current = locked_version(name)
        upper = upper_bound(entry["requirement"])
        return false if current.nil? || upper.nil?

        Gem::Version.new(current) >= upper
      rescue ArgumentError
        false
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
