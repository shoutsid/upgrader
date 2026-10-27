# frozen_string_literal: true

require "json"

module Agents
  module Upgrader
    # The interpreters a step may execute on, and which one it is allowed to pick.
    #
    # A Rails move is a *sequence* of releases whose Ruby floors climb (4.2 wants 1.9.3,
    # 5.0 wants 2.2.2, 6.0 wants 2.5, 7.0 wants 2.7, 8.0 wants 3.2), and an application old
    # enough to be interesting cannot be installed on the interpreter running this tool.
    # Tomorrow's ledger comment says it in one line: an application that cannot be walked on
    # Ruby 3.3 may be walkable on 2.7, which is the whole reason a verdict is stamped with
    # the machine that produced it.
    #
    # So the interpreters are *data* (`data/interpreters.json`, shipped with the client the
    # way the miner ships its download snapshot) and this module is the two decisions over
    # it: which interpreters satisfy a step's floor, and which of those to try first.
    #
    # **The matrix starts at 2.1, and that is a fact about an index rather than a taste.**
    # `ruby:2.0` is no longer served by Docker Hub — `docker manifest inspect ruby:2.0`
    # answers "missing" — and the oldest base that still pulls is `ruby:2.1`. An application
    # whose floor is below that is refused by name ("no interpreter in the matrix satisfies
    # ...") rather than silently run on something newer, because a floor a machine cannot
    # meet is exactly the fact the refusal exists to carry.
    #
    # **Selection is oldest-first, from a starting point the application states.** The
    # candidates are the matrix's entries at or above the step's floor, in ascending order;
    # a `ruby` line in the Gemfile or a `RUBY VERSION` in the lockfile says where the
    # application last succeeded, and the walk starts there rather than at the oldest era.
    # What the application states is a *hint* and never the answer: the answer is which
    # interpreter installs the bundle, and `Step` probes that by running `bundle install`
    # (`Machine`), because a declared version can be absent from the matrix and a lockfile
    # can be lying. The one thing this module will not do is guess upward silently: every
    # probe outcome travels in the record.
    module Interpreters
      # Where the matrix lives, beside the client rather than in the repository root: the
      # image copies `lib/`, and a data file the image did not copy is a matrix that reads
      # as empty in the deployment and complete everywhere else.
      MATRIX_PATH = File.expand_path("data/interpreters.json", __dir__)

      # The image ref of each era, overridable as `name=ref` pairs. This is how a deployment
      # pins digests (`2.1=agents-upgrader-ruby-2.1@sha256:…`) without a code change, and
      # how a test points the selection at an image that exists.
      OVERRIDES_ENV = "UPGRADER_INTERPRETER_IMAGES"

      # One era, as the matrix declares it: a name a human says ("2.2"), the interpreter's own
      # full version (compared against a step's floor, so it must be the *image's* version —
      # `2.2.10`, not `2.2`), the image reference, the base image's pin, and the era's facts.
      Entry = Struct.new(:name, :ruby, :image, :base, :bundler, :rvm, keyword_init: true) do
        def to_h
          { "name" => name, "ruby" => ruby, "image" => image, "base" => base,
            "bundler" => bundler, "rvm" => rvm }
        end

        # The rvm name of this era's interpreter, which is what `rvm install <version>`
        # produces — `ruby-2.1.10`. A deployment that names it differently (a patched build, a
        # non-rvm manager with an rvm-compatible layout) says so in the matrix, because the
        # alternative is a host whose interpreter the walker cannot find and a sentence that
        # does not say why.
        def rvm_name = rvm.to_s.empty? ? "ruby-#{ruby}" : rvm.to_s
      end

      # The matrix could not be read, or an entry in it is not one of these.
      class Invalid < StandardError; end

      class << self
        # The matrix, ascending by interpreter version, with any image overrides applied.
        #
        # Sorted here rather than trusted to be sorted: the candidate order *is* the
        # selection rule, and a file that is one line out of order would silently probe an
        # era before one that is older. A duplicate name is refused: two entries a person
        # cannot tell apart is a matrix whose selection depends on file order.
        def matrix(path: MATRIX_PATH, images: nil)
          payload = JSON.parse(File.read(path, encoding: "utf-8"))
          rows = payload.fetch("interpreters")
          overrides = images || overrides_from(ENV)
          entries = rows.map { |row| entry(row, overrides) }
          names = entries.map(&:name)
          raise Invalid, "#{path} declares #{names.uniq.size} name(s) for #{names.size} entrie(s)" if
            names.uniq.size != names.size

          # `sort_by` rather than `sort` with a comparison block, because it calls the key once
          # per entry: a one-row matrix never invokes a comparison block at all, so a version
          # nobody can place would pass validation unnoticed until the row stopped being alone.
          entries.sort_by { |candidate| place(candidate) }
        rescue JSON::ParserError, KeyError, TypeError => e
          raise Invalid, "#{path} is not an interpreter matrix: #{e.message}"
        end

        # The entries a step at this floor may run on, in the order to try them.
        #
        # `preferred` is the era a previous attempt actually used, as the ledger recorded it;
        # it is moved to the front when it is still in the matrix and still meets the floor.
        # Without it, an application whose floor is met by 2.1 but whose bundle only installs
        # on 2.2 would re-probe 2.1 on every cycle — a probe is a bundle resolve, and the
        # ledger exists to stop that.
        # The three declarations are ranked, because they are statements of different strength:
        # the Gemfile's `ruby` line is one Bundler *enforces*, `RUBY VERSION` in the lockfile is
        # what the application last resolved under, and `.ruby-version` is only what a developer
        # happened to have installed. The first one that exists is the hint, and none of them is
        # ever treated as a floor — that is the rung's `requires_ruby`.
        #
        # **A declaration may name the eras it will accept.** `only` is the project's `eras`
        # field, and it is a constraint rather than a hint: the walk tries the named
        # interpreters in the order the operator wrote them, and an era the list names that
        # does not meet the rung's floor is not tried at all. A project that says "3.2" on an
        # application whose CI runs 3.2 must not spend a bundle resolve on 2.7 just because
        # that is the oldest era the rung allows.
        def candidates(requires_ruby: nil, declared: nil, locked: nil, dot: nil, preferred: nil,
                       only: nil, images: nil, path: MATRIX_PATH)
          pool = matrix(path: path, images: images)
                 .select { |entry| meets?(entry.ruby, requires_ruby) != false }
          if only
            named = Array(only).map(&:to_s)
            pool = named.filter_map { |name| pool.find { |entry| entry.name == name } }
          else
            hinted = [declared, locked, dot].map { |value| value.to_s.strip }.find { |value| !value.empty? }
            pool = pool.rotate(start_at(pool, hinted.to_s))
          end
          return pool unless preferred

          found = pool.index { |entry| entry.name == preferred.to_s }
          found ? pool.rotate(found) : pool
        end

        # One era by name, or nil.
        def named(name, images: nil, path: MATRIX_PATH)
          matrix(path: path, images: images).find { |entry| entry.name == name.to_s }
        end

        # Whether an interpreter version satisfies a requirement string.
        #
        # `Gem::Version` is the ordering, because every version in play here was published to
        # an index that uses it. An empty requirement is met by everything; a requirement this
        # reader cannot place is met by nothing, and the difference matters: the second is a
        # malformed floor rather than an absent one, and refusing to *place* it (nil) says so
        # rather than guessing either way.
        def meets?(version, requirement)
          return true if requirement.to_s.strip.empty?
          return false if version.to_s.strip.empty?

          floor = Gem::Version.new(requirement.to_s.strip)
          mine = Gem::Version.new(version.to_s.strip)
          mine >= floor
        rescue ArgumentError
          nil
        end

        def overrides_from(env)
          raw = env[OVERRIDES_ENV].to_s.strip
          return {} if raw.empty?

          raw.split(",").to_h do |pair|
            name, ref = pair.split("=", 2)
            [name.to_s.strip, ref.to_s.strip]
          end
        end

        private

        def entry(row, overrides)
          name = row.fetch("name").to_s
          raise Invalid, "an interpreter entry has no name" if name.empty?

          image = overrides[name] || row.fetch("image").to_s
          # A bare digest is the pin an operator naturally writes, so it inherits the matrix
          # image's repository rather than becoming a daemon reference that starts with
          # `sha256:` and names no image at all. A full reference is used as written.
          if image.start_with?("sha256:")
            repository = row.fetch("image").to_s.split("@", 2).first.sub(/:[^:\/]+\z/, "")
            image = "#{repository}@#{image}"
          end

          Entry.new(
            name: name, ruby: row.fetch("ruby").to_s, image: image,
            base: row.fetch("base").to_s, bundler: row.fetch("bundler").to_s,
            rvm: row["rvm"].to_s
          )
        end

        # Where in the ascending pool to start: the first entry that could satisfy what the
        # application states about its interpreter. A version above the whole matrix starts at
        # the newest entry rather than at the oldest, and there is a measured reason rather
        # than a defensive one: the subset of the pool that satisfies a floor *increases*
        # with the interpreter version only in the direction the matrix is sorted, so a
        # starting point above the top means "nothing here is known to be enough", and the
        # newest entry is the closest thing to an answer the machine has.
        #
        # **What an application usually states is a *requirement*, and reading it as a bare
        # version made it no hint at all.** A Gemfile's `ruby` line is Bundler's own directive, so
        # `ruby '~> 3.2.0'` is the shape most applications write; `Gem::Version` cannot place it,
        # which used to mean "start at the oldest era". Measured on `rails_modular_monolith`: 2.1,
        # 2.2, 2.5, 2.7 and 3.1 were each started and apt-installed and five bundles resolved to
        # refusal, four minutes before the era the application declares was tried. A requirement is
        # answered as one — the first era it *accepts* — and a bare version keeps the at-or-above
        # rule, because `ruby "3.2.2"` names what the developer had rather than demanding exactly
        # that patch of every machine.
        #
        # A hint this reader can place neither way is not a hint, and starting from the first entry
        # assumes nothing about it.
        def start_at(pool, hint)
          return 0 if hint.empty?

          requirement = requirement_for(hint)
          if requirement
            index = pool.index { |candidate| accepts?(requirement, candidate.ruby) }
            return index || [pool.size - 1, 0].max
          end

          return 0 unless placeable?(hint)

          index = pool.index { |candidate| meets?(candidate.ruby, hint) }
          index || [pool.size - 1, 0].max
        end

        # The hint as a requirement, or nil when it is a bare version.
        #
        # Only an operator makes a string a requirement. `Gem::Requirement` reads a bare version as
        # an *equality*, and no era satisfies one: a matrix entry is a patch (`3.2.11`) while a
        # declaration is whatever that developer ran (`3.2.4`), so treating `3.2.4` as `= 3.2.4`
        # would answer "nothing here is enough" for the era that is.
        def requirement_for(hint)
          text = hint.to_s.strip
          return nil unless text.match?(/[<>=~,]/)

          Gem::Requirement.new(text)
        rescue Gem::Requirement::BadRequirementError
          nil
        end

        def accepts?(requirement, version)
          requirement.satisfied_by?(Gem::Version.new(version.to_s.strip))
        rescue ArgumentError
          false
        end

        def placeable?(version)
          Gem::Version.new(version.to_s.strip)
          true
        rescue ArgumentError
          false
        end

        def place(entry)
          Gem::Version.new(entry.ruby)
        rescue ArgumentError
          raise Invalid, "#{entry.name} declares `#{entry.ruby}`, which is not a version"
        end
      end
    end
  end
end
