# frozen_string_literal: true

require 'asciidoctor'
require 'asciidoctor-mdx'
require 'json'
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
      standalone: true,
      to_file: false,
      attributes: { 'stem' => 'latexmath', 'mdxdir' => tmpdir }.merge(attributes)
    )
    Dir[File.join(tmpdir, '*.mdx')].each_with_object({}) do |path, h|
      h[File.basename(path, '.mdx')] = File.read(path)
    end
  end
end

# Helper: convert an adoc string with mdx-sidebar-dir set, return parsed sidebar.json or nil.
def convert_to_sidebar(source, dir:, attributes: {})
  Dir.mktmpdir do |tmpdir|
    Asciidoctor.convert(
      source,
      backend: 'mdx',
      safe: :safe,
      standalone: true,
      to_file: false,
      attributes: { 'stem' => 'latexmath', 'mdxdir' => tmpdir, 'mdx-sidebar-dir' => dir }.merge(attributes)
    )
    path = File.join(tmpdir, 'sidebar.json')
    File.exist?(path) ? JSON.parse(File.read(path)) : nil
  end
end
