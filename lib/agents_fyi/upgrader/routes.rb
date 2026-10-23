# frozen_string_literal: true

require "json"
require "agents_fyi/upgrader/stacks"

module AgentsFyi
  module Upgrader
    # **The application's route table, asked of the application rather than parsed out of
    # `config/routes.rb`.**
    #
    # A repair that renames a route helper has to know which helper the application declares for a
    # controller and action, and in what order its required parts are passed. Reading `routes.rb`
    # would mean reimplementing the DSL (resources, nesting, concerns, scopes, namespaces) and being
    # wrong about the first application that uses a form this file did not anticipate. The router
    # already answers the question, in the application's own interpreter, so this runs a script on
    # the machine the step executes on — the pack owns the command spelling, this reads what it
    # prints — and reads three facts per named route: the helper's name, the controller and action
    # it dispatches to, and the parts it requires.
    #
    # **The parts are the repair's argument list.** A named route's `required_parts` are in the
    # order the path takes them, which is exactly the order a call has to pass them.
    module Routes
      SCRIPT = <<~RUBY
        require "json"
        rows = Rails.application.routes.routes.map do |route|
          name = route.name
          next if name.nil?
          { "name" => name.to_s, "controller" => route.defaults[:controller].to_s,
            "action" => route.defaults[:action].to_s,
            "parts" => route.required_parts.map(&:to_s) }
        end
        puts JSON.generate(rows.compact)
      RUBY

      Row = Struct.new(:name, :controller, :action, :parts, keyword_init: true) do
        def helper = "#{name}_path"

        def requires = Array(parts)
      end

      # A route named in the application's source is not a route: an empty table is what an
      # application whose `routes.rb` could not be loaded answers, and a repair built on it would be
      # a guess. The caller treats it as "no repair", never as "no routes exist".
      def self.read(machine:, root:, env: {}, stack: nil)
        stack ||= Stacks.for("rails")
        argv = stack.routes_runner(root, script: SCRIPT)
        return [] if argv.nil?

        argv, process_env = machine.command(argv, chdir: root, env: env)
        command = Shell.run(argv, stage: "routes", chdir: root, env: process_env,
          excerpt_bytes: 1_000_000)
        return [] unless command.exit_code.to_i.zero?

        # The JSON is the last line the router printed; a boot's deprecation warnings arrive before
        # it, and a `runner` that prints anything after it would be a script this build does not
        # have. Reading the last bracket line is what keeps a warning from being parsed as routes.
        payload = command.output_tail.to_s.lines.reverse.find { |line| line.lstrip.start_with?("[") }
        return [] if payload.nil?

        Array(JSON.parse(payload)).filter_map do |row|
          next unless row.is_a?(Hash) && !row["name"].to_s.empty?

          Row.new(name: row["name"].to_s, controller: row["controller"].to_s,
            action: row["action"].to_s, parts: Array(row["parts"]).map(&:to_s))
        end
      rescue JSON::ParserError, TypeError
        []
      end
    end
  end
end
