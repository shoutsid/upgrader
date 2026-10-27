# frozen_string_literal: true

require "json"

module Agents
  module Upgrader
    # **A project is an application the walk can be pointed at, declared rather than coded.**
    #
    # Everything here is a fact about *somebody's* application: where it lives, which ref the walk
    # starts from, which releases it moves between, how its suite runs, which services it needs, which
    # environment *names* its suite reads, which interpreters it may use, and where a passed rung is
    # delivered. None of it belongs to the engine. Measured on the first complete walk, the engine
    # named `bin/rails`, `bundle exec rspec`, `agents-services`, `RAILS_SECRET_TOKEN`, the era image
    # prefix and the GitHub target, and every one of those is a property of one application
    # (see `docs/design-notes.md`).
    #
    # A project names a **stack** — `rails` today — whose pack knows what a release changes and how a
    # command is spelled for it. The project says *which* of the stack's commands to run and what its
    # suite is called; the pack says how to run them.
    class Project
      # The fields a declaration may carry. **An unknown key is an error rather than a comment:** a
      # typo is a setting that silently does nothing, and a walk that ignores a setting its operator
      # believes is in force is the failure this class exists to prevent.
      FIELDS = %w[slug repo base_ref from to path_policy next_checkpoint stack suite services
        env_names eras delivery decisions brief_decisions source_roots checks toolchain style
        app_update repair].freeze

      # **The account's permission for a model repair, published with the project.** The service's
      # feed carries it on every row because it is the account's setting applied to this project;
      # `off` is the mechanical default and the absence of a field (a feed from before this
      # existed) is the deployment's own switch, which is what every walk had.
      REPAIR_POLICIES = %w[off fallback].freeze

      # **Where a walk stops next, and by which rule.** A project connected before paths existed has
      # neither field and walks to `to`, exactly as it always did; the two are optional on purpose,
      # because the service and the client are deployed apart and the older side must keep working.
      PATH_POLICIES = %w[minor latest_patch every_patch].freeze

      # The fields one accepted decision carries in a declaration. It is the site admin's rendering of
      # `decision_questions`/`answers`/`effects` — the row is the record, this is the delivery — and a
      # key nobody reads is a refusal here for the same reason every other unknown key is: a typo is
      # a setting that silently does nothing.
      # `project` and `change_key` are how a decision from another application is recognisable in
      # this one: the same key is the same change, and the project says whose answer it was. They
      # are optional because a declaration written before the join existed has neither.
      DECISION_FIELDS = %w[id project change_key question answer accepted_by effects
        verified_by_run_id accepted_by_policy review risk_class acceptance].freeze
      EFFECT_FIELDS = %w[id kind payload applies_when phase].freeze

      # What a suite can be. `none` is a real answer, not a missing one: an application without a
      # suite is measured by its boot, and a declaration that says so is not one typo away from a
      # declaration that forgot.
      SUITES = %w[rspec minitest none].freeze

      # Where a passed rung is delivered. `none` is a repository the walk may still commit to but has
      # nowhere to open a request for — the patch and the record are then the product.
      PROVIDERS = %w[github none].freeze

      # **A check is one thing the application's own gate runs, and the suite is only one of them.**
      # Measured on the first walks, a green `bundle exec rspec` was treated as the whole gate while
      # the application's CI also ran packwerk, rubocop and a JavaScript build. A check that is not
      # declared is not therefore green; the PR says which checks were not run.
      CHECK_KINDS = %w[test lint static build prepare external].freeze

      # The environments a check can name. `ci` is deliberately not "the same as test": it says the
      # command is the application's CI command and this machine cannot reproduce that environment.
      CHECK_ENVIRONMENTS = %w[test development ci].freeze

      # What an `app_update` policy may say. `added_only` is the only adoption rule this build
      # implements: a file the application already owns keeps the application's version and the
      # conflict is recorded, because overwriting it is a decision and not a safeguard.
      APP_UPDATE_ADOPTS = %w[added_only].freeze

      # How new framework defaults are treated: `off` means `app:update` writes the initializer and
      # the walk leaves `config.load_defaults` alone; `step` lets `UPGRADER_DEFAULT_STEPS` spend a
      # suite run per toggle, exactly as before. The declaration is the policy; the environment is
      # the budget.
      FRAMEWORK_DEFAULTS = %w[off step].freeze

      # The default destination of a branch a rung is published on. `<release>` is the rung's target
      # release, which is what makes one branch per rung the default shape rather than a convention.
      DEFAULT_BRANCH = "agents/upgrade-<release>"

      # An environment *name*, never a value: `RAILS_SECRET_TOKEN`, not `RAILS_SECRET_TOKEN=…`. The
      # value lives in the deployment (a compose secret, a `suite.env` on the walker's volume) and a
      # project file that carried one would be a secret written into an image and into every record
      # that ever prints the declaration.
      ENV_NAME = /\A[A-Z][A-Z0-9_]*\z/

      # Where the declarations live, beside the client rather than in the repository root: the image
      # copies `lib/`, and a data file the image did not copy is a declaration that reads as absent in
      # the deployment and present everywhere else.
      PROJECTS = File.expand_path("data/projects", __dir__)

      class Invalid < StandardError; end

      # The suite: its dialect, and the command the pack runs it with.
      Suite = Struct.new(:kind, :command, keyword_init: true) do
        def none? = kind == "none"

        def to_h = { "kind" => kind, "command" => command }
      end

      # Where a rung is delivered, and whether each request targets the rung before it.
      Delivery = Struct.new(:provider, :branch, :chain, :publish, :deploy, keyword_init: true) do
        def github? = provider == "github"

        def branch_for(release) = branch.to_s.gsub("<release>", release.to_s)

        # `publish` is the account's handoff switch (`off`/`branch`/`pr`), not a deploy switch. A
        # response from an older service omits it and means `off`, which is the safe default.
        # `deploy` is read-only context the pull-request body names; the walker never runs it.
        def to_h
          { "provider" => provider, "branch" => branch, "chain" => chain,
                     "publish" => publish, "deploy" => Array(deploy) }
        end
      end

      # One command in the application's gate. `external` is the honest answer for a check this
      # walker cannot run — the application's GitHub Actions job is the case that produced it — and
      # an external check must say *where* it runs, because "not run here" without a reason is
      # indistinguishable from a check somebody forgot to declare.
      Check = Struct.new(:id, :name, :kind, :command, :required, :external, :environment, :reason,
        keyword_init: true) do
        def external? = external

        def local? = !external

        def label = name.to_s.empty? ? id : name

        def to_h
          { "id" => id, "name" => name, "kind" => kind, "command" => command,
            "required" => required, "external" => external, "environment" => environment,
            "reason" => reason }.compact
        end
      end

      # The application's build facts. They are carried and quoted now; the overlay image that
      # spends them is a later phase, and a field that is declared but not yet consumed is still a
      # fact a reviewer can check against the application's CI.
      # The account's repair permission and the model chain it names. `off` is a decision (no
      # model, however the deployment is configured); `fallback` is a permission the deployment's
      # budget still has to allow. An empty chain means the deployment's `UPGRADER_REPAIR_MODEL`.
      Repair = Struct.new(:policy, :models, keyword_init: true) do
        def off? = policy == "off"
        def fallback? = policy == "fallback"
        def model_chain = Array(models)
        def to_h = { "policy" => policy, "model" => model_chain.join(",") }.compact
      end

      # **A browser version is a fact about the application's test stack, not about the era.** The
      # pair a step drives has to speak the protocol the application's `selenium-webdriver` was
      # written for, and an era image's distribution browser moves under that stack: measured on
      # `ohana-api`, 19 `:js` examples failed on bookworm's Chromium 156 and none on 120, same tree
      # and same bundle. So `chrome` is a declaration, and **its presence is the claim itself** —
      # the suite drives a browser — with its value naming which build: `pinned` (the one the era
      # image verified) or `distro` (the release's own package). A project with no browser in its
      # suite leaves the key out, and no browser stage runs for it; most Rails applications are that
      # project.
      Toolchain = Struct.new(:ruby, :node, :postgres, :extensions, :apt, :native, :chrome,
        keyword_init: true) do
        # The browser this suite is measured on, or empty when it drives none.
        def browser = chrome.to_s.strip

        def to_h
          { "ruby" => ruby, "node" => node, "postgres" => postgres,
            "extensions" => extensions, "apt" => apt, "native" => native,
            "chrome" => chrome }.compact
        end
      end

      # What the walk may do with the files `app:update` generates, and whether it may turn a
      # framework default on. The two are separate on purpose: adopting a generated file is a fact
      # about the application's configuration, and flipping a default is a change the suite must
      # judge one at a time.
      AppUpdate = Struct.new(:adopt, :skip, :skip_unused_engines, :framework_defaults,
        keyword_init: true) do
        def skip?(path)
          skip.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME) }
        end

        def step_defaults? = framework_defaults == "step"

        def to_h
          { "adopt" => adopt, "skip" => skip, "skip_unused_engines" => skip_unused_engines,
            "framework_defaults" => framework_defaults }
        end
      end

      # The formatter and the check that verifies it. `format` may write; `check` is the same
      # question asked without writing, and it is added to the gate as a check when it is declared.
      Style = Struct.new(:format, :check, keyword_init: true) do
        def to_h = { "format" => format, "check" => check }.compact
      end

      attr_reader :slug, :repo, :base_ref, :from, :to, :path_policy, :next_checkpoint, :stack, :suite,
        :services, :env_names, :eras, :delivery, :decisions, :brief_decisions, :source_roots,
        :checks, :toolchain, :style, :app_update, :repair, :path

      # The declaration named by a slug, from the projects directory.
      #
      # **The site admin's directory is read first, and the built-in declarations are the fallback.**
      # The operator edits the declaration on the site admin, which writes it into a volume this client
      # mounts read-only; a project the site admin has not written still walks from the copy this image
      # ships, so an empty volume is the built-in behaviour rather than no behavior. A written
      # declaration shadows the built-in of the same slug — that is what editing means — and the
      # walker validates it here, so a declaration the site admin got wrong is refused by name at
      # startup rather than walked halfway.
      def self.find(slug, dir: nil)
        candidates = directories(dir)
        candidates.each do |candidate|
          path = File.join(candidate, "#{slug}.json")
          return load(path) if File.file?(path)
        end

        raise Invalid, "no project named #{slug.inspect} in #{candidates.join(", ")}"
      end

      # **The declaration for a repository, which is how a queue row finds its own application.**
      # A target says *which* repository; a declaration says *how* to walk it. Matching them is what
      # lets one walker serve several applications without being told which declaration goes with
      # which queue row — the order is the service's, the facts are the declaration's.
      def self.find_by_repository(reference, dir: nil)
        wanted = Repository.name(reference)
        all(dir: dir).find { |project| Repository.name(project.repository) == wanted }
      end

      # Every declaration this process can see, keyed by slug with the site admin's copy winning. An
      # unreadable declaration is skipped here rather than raised: `find` is where a named project
      # says why it cannot be read, and one bad file must not hide the others.
      def self.all(dir: nil)
        by_slug = {}
        directories(dir).each do |candidate|
          Dir[File.join(candidate, "*.json")].sort.each do |path|
            slug = File.basename(path, ".json")
            next if by_slug.key?(slug)

            begin
              by_slug[slug] = load(path)
            rescue Invalid
              next
            end
          end
        end
        by_slug.values
      end

      def self.directories(dir = nil)
        [dir, ENV["UPGRADER_PROJECTS_DIR"], PROJECTS].compact.map(&:to_s).reject(&:empty?).uniq
      end

      # The clone URL this declaration means. A declaration may carry `owner/name` (what a person
      # types) or a URL; every command clones the normalized one, so a plan and a walk of the same
      # project cannot disagree about the repository.
      def repository = Repository.normalize(@repo)

      def self.load(path)
        text = File.read(path, encoding: "utf-8")
        parse(text, path: path)
      rescue Errno::ENOENT
        raise Invalid, "no project declaration at #{path}"
      end

      # A declaration, validated. Public because the site admin will write one and has to be able to ask
      # whether it is valid before storing it (see `docs/design-notes.md`).
      def self.parse(text, path: nil)
        parsed = JSON.parse(text.to_s)
        raise Invalid, "a project declaration is an object, not #{parsed.class}" unless parsed.is_a?(Hash)

        new(parsed, path: path)
      rescue JSON::ParserError => e
        raise Invalid, "the project declaration is not JSON: #{e.message.to_s.lines.first.to_s.strip}"
      end

      def initialize(fields, path: nil)
        @path = path
        unknown = fields.keys - FIELDS
        unless unknown.empty?
          raise Invalid, "unknown field(s) in the project declaration: #{unknown.sort.join(", ")} — " \
                         "known: #{FIELDS.join(", ")}"
        end

        @slug = required(fields, "slug")
        @repo = required(fields, "repo")
        @from = required(fields, "from")
        @to = required(fields, "to")
        @path_policy = read_path_policy(fields["path_policy"])
        @next_checkpoint = optional_text(fields, "next_checkpoint")
        @base_ref = optional_text(fields, "base_ref")
        @stack = optional_text(fields, "stack") || "rails"
        @suite = read_suite(fields["suite"])
        @services = read_names(fields["services"] || [], "services")
        @env_names = environment_names(fields["env_names"] || [])
        @eras = read_eras(fields["eras"])
        @delivery = read_delivery(fields["delivery"])
        @decisions = read_decisions(fields["decisions"])
        # **A brief decision is recall, not an applied effect.** The site admin writes the same
        # project's answers under `decisions` and the same change answered on another project under
        # `brief_decisions`; the brief shows both, and only `decisions` reaches `Effects`. That is
        # ADR 0011's "nothing from recall is applied automatically" made structural.
        @brief_decisions = read_decisions(fields["brief_decisions"])
        @source_roots = read_source_roots(fields["source_roots"])
        @checks = read_checks(fields["checks"])
        @toolchain = read_toolchain(fields["toolchain"])
        @style = read_style(fields["style"])
        @repair = read_repair(fields["repair"])
        @app_update = read_app_update(fields["app_update"])
      end

      # The declaration as it would be written back — what the site admin edits and what a record quotes.
      def to_h
        {
          "slug" => slug, "repo" => repo, "base_ref" => base_ref, "from" => from, "to" => to,
          "path_policy" => path_policy, "next_checkpoint" => next_checkpoint,
          "stack" => stack, "suite" => suite.to_h, "services" => services,
          "env_names" => env_names, "eras" => eras, "delivery" => delivery.to_h,
          "decisions" => decisions, "brief_decisions" => brief_decisions,
          "source_roots" => source_roots,
          "checks" => checks.map(&:to_h), "toolchain" => toolchain&.to_h,
          "style" => style&.to_h, "app_update" => app_update.to_h,
          "repair" => repair&.to_h
        }.compact
      end

      # Where the walk starts: the named ref when the declaration has one, the repository's own
      # default branch otherwise. Said as a sentence rather than a nil so the record can quote it.
      def starting_point = base_ref.to_s.empty? ? "the repository's default branch" : base_ref

      # Whether a release is one this project's walk can be asked about.
      def moves_from?(release) = release.to_s == from.to_s

      def suite_command = suite&.command

      # **The release the next step walks to.** A project that publishes a checkpoint stops there
      # instead of at the final destination; one that does not (or a feed written before checkpoints
      # existed) keeps the destination, which is the behaviour every walk had. `to` stays the
      # *destination* — the field the service's final-destination rule reads — so the two are never
      # the same question.
      def checkpoint = next_checkpoint.to_s.empty? ? to : next_checkpoint

      def checkpoints? = !next_checkpoint.to_s.empty?

      def patch_checkpoint? = same_minor?(from, checkpoint)

      private

      def required(fields, name)
        value = fields[name]
        raise Invalid, "the project declaration has no #{name}" if value.nil? || value.to_s.strip.empty?

        value.to_s.strip
      end

      def optional_text(fields, name)
        value = fields[name]
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end

      # **A boolean is a boolean.** `"required": "false"` used to make a required check optional,
      # because `"false" == true` is false — a typo that silently weakened the gate. The declaration
      # refuses anything but true/false, like every other key it does not understand.
      def boolean_field(fields, name, default, where)
        return default unless fields.key?(name)

        value = fields[name]
        unless value == true || value == false
          raise Invalid, "#{where}.#{name} is #{value.inspect}; it is true or false, not a string " \
                         "or a null"
        end
        value
      end

      # A policy the declaration does not state is the service's default. It is read at all because
      # a walker that silently ignored a policy its operator set would be walking a path the service
      # planned and this client did not agree to; an unknown one is a typo, and a typo here is a
      # setting that silently does nothing, so it is refused like every other unknown value.
      def read_path_policy(value)
        return nil if value.nil? || value.to_s.strip.empty?

        policy = value.to_s.strip
        unless PATH_POLICIES.include?(policy)
          raise Invalid, "path_policy is #{policy.inspect}; known: #{PATH_POLICIES.join(", ")}"
        end
        policy
      end

      # `major.minor` of a release, or nil when it is not one. The client keeps no copy of the
      # service's ladder, but it does have to answer one question the ladder answers: whether two
      # releases are in the same minor, which is what makes a checkpoint a maintenance run.
      def same_minor?(left, right)
        one = minor(left)
        two = minor(right)
        !one.nil? && one == two
      end

      def minor(version)
        parts = version.to_s.strip.split(".").first(2)
        return nil unless parts.size == 2 && parts.all? { |part| part.match?(/\A[0-9]+\z/) }

        parts.join(".")
      end

      def read_suite(value)
        return Suite.new(kind: "none", command: nil) if value.nil?

        unless value.is_a?(Hash)
          raise Invalid, "suite must be an object with kind and command, not #{value.class}"
        end

        unknown = value.keys - %w[kind command]
        raise Invalid, "unknown suite field(s): #{unknown.sort.join(", ")}" unless unknown.empty?

        kind = value["kind"].to_s
        raise Invalid, "suite.kind is #{kind.inspect}; known: #{SUITES.join(", ")}" unless SUITES.include?(kind)

        command = value["command"].to_s.strip
        if kind != "none" && command.empty?
          raise Invalid, "suite.kind is #{kind.inspect} and no command is declared"
        end

        Suite.new(kind: kind, command: command.empty? ? nil : command)
      end

      def read_names(value, field)
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.strip.empty? }
          raise Invalid, "#{field} must be a list of names"
        end

        value.map(&:strip)
      end

      # **Names, never values.** A declaration that carried `RAILS_SECRET_TOKEN=abc` would be a secret
      # in an image and in every record that prints the declaration, so the check is the shape of a
      # name rather than a check for the word "secret".
      def environment_names(value)
        value.each do |name|
          unless name.is_a?(String) && name.match?(ENV_NAME)
            raise Invalid,
              "env_names carries #{name.to_s.inspect}: a name like MY_SECRET_TOKEN, never a value — " \
              "the value belongs in the deployment"
          end
        end

        value
      end

      def read_eras(value)
        return "auto" if value.nil?
        return "auto" if value == "auto"

        read_names(value, "eras")
      end

      # **The decisions this project has already made, as data.** An accepted answer's effects are
      # applied on every walk (`Effects`), which is what makes a decision machinery rather than a note.
      # The shape is checked here — keys, an id, a list of effects — and the *meaning* of an effect
      # (its kind, its conditions, the text it finds) is `Effects`'s, because that is where it is
      # applied and where a refusal belongs beside the run rather than at load.
      def read_decisions(value)
        return [] if value.nil?

        unless value.is_a?(Array)
          raise Invalid, "decisions must be a list of accepted decisions, not #{value.class}"
        end

        value.each_with_index.map do |decision, index|
          unless decision.is_a?(Hash)
            raise Invalid, "decision #{index} is not an object"
          end

          unknown = decision.keys - DECISION_FIELDS
          unless unknown.empty?
            raise Invalid, "unknown field(s) in decision #{index}: #{unknown.sort.join(", ")} — " \
                           "known: #{DECISION_FIELDS.join(", ")}"
          end
          if decision["id"].to_s.strip.empty?
            raise Invalid, "decision #{index} has no `id`, so nothing in the run could name it"
          end

          effects = decision["effects"]
          unless effects.is_a?(Array)
            raise Invalid, "decision #{decision["id"]} has no `effects` list"
          end
          effects.each_with_index do |effect, position|
            unless effect.is_a?(Hash)
              raise Invalid, "decision #{decision["id"]}'s effect #{position} is not an object"
            end

            unknown_effect = effect.keys - EFFECT_FIELDS
            unless unknown_effect.empty?
              raise Invalid, "unknown field(s) in decision #{decision["id"]}'s effect #{position}: " \
                             "#{unknown_effect.sort.join(", ")} — known: #{EFFECT_FIELDS.join(", ")}"
            end
          end

          decision
        end
      end

      # **Where the application's own source lives, and the one place a rule may look outside it.**
      # A modular monolith keeps models under `components/*/app/models`, and an engine under
      # `engines/`; a rule whose glob names `app/models` is a fact about one application, not about
      # Rails. The walker scopes the scan and the rules to these roots, and an absent list keeps the
      # old repository-wide read, so a declaration written before the field existed means what it
      # meant.
      def read_source_roots(value)
        return [] if value.nil?

        roots = read_names(value, "source_roots")
        roots.each do |root|
          if root.start_with?("/") || root.split("/").include?("..")
            raise Invalid, "source_roots carries #{root.inspect}: a root is a relative directory " \
                           "inside the application, never an absolute path or one that leaves it"
          end
        end
        roots
      end

      # **The rest of the application's gate.** The suite is declared separately and is always the
      # test check; this list is what the suite alone was hiding. An empty list is a real answer —
      # the suite is the gate — and the PR says so rather than implying checks that do not exist.
      def read_checks(value)
        return [] if value.nil?

        unless value.is_a?(Array)
          raise Invalid, "checks must be a list of check objects, not #{value.class}"
        end

        seen = {}
        value.each_with_index.map do |check, index|
          unless check.is_a?(Hash)
            raise Invalid, "check #{index} is not an object"
          end

          unknown = check.keys - %w[id name kind command required external environment reason]
          unless unknown.empty?
            raise Invalid, "unknown field(s) in check #{index}: #{unknown.sort.join(", ")}"
          end

          id = check["id"].to_s.strip
          raise Invalid, "check #{index} has no `id`, so no record could name it" if id.empty?
          if seen[id]
            raise Invalid, "two checks are called #{id.inspect}; an id names one result"
          end
          seen[id] = true

          kind = check["kind"].to_s.strip
          unless CHECK_KINDS.include?(kind)
            raise Invalid, "check #{id}'s kind is #{kind.inspect}; known: #{CHECK_KINDS.join(", ")}"
          end

          external = boolean_field(check, "external", false, "check #{id}") || kind == "external"
          required = boolean_field(check, "required", true, "check #{id}")
          command = check["command"].to_s.strip
          reason = check["reason"].to_s.strip
          if external
            if reason.empty?
              raise Invalid, "check #{id} is external and has no `reason`: say where it runs, or " \
                             "the record reads as a check somebody forgot"
            end
          elsif command.empty?
            raise Invalid, "check #{id} has no `command`: a local check is a command this walk runs"
          end

          environment = check["environment"].to_s.strip
          if !environment.empty? && !CHECK_ENVIRONMENTS.include?(environment)
            raise Invalid, "check #{id}'s environment is #{environment.inspect}; known: " \
                           "#{CHECK_ENVIRONMENTS.join(", ")}"
          end
          if environment == "ci" && !external
            raise Invalid, "check #{id} names environment `ci` but is not external: this walk " \
                           "cannot reproduce the application's CI environment, so a command it " \
                           "runs here is not that check"
          end

          Check.new(id: id, name: check["name"].to_s.strip.empty? ? nil : check["name"].to_s.strip,
            kind: kind, command: command.empty? ? nil : command, required: required,
            external: external, environment: environment.empty? ? nil : environment,
            reason: reason.empty? ? nil : reason)
        end
      end

      # The build facts the application's CI assumes. They are optional because a declaration that
      # does not know them is still walkable; they become load-bearing when the overlay image and the
      # parity check arrive.
      def read_toolchain(value)
        return nil if value.nil?

        unless value.is_a?(Hash)
          raise Invalid, "toolchain must be an object, not #{value.class}"
        end

        unknown = value.keys - %w[ruby node postgres extensions apt native chrome]
        raise Invalid, "unknown toolchain field(s): #{unknown.sort.join(", ")}" unless unknown.empty?

        browser = optional_text(value, "chrome")
        unless browser.nil? || %w[pinned distro].include?(browser)
          raise Invalid, "toolchain.chrome is #{browser.inspect}; the browser is `pinned` (the build " \
                         "this era image verified) or `distro` (the Debian release's own package), " \
                         "and a suite that drives none leaves the key out"
        end

        Toolchain.new(
          ruby: optional_text(value, "ruby"), node: optional_text(value, "node"),
          postgres: optional_text(value, "postgres"),
          extensions: read_names(value["extensions"] || [], "toolchain.extensions"),
          apt: read_names(value["apt"] || [], "toolchain.apt"),
          native: read_names(value["native"] || [], "toolchain.native"),
          chrome: browser
        )
      end

      # **The two facts are one object, because a policy without a model is a permission nobody
      # can use.** An unknown policy is refused rather than read as `off`: a typo that silently
      # disables a permission somebody just granted is the "setting that does nothing" this class
      # refuses everywhere else.
      def read_repair(value)
        return nil if value.nil?

        raise Invalid, "repair must be an object, not #{value.class}" unless value.is_a?(Hash)

        unknown = value.keys - %w[policy model]
        raise Invalid, "unknown repair field(s): #{unknown.sort.join(", ")}" unless unknown.empty?

        policy = value["policy"].to_s.strip
        unless REPAIR_POLICIES.include?(policy)
          raise Invalid, "repair.policy is #{policy.inspect}; this build knows " \
                         "#{REPAIR_POLICIES.join(", ")}"
        end

        Repair.new(policy: policy,
          models: value["model"].to_s.split(/[,\s]+/).reject(&:empty?))
      end

      def read_style(value)
        return nil if value.nil?

        unless value.is_a?(Hash)
          raise Invalid, "style must be an object with format and check, not #{value.class}"
        end

        unknown = value.keys - %w[format check]
        raise Invalid, "unknown style field(s): #{unknown.sort.join(", ")}" unless unknown.empty?

        format = optional_text(value, "format")
        check = optional_text(value, "check")
        if format.nil? && check.nil?
          raise Invalid, "style declares neither `format` nor `check`, so it asks for nothing"
        end

        Style.new(format: format, check: check)
      end

      # **What `app:update` may do.** The defaults are the walk's current behaviour, stated rather
      # than implied: adopt only files the application did not have, skip an engine's migration when
      # the application does not use that engine, record every conflict, and leave
      # `config.load_defaults` alone unless the declaration says `step`.
      def read_app_update(value)
        defaults = { "adopt" => "added_only", "skip" => [], "skip_unused_engines" => true,
                     "framework_defaults" => "off" }
        return AppUpdate.new(**symbolize(defaults)) if value.nil?

        unless value.is_a?(Hash)
          raise Invalid, "app_update must be an object, not #{value.class}"
        end

        unknown = value.keys - defaults.keys
        raise Invalid, "unknown app_update field(s): #{unknown.sort.join(", ")}" unless unknown.empty?

        merged = defaults.merge(value)
        adopt = merged["adopt"].to_s
        unless APP_UPDATE_ADOPTS.include?(adopt)
          raise Invalid, "app_update.adopt is #{adopt.inspect}; this build knows " \
                         "#{APP_UPDATE_ADOPTS.join(", ")} — overwriting a file the application " \
                         "owns is a decision, not a policy this walk will take"
        end

        skip = read_names(merged["skip"] || [], "app_update.skip")
        skip.each do |pattern|
          if pattern.start_with?("/") || pattern.split("/").include?("..")
            raise Invalid, "app_update.skip carries #{pattern.inspect}: a skip is a relative glob " \
                           "inside the application"
          end
        end

        framework = merged["framework_defaults"].to_s
        unless FRAMEWORK_DEFAULTS.include?(framework)
          raise Invalid, "app_update.framework_defaults is #{framework.inspect}; known: " \
                         "#{FRAMEWORK_DEFAULTS.join(", ")}"
        end

        AppUpdate.new(adopt: adopt, skip: skip,
          skip_unused_engines: boolean_field(merged, "skip_unused_engines", true, "app_update"),
          framework_defaults: framework)
      end

      def symbolize(hash)
        hash.transform_keys(&:to_sym)
      end

      def read_delivery(value)
        return Delivery.new(provider: "none", branch: nil, chain: false, publish: "off",
          deploy: []) if value.nil?

        unless value.is_a?(Hash)
          raise Invalid, "delivery must be an object with provider, branch and chain, not #{value.class}"
        end

        unknown = value.keys - %w[provider branch chain publish deploy]
        raise Invalid, "unknown delivery field(s): #{unknown.sort.join(", ")}" unless unknown.empty?

        provider = value["provider"].to_s
        unless PROVIDERS.include?(provider)
          raise Invalid, "delivery.provider is #{provider.inspect}; known: #{PROVIDERS.join(", ")}"
        end
        publish = value.fetch("publish", "off").to_s
        unless %w[off branch pr].include?(publish)
          raise Invalid, "delivery.publish is #{publish.inspect}; known: off, branch, pr"
        end
        deploy = Array(value["deploy"]).map(&:to_s).reject(&:empty?)

        # **A branch belongs to a provider that has one.** An explicit null is "none" and is honoured;
        # an absent branch defaults only for GitHub, because a `none` delivery with GitHub's pattern
        # would round-trip into a different declaration than the one that was written.
        branch = value.key?("branch") ? value["branch"] : (provider == "github" ? DEFAULT_BRANCH : nil)
        Delivery.new(provider: provider, branch: branch,
          chain: value.key?("chain") ? value["chain"] == true : true, publish: publish,
          deploy: deploy)
      end
    end
  end
end
