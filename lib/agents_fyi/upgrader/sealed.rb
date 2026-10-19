# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # **A path in a working copy, and nothing outside it.**
    #
    # Two things now write into somebody's tree — the ladder's scanned edits (`Applier`) and the
    # effects of an accepted decision (`Effects`) — and they must agree about what a legal path is,
    # down to the sentences a refusal carries. This was the applier's private guard until the second
    # writer arrived; a private copy is how one of them would come to accept `app/models -> /tmp`.
    #
    # Checked by spelling first and by *real* path second, because the two catch different escapes:
    # `../` is a path nobody means, and a symlink to `/etc/passwd` is a path that looks like it
    # belongs here.
    module Sealed
      module_function

      # `[full_path, nil]` when the path is a file this writer may touch, `[nil, sentence]` when it is
      # not. `root_real` is the resolved root, passed by a caller that already has it because a
      # scanned run checks thousands of paths and a `realpath` each would be the cost of the scan.
      def path(root, path, root_real: nil)
        root = File.expand_path(root)
        root_real ||= resolved(root)

        if path.start_with?("/")
          return [nil, "an absolute path (#{path}) is not a file in the working copy"]
        end

        full = File.expand_path(path, root)
        return [nil, "#{path} is the working copy itself, not a file in it"] if full == root
        unless full.start_with?("#{root}#{File::SEPARATOR}")
          return [nil, "#{path} resolves outside the working copy"]
        end

        real_parent = File.realpath(File.dirname(full))
        unless inside?(root_real, real_parent)
          return [nil, "#{path} is under #{real_parent}, which is outside the working copy"]
        end

        if File.symlink?(full)
          real = File.realpath(full)
          unless inside?(root_real, real)
            return [nil, "#{path} is a symlink to #{real}, which is outside the working copy"]
          end
        end

        [full, nil]
      rescue SystemCallError => e
        [nil, "#{path} could not be resolved (#{e.class}: #{e.message})"]
      end

      def resolved(root)
        File.realpath(root)
      rescue SystemCallError
        File.expand_path(root)
      end

      def inside?(root_real, real)
        real == root_real || real.start_with?("#{root_real}#{File::SEPARATOR}")
      end
    end
  end
end
