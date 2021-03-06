require 'pdk'

module PDK
  module Validate
    # A base class for file based validators.
    # This class provides base methods and helpers to help determine the file targets to validate against.
    # Acutal validator implementation should inherit from other child abstract classes e.g. ExternalCommandValdiator
    # @see PDK::Validate::Validator
    # @abstract
    class InvokableValidator < Validator
      # Controls how many times the validator is invoked.
      #
      #   :once -       The validator will be invoked once and passed all the
      #                 targets.
      #   :per_target - The validator will be invoked for each target
      #                 separately.
      # @abstract
      def invoke_style
        :once
      end

      # An array, or a string, of glob patterns to use to find targets
      # @return [Array[String], String]
      # @abstract
      def pattern; end

      # An array, or a string, of glob patterns to use to ignore targets
      # @return [Array[String], String, Nil]
      # @abstract
      def pattern_ignore; end

      # @see PDK::Validate::Validator.prepare_invoke!
      def prepare_invoke!
        return if @prepared
        super

        # Register the spinner
        spinner
        nil
      end

      # Parses the target strings provided from the CLI
      #
      # @param options [Hash] A Hash containing the input options from the CLI.
      #
      # @return targets [Array] An Array of Strings containing target file paths
      #                         for the validator to validate.
      # @return skipped [Array] An Array of Strings containing targets
      #                         that are skipped due to target not containing
      #                         any files that can be validated by the validator.
      # @return invalid [Array] An Array of Strings containing targets that do
      #                         not exist, and will not be run by validator.
      def parse_targets
        requested_targets = options.fetch(:targets, [])
        # If no targets are specified and empty targets are allowed return with an empty list.
        # It will be up to the validator (and whatever validation tool it uses) to determine the
        # targets. For example, using rubocop with no targets, will allow rubocop to determine the
        # target list using it's .rubocop.yml file
        return [[], [], []] if requested_targets.empty? && allow_empty_targets?
        # If no targets are specified, then we will run validations from the
        # base module directory.
        targets = requested_targets.empty? ? [PDK::Util.module_root] : requested_targets

        targets.map! { |r| r.gsub(File::ALT_SEPARATOR, File::SEPARATOR) } if File::ALT_SEPARATOR
        skipped = []
        invalid = []
        matched = targets.map { |target|
          if pattern.nil?
            target
          else
            if PDK::Util::Filesystem.directory?(target) # rubocop:disable Style/IfInsideElse
              target_root = PDK::Util.module_root
              pattern_glob = Array(pattern).map { |p| PDK::Util::Filesystem.glob(File.join(target_root, p), File::FNM_DOTMATCH) }
              target_list = pattern_glob.flatten
                                        .select { |glob| PDK::Util::Filesystem.fnmatch(File.join(PDK::Util::Filesystem.expand_path(PDK::Util.canonical_path(target)), '*'), glob, File::FNM_DOTMATCH) }
                                        .map { |glob| Pathname.new(glob).relative_path_from(Pathname.new(PDK::Util.module_root)).to_s }

              ignore_list = ignore_pathspec
              target_list = target_list.reject { |file| ignore_list.match(file) }

              skipped << target if target_list.flatten.empty?
              target_list
            elsif PDK::Util::Filesystem.file?(target)
              if Array(pattern).include? target
                target
              elsif Array(pattern).any? { |p| PDK::Util::Filesystem.fnmatch(PDK::Util::Filesystem.expand_path(p), PDK::Util::Filesystem.expand_path(target), File::FNM_DOTMATCH) }
                target
              else
                skipped << target
                next
              end
            else
              invalid << target
              next
            end
          end
        }.compact.flatten
        [matched, skipped, invalid]
      end

      # Whether the target parsing ignores "dotfiles" (e.g. .gitignore or .pdkignore) which are considered hidden files in POSIX
      # @return [Boolean]
      # @abstract
      def ignore_dotfiles?
        true
      end

      # @see PDK::Validate::Validator.spinner_text
      # @abstract
      def spinner_text
        _('Running %{name} validator ...') % { name: name }
      end

      # @see PDK::Validate::Validator.spinner
      def spinner
        return nil unless spinners_enabled?
        return @spinner unless @spinner.nil?
        require 'pdk/cli/util/spinner'

        @spinner = TTY::Spinner.new("[:spinner] #{spinner_text}", PDK::CLI::Util.spinner_opts_for_platform)
      end

      # Process any targets that were skipped by the validator and add the events to the validation report
      # @param report [PDK::Report] The report to add the events to
      # @param skipped [Array[String]] The list of skipped targets
      def process_skipped(report, skipped = [])
        skipped.each do |skipped_target|
          PDK.logger.debug(_('%{validator}: Skipped \'%{target}\'. Target does not contain any files to validate (%{pattern}).') % { validator: name, target: skipped_target, pattern: pattern })
          report.add_event(
            file:     skipped_target,
            source:   name,
            message:  _('Target does not contain any files to validate (%{pattern}).') % { pattern: pattern },
            severity: :info,
            state:    :skipped,
          )
        end
      end

      # Process any targets that were invalid by the validator and add the events to the validation report
      # @param report [PDK::Report] The report to add the events to
      # @param invalid [Array[String]] The list of invalid targets
      def process_invalid(report, invalid = [])
        invalid.each do |invalid_target|
          PDK.logger.debug(_('%{validator}: Skipped \'%{target}\'. Target file not found.') % { validator: name, target: invalid_target })
          report.add_event(
            file:     invalid_target,
            source:   name,
            message:  _('File does not exist.'),
            severity: :error,
            state:    :error,
          )
        end
      end

      # Controls how the validator behaves if not passed any targets.
      #
      #   true  - PDK will not pass the globbed targets to the validator command
      #           and it will instead rely on the underlying tool to find its
      #           own default targets.
      #   false - PDK will pass the globbed targets to the validator command.
      # @abstract
      def allow_empty_targets?
        false
      end

      private

      # Helper method to collate the default ignored paths
      # @return [PathSpec] Paths to ignore
      def ignore_pathspec
        require 'pdk/module'

        ignore_pathspec = PDK::Module.default_ignored_pathspec(ignore_dotfiles?)

        unless pattern_ignore.nil?
          Array(pattern_ignore).each do |pattern|
            ignore_pathspec.add(pattern)
          end
        end

        ignore_pathspec
      end
    end
  end
end
