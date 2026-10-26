# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # **A configuration line the release moved to another namespace, found by the boot its old
    # namespace no longer answers.**
    #
    # Rails 6.1 deprecated `config.action_view.raise_on_missing_translations` and said it would be
    # removed in 7.0; 7.0 removed the `ActionView::Base.raise_on_missing_translations=` setter the
    # option drove, while the generated environments moved the setting to
    # `config.i18n.raise_on_missing_translations`. An application that kept the old line therefore
    # boots (`bin/rails runner` never loads ActionView) and then fails every example that renders a
    # template with `NoMethodError: undefined method 'raise_on_missing_translations=' for
    # ActionView::Base:Class` — measured on ohana-api's 7.0.10 rung: 1,554 examples, all of them,
    # in 63 seconds.
    #
    # The repair is the setting's new home, not a rewrite of what the application asked for: the
    # value stays exactly as written and only the namespace moves. It edits every configuration file
    # that carries the old spelling under `config/`, because the same line is usually in more than
    # one environment file and an edit that answered only the test environment would leave
    # `development.rb` to break the next boot.
    #
    # What it refuses: a failure that does not name this setter. The message is the evidence, and a
    # suite that failed for another reason must not have its configuration rewritten.
    module TranslationSettings
      # The release's own words for the setter it removed. The class is named so a gem's unrelated
      # `raise_on_missing_translations=` is not this family's failure.
      REMOVED = /undefined method [`']raise_on_missing_translations=' for ActionView::Base/

      # The setting as an application writes it. The receiver is `config`, which is what the
      # generated environment files bind; a value read as `Rails.application.config...` is the same
      # setting and the same line, so the match starts after `config.`.
      SETTING = /\bconfig\.action_view\.raise_on_missing_translations\b/

      def self.for(root:, failures:)
        return [] unless Array(failures).any? { |failure| removed_setter?(failure) }

        Dir.glob(File.join(root, "config", "**", "*.rb")).sort.flat_map do |full|
          path = full.delete_prefix("#{root}/")
          File.readlines(full).each_with_index.filter_map do |line, index|
            text = line.chomp
            next unless text.match?(SETTING)

            {
              "path" => path,
              "line" => index + 1,
              "text" => text,
              "after" => text.sub(SETTING, "config.i18n.raise_on_missing_translations"),
              "automatic" => true,
              "subject" => "raise_on_missing_translations",
              "origin" => "suite-repair",
              "note" => "Rails 7.0 removed the ActionView accessor this setting drove; the setting's " \
                        "own home is `config.i18n.raise_on_missing_translations`, with the value kept"
            }
          end
        end
      end

      def self.removed_setter?(failure)
        failure.messages.any? { |message| message.match?(REMOVED) }
      end
    end
  end
end
