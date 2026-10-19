# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # **A lock names the bundler that made it, RubyGems activates that version, and an era may not be
    # able to run it — so the trailer is the one thing standing between an application and an install.**
    #
    # Measured at the 7.2 rung, the first to run on the 3.2 era. The `bundle install` stage exits 1 and
    # the verdict is `no interpreter installed the application's bundle`:
    #
    #     3.2: .../bundler-1.17.3/lib/bundler/shared_helpers.rb:29: warning: Pathname#untaint is
    #          deprecated and will be removed in Ruby 3.2.
    #     3.3: Bundler 2.6.9 is running, but your lockfile was generated with 1.17.3. Installing
    #          Bundler 1.17.3 and restarting using that version.
    #          .../bundler-1.17.3/lib/bundler/shared_helpers.rb:29:in `root':
    #            undefined method `untaint' for an instance of Pathname (NoMethodError)
    #
    # RubyGems had read the lock, installed the 1.17.3 it names, and restarted into it — and
    # `Pathname#untaint` is gone from 3.2 onward. **The era's own bundler is what can run there** (3.2
    # ships 2.4.22 and 3.3 ships 2.6.9), and the trailer is the only thing that stops it: dropping the
    # two lines lets the era's bundler read the lock and write its own version back on the next install.
    #
    # **Whether a bundler can run is a fact about the interpreter, so it is asked of the interpreter**
    # (`bundle --version` in the era's own container) rather than tabulated here — the same reason the
    # digest states a condition and lets the caller evaluate it.
    module BundlerTrailer
      TRAILER = /\nBUNDLED WITH\n[ \t]+\S+[ \t]*\n?\z/

      # The lock without its trailer, or nil when it has none — which is "nothing to drop" rather than
      # "nothing to say".
      def self.drop(text)
        return nil unless text.to_s.match?(TRAILER)

        text.to_s.sub(TRAILER, "\n")
      end

      # The version the trailer names, for the record's own sentence. Nil when it names none.
      def self.version(text)
        text.to_s[/^BUNDLED WITH\n[ \t]+(\S+)/, 1]
      end
    end
  end
end
