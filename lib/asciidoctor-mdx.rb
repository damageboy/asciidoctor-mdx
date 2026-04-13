# frozen_string_literal: true

require 'asciidoctor'
require_relative 'asciidoctor/converter/mdx_converter'

# Enable sourcemap automatically so the MDX converter can read
# node.source_location (used for last_update frontmatter).
# sourcemap is a processor-level option that must be set before parsing;
# it cannot be passed via the asciidoctor CLI.  Patching convert_file here
# ensures it is always active when this gem is loaded.
module Asciidoctor
  class << self
    prepend(Module.new do
      def convert_file(filename, options = {})
        super(filename, { sourcemap: true }.merge(options))
      end
    end)
  end
end
