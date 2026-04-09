# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = 'asciidoctor-mdx'
  spec.version       = '0.1.0'
  spec.authors       = ['Dan Shechter']
  spec.summary       = 'Asciidoctor backend that converts documents to Docusaurus v3 MDX files'
  spec.license       = 'MIT'

  spec.files         = Dir['lib/**/*.rb']
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 3.0'
  spec.add_runtime_dependency 'asciidoctor', '>= 2.0'
end
