# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

module Agents
  module Upgrader
    # **The walker's environment, written where the site admin can read it.**
    #
    # The site admin cannot see the host: the era images live on the daemon, the disk is the walker's
    # volume, and the interpreter matrix is the client's data. This is the third feed of that kind,
    # beside the progress file and the delivery list, and it exists for the same reason — the public
    # contract is frozen, so the operator's own surface is where a fact the service cannot query goes.
    #
    # What is written is what a preflight would ask: does every era in the matrix name an image, and
    # does the daemon have it; how much room is left on the volume the walk writes to; and when this
    # reading was taken. Docker and `df` can refuse, and a refusal is a fact too — it is recorded as
    # the reason rather than hidden, because "no disk figure" and "plenty of disk" must not look the
    # same on an operator's page.
    class Environment
      FILE = "environment.json"

      def self.path(home) = File.join(Progress.dir(home), FILE)

      def initialize(home:, out: nil, df: nil, images: nil, matrix: nil)
        @home = home
        @out = out
        @df = df || method(:disk_usage)
        @images = images || method(:daemon_images)
        @matrix = matrix || method(:interpreters)
      end

      def path = self.class.path(@home)

      # One reading, replacing the file whole. Anything that cannot be read is carried as a reason.
      def write
        matrix, matrix_problem = read_matrix
        images, images_problem = @images.call(matrix.map { |entry| entry["image"] }.compact)
        disk, disk_problem = @df.call(@home)
        document = {
          "read_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "home" => @home.to_s,
          "eras" => matrix,
          "eras_problem" => matrix_problem,
          "images" => images,
          "images_problem" => images_problem,
          "disk" => disk,
          "disk_problem" => disk_problem
        }
        write_file(document)
        document
      end

      private

      def read_matrix
        [Array(@matrix.call).map { |entry| entry.respond_to?(:to_h) ? entry.to_h : entry }, nil]
      rescue StandardError => e
        [[], "#{e.class}: #{e.message}"]
      end

      def interpreters = Interpreters.matrix

      # `df -Pk` is the POSIX form: 1024-byte blocks, one line per filesystem, and the path's own
      # filesystem first. The columns are filesystem, total, used, available, capacity, mount.
      def disk_usage(path)
        output, status = Open3.capture2e("df", "-Pk", path.to_s)
        return [nil, "df exited #{status.exitstatus}: #{output.to_s.lines.first.to_s.strip}"] unless status.success?

        line = output.to_s.lines[1].to_s.split
        return [nil, "df answered a line this cannot read"] if line.length < 4
        return [nil, "df answered a size this cannot read"] unless line[1].to_s.match?(/\A\d+\z/) && line[3].to_s.match?(/\A\d+\z/)

        [{ "path" => path.to_s, "total_bytes" => line[1].to_i * 1024,
           "free_bytes" => line[3].to_i * 1024 }, nil]
      rescue SystemCallError => e
        [nil, "df could not be run: #{e.class}: #{e.message}"]
      end

      # One daemon call for every ref, because an image is a host fact and a per-era `inspect` would
      # be one call per era on every cycle. The list is `repository:tag`, which is how the matrix
      # spells a ref; a digest-pinned ref is matched by its repository and tag prefix below.
      def daemon_images(references)
        return [{}, "no era image is declared"] if references.empty?

        output, status = Open3.capture2e("docker", "image", "ls", "--format", "{{.Repository}}:{{.Tag}}")
        return [{}, "the daemon answered #{status.exitstatus}: #{output.to_s.lines.first.to_s.strip}"] unless status.success?

        present = output.to_s.lines.map(&:strip).reject(&:empty?)
        found = references.each_with_object({}) do |reference, out|
          out[reference] = present.any? { |image| image == reference || image.start_with?("#{reference.split("@").first}:") }
        end
        [found, nil]
      rescue SystemCallError => e
        [{}, "docker could not be run: #{e.class}: #{e.message}"]
      end

      def write_file(document)
        FileUtils.mkdir_p(File.dirname(path))
        temporary = "#{path}.#{Process.pid}.tmp"
        File.write(temporary, JSON.pretty_generate(document))
        File.rename(temporary, path)
      rescue SystemCallError => e
        @out&.puts("  environment: not written: #{e.class}: #{e.message}")
      end
    end
  end
end
