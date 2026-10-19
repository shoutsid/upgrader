# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # **The Rails knowledge, in one place.** A *stack* is what a set of releases changes and how a
    # command is spelled for it; a *project* (Project) says which of those commands to run and what
    # its suite is called. The engine between them decides nothing about either, and
    # `test/engine_facts_test.rb` holds the boundary: no file outside this directory names
    # `bin/rails`, `rake`, the services script, `RAILS_ENV` or an era image.
    #
    # The spellings here are not style choices — each was measured on the first complete walk:
    #
    # * **`rails db:create` arrived in Rails 5.0 and `bin/rails` in 4.0**, so a binstub says nothing
    #   about which spelling the application can run. The lighthouse has both and runs 4.0.0.rc1,
    #   where `bin/rails db:create` answers "Command 'db:create' not recognized" and leaves the
    #   suite to fail on a database nobody created.
    # * **`app:update` and `rails:update` are one job under two names**, and two of the four
    #   runner/task combinations fail with a command-not-found: a 4.x task through `bin/rails` says
    #   "Command 'rails:update' not recognized", a 5.x task through rake says "Don't know how to
    #   build task 'app:update'". They are chosen together, from the application's own version.
    # * **`app:update` is a development command.** The walker runs everything else in `test`; the
    #   update task loaded a test-group gem that could not load under the release it was
    #   installing, so a task about config files failed on a test gem.
    # * **The boot is `bin/rails runner`** and exists only where the binstub does: an application
    #   without one is measured by its suite alone.
    module Stacks
      module Rails
        # The script the era images ship. It reads the application's own `database.yml` for the
        # adapter and the usernames, starts PostgreSQL and Redis on localhost, and reports what it
        # started. A native machine has no services stage at all.
        SERVICES = "agents-fyi-services"

        # The suite candidates, in the order they are tried, and **the order is the decision**.
        # Read top to bottom:
        #
        # 1. `bundle exec rspec` — a helper file is a deliberate statement that a suite exists.
        # 2. `bin/rails test` — Rails 5+ has a Rakefile as well, and `bin/rails` is the entry point
        #    Rails documents; `rake test` prints a deprecation on Rails 7 and is gone on 8, so a
        #    table that checked the Rakefile first would break the newer application to serve the
        #    older one.
        # 3. `bundle exec rake test` — Rails 4 and older, which have no `bin/rails`.
        #
        # The first real walk's repository has all three shapes at once — a `spec/spec_helper.rb`,
        # a `test/test_helper.rb` from Rails' generators, and a `Rakefile` — and the suite that
        # matters is the spec one (its `Guardfile` watches `spec/`, its `.rspec` asks for colour).
        # A `test/` directory of generated files is not a deliberate statement, so rspec is asked
        # first and the alternatives are named in `reason` and travel into the record.
        SUITES = [
          {
            kind: :rspec,
            command: "bundle exec rspec",
            matches: ->(root) do
              File.file?(File.join(root, "spec/spec_helper.rb")) ||
                File.file?(File.join(root, "spec/rails_helper.rb"))
            end,
            looked_for: "a `spec/spec_helper.rb` or `spec/rails_helper.rb`",
            reason: "a spec directory with a helper file: this application's suite is rspec"
          },
          {
            kind: :rails,
            command: "bin/rails test",
            matches: ->(root) do
              File.file?(File.join(root, "bin/rails")) &&
                File.file?(File.join(root, "test/test_helper.rb"))
            end,
            looked_for: "`bin/rails` beside a `test/test_helper.rb`",
            reason: "`bin/rails` and `test/test_helper.rb`: a Rails 5 or newer application " \
                    "runs its suite through bin/rails, and `rake test` is the deprecated entry"
          },
          {
            kind: :rake,
            command: "bundle exec rake test",
            matches: ->(root) do
              File.file?(File.join(root, "Rakefile")) && File.directory?(File.join(root, "test"))
            end,
            looked_for: "a `Rakefile` with a `test` directory",
            reason: "a Rakefile and a test directory, with no bin/rails: Rails 4 and older " \
                    "run minitest through the rake task"
          }
        ].freeze

        module_function

        # **The environment a Rails suite has to run under.** A suite that runs without it boots in
        # *development*, against the development database, inside a working copy somebody is
        # upgrading — and `RACK_ENV` is included because a Rack application reads that one and not
        # `RAILS_ENV`. The walker runs everything else in test too; this is the stack's statement
        # of what its suites need, not the engine's opinion about one framework.
        TEST_ENV = { "RAILS_ENV" => "test", "RACK_ENV" => "test" }.freeze

        # The suite kinds that read `TEST_ENV`. A suite this pack did not recognise needs nothing.
        TESTED = %i[rspec rails rake].freeze

        # The command a component's own installer is, named in a note the application's operator
        # reads: `bin/rails active_storage:install` says what to run if the application wants the
        # component whose migration was just refused.
        def install_command(component) = "bin/rails #{component}:install"

        # The update command as it would be written in a record, for the refusal that has nothing to
        # run: a real spelling rather than a placeholder, chosen the same way the runner is.
        def update_command(five_or_newer:)
          five_or_newer ? "bin/rails app:update" : "bundle exec rake rails:update"
        end

        # What the record says when there is no update to run: the application has neither binstub
        # nor Rakefile, so the task the pack knows about has no runner.
        def no_update_reason = "no bin/rails and no Rakefile: nothing to run"

        def name = "rails"

        # **The release where every command moved from rake to the CLI.** `major >= 5` is the whole
        # rule: `db:create`, `app:update` and the boot all moved at 5.0, and an application on a
        # pre-release (`4.0.0.rc1`) is on 4. Read from the lockfile the step opened before anything
        # was written — that is the Rails that would *run* the command, not the one being installed.
        def five_or_newer?(lockfile)
          lockfile&.rails&.version.to_s.split(".").first.to_i >= 5
        end

        def services_command = [SERVICES]

        def suite_candidates = SUITES

        def test_env = TEST_ENV

        def suite_env(kind) = TESTED.include?(kind.to_sym) ? TEST_ENV : {}

        # What the pack looked for, one clause per candidate, for the sentence a repository with no
        # suite is told. Read from the table rather than restated, so a candidate added here is a
        # candidate the refusal names.
        def no_suite_looked_for = SUITES.map { |candidate| candidate[:looked_for] }

        # The runner and the task together: `[["bin/rails"], "app:update"]`, or nil when the
        # application has neither binstub nor Rakefile.
        def app_update(root, five_or_newer:)
          if five_or_newer
            return [["bin/rails"], "app:update"] if File.executable?(File.join(root, "bin", "rails"))

            return nil
          end
          return [["bundle", "exec", "rake"], "rails:update"] if File.file?(File.join(root, "Rakefile"))

          nil
        end

        # `[argv, nil]` when there is something to run, `[nil, sentence]` when there is not.
        def prepare_database(root, five_or_newer:)
          if five_or_newer
            return [["bin/rails", "db:create", "db:test:prepare"], nil]
          end
          if File.file?(File.join(root, "Rakefile"))
            return [["bundle", "exec", "rake", "db:create", "db:test:prepare"], nil]
          end

          [nil, "no Rakefile and no bin/rails: nothing to prepare the database with"]
        end

        # The command Rails' own message names when a migration is pending.
        def migrate(root, five_or_newer:)
          five_or_newer ? ["bin/rails", "db:migrate"] : ["bundle", "exec", "rake", "db:migrate"]
        end

        def boot(root)
          return nil unless File.executable?(File.join(root, "bin", "rails"))

          ["bin/rails", "runner", "puts Rails.version"]
        end

        # The environment a development-only command runs under, over whatever the application's
        # own suite environment already carries.
        def development_env(env = {})
          env.merge("RAILS_ENV" => "development", "RACK_ENV" => "development")
        end
      end

      # The packs this build knows, by the name a project declares. An unknown name is an error
      # rather than a default: a declaration that asks for `node` and silently gets Rails is a walk
      # measured against the wrong knowledge.
      PACKS = { "rails" => Rails }.freeze

      module_function

      def for(name)
        pack = PACKS[normalise(name)]
        raise Project::Invalid, "no stack pack named #{name.inspect}; known: #{PACKS.keys.join(", ")}" if pack.nil?

        pack
      end

      def normalise(name) = name.to_s.strip.downcase
    end
  end
end
