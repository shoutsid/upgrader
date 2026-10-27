# frozen_string_literal: true

module Agents
  module Upgrader
    # **A gem the application was using directly and a dependency used to provide.**
    #
    # `bin/rails runner` answering `LoadError: cannot load such file -- attr_encrypted` is a boot
    # failure with two facts behind it, and both are in the tree: the application's own Require
    # (a model, a controller, an initializer — whatever the stack trace names) and the base
    # commit's lockfile, which carried the gem at a version because something else pulled it in.
    # A move can break that without touching the application: measured at diaspora's 7.1 rung,
    # `devise-two-factor 4.1.0` depends on `attr_encrypted`, `~> 6.3.1` does not, and
    # `app/models/user.rb` encrypts the OTP secret with it — so the pin was correct and the
    # application still could not boot.
    #
    # The repair is therefore a *declaration*, not a rewrite: a gem the application's code
    # requires is a direct dependency whether or not the Gemfile says so, and relying on another
    # gem's transitive dependency was always a fact about the resolver rather than a decision.
    # The version is the one the base commit ran with, exact rather than a range — a range would
    # let the resolver take a release the application was never measured against, which is the
    # opposite of what a repair is allowed to do.
    #
    # **Nothing is guessed.** A require name that matches no spec in the base lockfile has no
    # version to pin, a gem already declared is not this family's (its line is not the fix), and
    # a gem still in the current lockfile is not missing from the bundle at all. Each of those is
    # a nil, and the boot's own failure stands in the record.
    module MissingGems
      # Ruby spells this one way in every version this tool runs: the message carries the name
      # the application passed to `require`, which may be a path into the gem's own directory.
      LOAD_ERROR = /cannot load such file -- ([\w.\/-]+)/

      # A name compared the way Ruby and RubyGems disagree about it: the require is
      # `active_support`, the gem is `activesupport`, and `devise-two-factor` is required as
      # `devise-two-factor` or `devise_two_factor` depending on who wrote the line. Removing the
      # separators is what makes one comparison answer all three.
      def self.normalize(name)
        name.to_s.downcase.delete("-_")
      end

      # The edit that declares the gem, or nil when the tree does not support one.
      #
      # `lock` is the *base commit's* parse — the one the step read before the pin — because the
      # question is what the application was running before this rung, and the current lock is
      # what no longer has the gem in it.
      def self.for(output:, root:, lock:)
        required = Array(output.to_s.scan(LOAD_ERROR)).flatten.first
        return nil if required.nil?

        wanted = normalize(required.split("/").first)
        return nil if wanted.empty?

        spec = (lock&.specs || {}).find { |name, _version| normalize(name) == wanted }
        return nil if spec.nil?

        name, version = spec
        return nil if version.to_s.strip.empty?

        gemfile = File.join(root, "Gemfile")
        return nil unless File.file?(gemfile)

        lines = File.read(gemfile, encoding: "utf-8").lines.map(&:chomp)
        return nil if declares?(lines, name)
        return nil if still_locked?(root, name)

        anchor = anchor(lines)
        return nil if anchor.nil?

        {
          "path" => "Gemfile",
          "line" => anchor + 1,
          "text" => lines[anchor],
          "after" => "#{lines[anchor]}\ngem \"#{name}\", \"#{version}\"",
          "automatic" => true,
          "subject" => "a gem the application requires and a dependency used to provide",
          "origin" => "boot-repair",
          "note" => "`#{required}` could not be loaded at boot; the base commit's lockfile " \
                    "carried #{name} #{version}, this rung's pin no longer provides it, so the " \
                    "Gemfile declares the gem the application's own code requires"
        }
      end

      # Whether the Gemfile already names this gem. A declared gem is another failure's: the
      # bundle would have installed it, so a LoadError for it means something else (a group the
      # suite does not install, a `require:` mismatch) and adding a second line would not be the fix.
      def self.declares?(lines, name)
        pattern = /\A\s*gem\s*\(?\s*["']#{Regexp.escape(name)}["']/
        Array(lines).any? { |line| line.match?(pattern) }
      end

      # Whether the current lockfile still has it. The base parse is what names a version; this is
      # what decides whether anything is missing at all.
      def self.still_locked?(root, name)
        Lockfile.read(root).specs.keys.any? { |candidate| normalize(candidate) == normalize(name) }
      rescue Lockfile::Missing, Lockfile::Unreadable
        false
      end

      # The line the new declaration goes after: the last `gem` line the Gemfile has, so the
      # addition lands in the list a person reads rather than after a trailing `end` or in the
      # middle of a group the last gem line belongs to.
      #
      # A Gemfile with no `gem` line at all is not one this family writes into — its shape is
      # something else's problem, and a plausible-looking insertion would be a guess.
      def self.anchor(lines)
        Array(lines).each_index.reverse_each.find do |index|
          lines[index].match?(/\A\s*gem\s*\(?\s*["']/)
        end
      end
    end
  end
end
