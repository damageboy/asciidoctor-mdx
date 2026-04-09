# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MdxConverter do
  describe 'document splitting' do
    let(:source) do
      <<~ADOC
        = The Manual

        [#chapter-one]
        == Chapter One

        Content of chapter one.

        [#chapter-two]
        == Chapter Two

        Content of chapter two.
      ADOC
    end

    it 'produces one .mdx file per top-level section' do
      result = convert_to_mdx(source)
      expect(result.keys).to contain_exactly('chapter-one', 'chapter-two')
    end

    it 'includes YAML frontmatter with title and sidebar_position' do
      result = convert_to_mdx(source)
      expect(result['chapter-one']).to start_with("---\n")
      expect(result['chapter-one']).to include('title: Chapter One')
      expect(result['chapter-one']).to include('sidebar_position: 1')
      expect(result['chapter-two']).to include('sidebar_position: 2')
    end

    it 'includes id and sidebar_label in frontmatter' do
      result = convert_to_mdx(source)
      expect(result['chapter-one']).to include('id: chapter-one')
      expect(result['chapter-one']).to include('sidebar_label: Chapter One')
    end

    it 'slugifies title when section has no explicit id' do
      src = "= Doc\n\n== Hello World\n\nContent."
      result = convert_to_mdx(src)
      expect(result.keys).to include('hello-world')
    end
  end
end
