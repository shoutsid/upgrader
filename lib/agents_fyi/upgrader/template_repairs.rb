# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # **A red suite's route failures, repaired from the application's own route table.**
    #
    # A rung can make a template that rendered before fail, and the question "what changed?" has
    # two halves. The *call site* is the application's — a helper it never declared, or one handed
    # a nil segment — while the *release* is what exercises it: a bundle that starts rendering a
    # view, or a Rails version whose test harness stops nullifying templates, changes which pages a
    # suite reaches. So the repair is mechanical and the evidence is the rung: the two families
    # below are answered from facts the application already holds, not from a per-application
    # decision, and the outcome is filed as a corpus report (`Repair.mechanical_outcome`) so the
    # next walk reads a failure and its fix rather than deriving them again.
    #
    # * **A route helper the application does not declare.** A view links to `edit_bid_path(@bid)`
    #   while the routes declare `edit_category_item_bid_path(category, item, bid)` — the resource is
    #   nested, and the helper was never there. The router knows which helper serves that controller
    #   and action, and in what order its parts go (`Routes`), and the controller knows which
    #   instance variable each route parameter arrives in (`@item = Item.find(params[:item_id])`).
    #   Those two facts are the repair.
    # * **A declared helper given a nil required part.** The failure is an
    #   `ActionController::UrlGenerationError` naming the missing key. The URL was never buildable —
    #   Journey refused a nil segment in 5.2 as it does in 6.0 — so what the rung changes is
    #   whether the page is rendered at all. The failure names the key and the line; if that line is
    #   one ERB output tag and the key's argument is a bare instance variable, the tag is guarded on
    #   it.
    #
    # **Nothing is guessed.** A part the controller does not assign from `params` has no variable
    # here, and the repair is nil rather than a plausible name: the alternative is a page that
    # renders and links somewhere wrong. Every edit goes through `Applier`, which compares the line
    # the suite reported against the file before writing it, and the suite is run again afterwards —
    # the execution gate is what makes a repair a fact.
    module TemplateRepairs
      # The helpers a view may call. `_url` is deliberately absent: replacing one with a path would
      # change an absolute URL into a relative one, which is a different repair.
      HELPER = /(\w+_path)\(([^)]*)\)/

      def self.for(root:, failures:, routes:)
        return [] if routes.empty?

        edits = Array(failures).filter_map { |failure| repair(root: root, failure: failure, routes: routes) }
        edits.uniq { |edit| [edit["path"], edit["line"], edit["after"]] }
      end

      def self.repair(root:, failure:, routes:)
        file = failure.file
        return nil if file.nil? || failure.line.nil? || !file.start_with?("app/views/")

        full = File.join(root, file)
        return nil unless File.file?(full)

        lines = File.readlines(full)
        index = failure.line - 1
        return nil if index.negative? || index >= lines.size

        text = lines[index].chomp
        helper = undefined_helper(failure)
        edited =
          if helper
            rewrite_helper(root: root, text: text, helper: helper, routes: routes)
          else
            guard_missing_part(text: text, failure: failure, routes: routes)
          end
        return nil if edited.nil? || edited == text

        {
          "path" => file,
          "line" => failure.line,
          "text" => text,
          "after" => edited,
          "automatic" => true,
          "subject" => failure.classes.first.to_s,
          "origin" => "suite-repair",
          "note" => "the suite failed at this line (#{failure.name})"
        }
      end

      # `undefined method 'bid_path' for ...`, in either the wrapper's message or its cause's —
      # and the second spelling Ruby uses for a call with no receiver. `link_to 'Back', bids_path`
      # is a bare method call, so it raises `NameError: undefined local variable or method
      # 'bids_path'`; matching only `undefined method` repaired the polymorphic link on the line
      # above and left this one, which cost the 6.0 rung's run its repair budget with four failures
      # still red (measured on the deployment this was written for).
      def self.undefined_helper(failure)
        failure.messages.each do |message|
          found = message[/(?:undefined method|undefined local variable or method) [`'](\w+_path)'/, 1]
          return found if found
        end
        nil
      end

      # The route that serves the controller and action a helper's name implies, or nil. The name
      # is the only thing the failure gives; the table is the only thing that may answer.
      #
      # **A bare helper is the resource's own route, named as the router names it.** `bids_path` is
      # the collection and `bid_path` the member, and both belong to the same controller — the table
      # declares them `category_item_bids` and `category_item_bid` — so the controller alone cannot
      # say which one a view meant. The declared name can: a nested resource keeps its own name as
      # the suffix of the route it becomes, which is why the suffix is what this asks about. The
      # alternative this replaced — "a show route exists, so a bare name is show" — repaired
      # `bids_path` into the member route, which renders and links somewhere else; the suite would
      # have gone green over a wrong page.
      def self.route_for(helper, routes)
        return nil unless helper.to_s.end_with?("_path")

        name = helper.delete_suffix("_path")
        action, resource =
          if name.start_with?("new_")
            ["new", name.delete_prefix("new_")]
          elsif name.start_with?("edit_")
            ["edit", name.delete_prefix("edit_")]
          else
            [nil, name]
          end
        controller = pluralize(resource)
        candidates = routes.select { |route| route.controller == controller }
        return nil if candidates.empty?
        return candidates.find { |route| route.action == action } if action

        # The declared route whose name is the helper's, or whose name ends with it — the parents'
        # prefixes are the router's, not the caller's. A name that matches no route falls back to
        # the two actions a bare resource helper can mean, in that same declared order.
        named = candidates.select do |route|
          route.name == name || route.name.end_with?("_#{name}")
        end
        [named, candidates].each do |set|
          found = set.find { |route| %w[index show].include?(route.action) }
          return found unless found.nil?
        end
        nil
      end

      # The instance variable each route parameter arrives in, read off the controller the route
      # dispatches to. A part the controller does not assign from `params` is absent, and a caller
      # treats an incomplete map as a refusal rather than filling the gap by convention.
      def self.ivars_for(root, controller)
        path = Dir[File.join(root, "app/controllers/**", "#{controller}_controller.rb")].first
        return nil if path.nil?

        map = {}
        File.read(path).scan(/@(\w+)\s*=[^\n]*?params\[:(\w+)\]/) do |ivar, param|
          map[param] ||= "@#{ivar}"
        end
        map
      end

      # **The rewrite a missing helper gets.** A call to the helper is replaced by the declared
      # helper with the controller's own variables; a polymorphic `link_to 'Show', @bid` is replaced
      # by the same call, because the record argument is the route's last part and the model's route
      # is the one the table names. A collection helper (`bids_path`) and a member one (`bid_path`)
      # are different routes, and `route_for` is where that distinction is read.
      def self.rewrite_helper(root:, text:, helper:, routes:)
        route = route_for(helper, routes)
        return nil if route.nil?

        map = ivars_for(root, route.controller)
        return nil if map.nil?

        args = route.requires.map { |part| map[part] }
        return nil if args.any?(&:nil?)

        call = "#{route.helper}(#{args.join(", ")})"
        if text.match?(/#{Regexp.escape(helper)}\([^)]*\)/)
          return text.sub(/#{Regexp.escape(helper)}\([^)]*\)/, call)
        end

        # **A bare helper carries no argument list, and that is not a reason to leave it.**
        # `link_to 'Back', bids_path` is how every Rails view writes a collection link, so the
        # call site is the name alone and the parts still come from the controller. The lookarounds
        # keep `new_bids_path` and `object.bids_path` out of it: those name other calls.
        bare = /(?<![\w.])#{Regexp.escape(helper)}\b(?!\s*\()/
        return text.sub(bare, call) if text.match?(bare)

        link = text.match(/link_to(\s+)(['"][^'"]*['"]),\s*(@\w+)/)
        return nil if link.nil?

        text.sub(link[0], "link_to#{link[1]}#{link[2]}, #{call}")
      end

      # **The guard a nil segment gets.** Only the first missing key is repaired per run; a line
      # missing two would need a guard that reads as a condition, and this tool does not write one.
      def self.guard_missing_part(text:, failure:, routes:)
        key = missing_keys(failure).first
        return nil if key.nil?

        found = text.match(HELPER)
        return nil if found.nil?

        route = routes.find { |candidate| candidate.helper == found[1] }
        return nil if route.nil?

        position = route.requires.index(key)
        return nil if position.nil?

        argument = found[2].split(",").map(&:strip)[position]
        return nil unless argument&.match?(/\A@\w+\z/)
        return nil unless text.match?(/\A\s*<%=.*%>\s*\z/)

        text.sub(/\A(\s*)(<%=.*%>)\s*\z/) { "#{::Regexp.last_match(1)}<% if #{argument} %>#{::Regexp.last_match(2)}<% end %>" }
      end

      def self.missing_keys(failure)
        failure.messages.each do |message|
          found = message[/missing required keys: \[([^\]]+)\]/, 1]
          next if found.nil?

          return found.split(",").map { |key| key.strip.delete_prefix(":") }
        end
        []
      end

      def self.pluralize(word)
        return word if word.end_with?("s")

        word.end_with?("y") ? "#{word[0..-2]}ies" : "#{word}s"
      end
    end
  end
end
