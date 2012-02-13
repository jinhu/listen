require 'find'
require 'digest/sha1'

require 'listen/adapter'
require 'listen/adapters/darwin'
require 'listen/adapters/linux'
require 'listen/adapters/polling'
require 'listen/adapters/windows'

module Listen
  class Listener
    attr_accessor :directory, :ignored_paths, :file_filters, :sha1_checksums, :paths, :adapter

    # Default paths that gets ignored by the listener
    DEFAULT_IGNORED_PATHS = %w[.bundle .git .DS_Store log tmp vendor]

    # Initialize the file listener.
    #
    # @param [String, Pathname] dir the directory to watch
    # @param [Hash] options the listen options
    # @option options [String] ignore a list of paths to ignore
    # @option options [Regexp] filter a list of regexps file filters
    # @option options [Integer] latency the delay between checking for changes
    # @option options [Boolean] polling whether to force or disable the polling adapter
    #
    # @yield [modified, added, removed] the changed files
    # @yieldparam [Array<String>] modified the list of modified files
    # @yieldparam [Array<String>] added the list of added files
    # @yieldparam [Array<String>] removed the list of removed files
    #
    # @return [Listen::Listener] the file listener
    #
    def initialize(dir, options = {}, &block)
      @directory      = dir
      @ignored_paths  = DEFAULT_IGNORED_PATHS
      @file_filters   = []
      @sha1_checksums = {}
      @block          = block
      @adapter        = Adapter.select_and_initialize(self, :use_polling => options[:polling])

      unless options.empty?
        @ignored_paths  += Array(options[:ignore]) if options[:ignore]
        @file_filters   += Array(options[:filter]) if options[:filter]
        @adapter.latency = options[:latency]       if options[:latency]
      end
    end

    # Initialize the @paths and start the adapter.
    #
    def start
      init_paths
      @adapter.start
    end

    # Stop the adapter.
    #
    def stop
      @adapter.stop
    end

    # Add ignored path to the listener.
    #
    # @example Ignore some paths
    #   ignore ".git", ".svn"
    #
    # @param [Array<String>] paths a list of paths to ignore
    #
    # @return [Listen::Listener] the listener itself
    #
    def ignore(*paths)
      @ignored_paths.push(*paths)
      self
    end

    # Add file filters to the listener.
    #
    # @example Filter some files
    #   ignore /\.txt$/, /.*\.zip/
    #
    # @param [Array<Regexp>] regexps a list of regexps file filters
    #
    # @return [Listen::Listener] the listener itself
    #
    def filter(*regexps)
      @file_filters.push(*regexps)
      self
    end

    # Sets the latency for the adapter. This is a helper method
    # to simplify changing the latency directly from the listener.
    #
    # @example Wait 5 seconds each time before checking changes
    #   latency 5
    #
    # @param [Integer] seconds the amount of delay, in seconds
    #
    # @return [Listen::Listener] the listener itself
    #
    def latency(seconds)
      @adapter.latency = seconds
      self
    end

    # Defines wheather the use of the polling adapter
    # should be forced or disabled.
    #
    # @example Forcing the use of the polling adapter
    #   polling true
    #
    # @param [Boolean] force_or_disable wheather to force or disable the polling adapter
    #
    # @return [Listen::Listener] the listener itself
    #
    def polling(force_or_disable)
      @adapter = Adapter.select_and_initialize(self, :use_polling => force_or_disable)
      self
    end

    # Set change callback block to the listener.
    #
    # @example Assign a callback to be called on changes
    #   callback = lambda { |modified, added, removed| ... }
    #   change &callback
    #
    # @param [Block] block a block callback called on changes
    #
    # @return [Listen::Listener] the listener itself
    #
    def change(&block) # modified, added, removed
      @block = block
      self
    end

    # Call @block callback when there is a diff in the passed directory.
    #
    # @param [Array] directories the list of directories to diff
    #
    def on_change(directories, diff_options = {})
      changes = diff(directories, diff_options)
      unless changes.values.all? { |paths| paths.empty? }
        @block.call(changes[:modified],changes[:added],changes[:removed])
      end
    end

    # Initialize the @paths double levels Hash with all existing paths and set diffed_at.
    #
    def init_paths
      @paths = Hash.new { |h,k| h[k] = {} }
      all_existing_paths { |path| insert_path(path) }
      @diffed_at = Time.now.to_i
    end

    # Detect changes diff in a directory.
    #
    # @param [Array] directories the list of directories to diff
    # @param [Hash] options
    # @option options [Boolean] recursive scan all sub-direcoties recursively (true when polling)
    # @return [Hash<Array>] the file changes
    #
    def diff(directories, options = {})
      @changes    = { :modified => [], :added => [], :removed => [] }
      directories = directories.sort_by { |el| el.length }.reverse # diff sub-dir first
      directories.each do |directory|
        detect_modifications_and_removals(directory, options)
        detect_additions(directory, options)
      end
      @diffed_at = Time.now.to_i
      @changes
    end

  private

    # Research all existing paths (directories & files) filtered and without ignored directories paths.
    #
    # @yield [path] the existing path
    #
    def all_existing_paths
      Find.find(@directory) do |path|
        next if @directory == path

        if File.directory?(path)
          if ignored_path?(path)
            Find.prune # Don't look any further into this directory.
          else
            yield(path)
          end
        elsif !ignored_path?(path) && filtered_file?(path)
          yield(path)
        end
      end
    end

    # Insert a path with its type (Dir or File) in @paths.
    #
    # @param [String] path the path to insert in @paths.
    #
    def insert_path(path)
      @paths[File.dirname(path)][File.basename(path)] = File.directory?(path) ? 'Dir' : 'File'
    end

    # Find is a path exists in @paths.
    #
    # @param [String] path the path to find in @paths.
    # @return [Boolean]
    #
    def existing_path?(path)
      @paths[File.dirname(path)][File.basename(path)] != nil
    end

    # Detect modifications and removals recursivly in a directory.
    # Modifications detection are based on mtime first and on checksum when mtime == last diffed_at
    #
    # @param [String] directory the path to analyze
    # @param [Hash] options
    # @option options [Boolean] recursive scan all sub-direcoties recursively (when polling)
    #
    def detect_modifications_and_removals(directory, options = {})
      @paths[directory].each do |basename, type|
        path = File.join(directory, basename)

        case type
        when 'Dir'
          if File.directory?(path)
            detect_modifications_and_removals(path, options) if options[:recursive]
          else
            detect_modifications_and_removals(path, :recursive => true)
            @paths[directory].delete(basename)
            @paths.delete("#{directory}/#{basename}")
          end
        when 'File'
          if File.exist?(path)
            new_mtime = File.mtime(path).to_i
            if @diffed_at < new_mtime || (@diffed_at == new_mtime && content_modified?(path))
              @changes[:modified] << relative_path(path)
            end
          else
            @paths[directory].delete(basename)
            @sha1_checksums.delete(path)
            @changes[:removed] << relative_path(path)
          end
        end
      end
    end

    # Tests if the file content has been modified by
    # comparing the SHA1 checksum.
    #
    # @param [String] path the file path
    #
    def content_modified?(path)
      sha1_checksum = Digest::SHA1.file(path).to_s
      if @sha1_checksums[path] != sha1_checksum
        @sha1_checksums[path] = sha1_checksum
        true
      else
        false
      end
    end

    # Detect additions in a directory.
    #
    # @param [String] directory the path to analyze
    # @param [Hash] options
    # @option options [Boolean] recursive scan all sub-direcoties recursively (when polling)
    #
    def detect_additions(directory, options = {})
      Find.find(directory) do |path|
        next if @directory == path

        if File.directory?(path)
          if directory != path && (ignored_path?(path) || (!options[:recursive] && existing_path?(path)))
            Find.prune # Don't look any further into this directory.
          else
            insert_path(path)
          end
        elsif !existing_path?(path) && !ignored_path?(path) && filtered_file?(path)
          @changes[:added] << relative_path(path) if File.file?(path)
          insert_path(path)
        end
      end
    end

    # Convert absolute path to a path relative to the listener directory (by default).
    #
    # @param [String] path the path to convert
    # @param [String] directory the directoy path to relative from
    # @return [String] the relative converted path
    #
    def relative_path(path, directory = @directory)
      base_dir = directory.sub(/\/$/, '')
      path.sub(%r(^#{base_dir}/), '')
    end

    # Test if a path should be ignored or not.
    #
    # @param [String] path the path to test.
    # @return [Boolean]
    #
    def ignored_path?(path)
      @ignored_paths.any? { |ignored_path| path =~ /#{ignored_path}$/ }
    end

    # Test if a file path should be filtered or not.
    #
    # @param [String] path the file path to test.
    # @return [Boolean]
    #
    def filtered_file?(path)
      @file_filters.empty? || @file_filters.any? { |file_filter| path =~ file_filter }
    end

  end
end
