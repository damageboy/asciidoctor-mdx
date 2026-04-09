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

  describe 'paragraphs and inline formatting' do
    def chapter_content(source)
      result = convert_to_mdx("= Doc\n\n[#ch]\n== Ch\n\n#{source}")
      result['ch']
    end

    it 'renders a plain paragraph' do
      expect(chapter_content('Hello world.')).to include('Hello world.')
    end

    it 'escapes curly braces' do
      expect(chapter_content('The {rd} register.')).to include('The \{rd\} register.')
    end

    it 'escapes bare less-than' do
      expect(chapter_content('Value < 10.')).to include('Value \< 10.')
    end

    it 'renders bold' do
      expect(chapter_content('*bold* text')).to include('**bold** text')
    end

    it 'renders italic' do
      expect(chapter_content('_italic_ text')).to include('_italic_ text')
    end

    it 'renders monospace' do
      expect(chapter_content('`mono` text')).to include('`mono` text')
    end

    it 'renders superscript' do
      expect(chapter_content('^super^')).to include('<sup>super</sup>')
    end

    it 'renders subscript' do
      expect(chapter_content('~sub~')).to include('<sub>sub</sub>')
    end

    it 'renders a URL link' do
      expect(chapter_content('See https://riscv.org[RISC-V].')).to include('[RISC-V](https://riscv.org)')
    end
  end
end
