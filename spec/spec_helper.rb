# frozen_string_literal: true

require 'asciidoctor'
require 'asciidoctor-mdx'
require 'tmpdir'

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

# Helper: convert an adoc string, write MDX to a tmpdir, return {slug => content} hash.
def convert_to_mdx(source, attributes: {})
  Dir.mktmpdir do |tmpdir|
    Asciidoctor.convert(
      source,
      backend: 'mdx',
      safe: :safe,
      to_dir: tmpdir,
      to_file: false,
      attributes: { 'stem' => 'latexmath' }.merge(attributes)
    )
    Dir[File.join(tmpdir, '*.mdx')].each_with_object({}) do |path, h|
      h[File.basename(path, '.mdx')] = File.read(path)
    end
  end
end
