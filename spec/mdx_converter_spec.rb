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

  describe 'section headings' do
    let(:source) do
      <<~ADOC
        = Doc

        [#intro]
        == Introduction

        [#overview]
        === Overview

        Some text.

        [#details]
        ==== Details

        More text.
      ADOC
    end

    it 'renders subsections as ## headings with MDX comment ID' do
      result = convert_to_mdx(source)
      expect(result['intro']).to include('## Overview {/* #overview */}')
    end

    it 'renders level 3 subsections as ### headings' do
      result = convert_to_mdx(source)
      expect(result['intro']).to include('### Details {/* #details */}')
    end

    it 'does not emit a heading for the top-level chapter section itself' do
      result = convert_to_mdx(source)
      expect(result['intro']).not_to include('# Introduction')
    end

    it 'escapes curly braces in heading titles' do
      src = "= Doc\n\n[#ch]\n== Ch\n\n[#h2]\n=== Heading {foo}\n\nText."
      result = convert_to_mdx(src)
      expect(result['ch']).to include('## Heading \{foo\} {/* #h2 */}')
    end
  end

  describe 'code blocks' do
    def chapter_content(source)
      result = convert_to_mdx("= Doc\n\n[#ch]\n== Ch\n\n#{source}")
      result['ch']
    end

    it 'renders a listing block as a fenced code block' do
      src = "[source,ruby]\n----\nputs 'hello'\n----"
      expect(chapter_content(src)).to include("```ruby\nputs 'hello'\n```")
    end

    it 'renders a listing block without language as plain fenced block' do
      src = "----\nsome text\n----"
      expect(chapter_content(src)).to include("```\nsome text\n```")
    end

    it 'renders a literal block as a plain fenced code block' do
      src = "....\nindented literal\n...."
      expect(chapter_content(src)).to include("```\nindented literal\n```")
    end

    it 'does not escape curly braces inside code blocks' do
      src = "[source,c]\n----\nvoid f(int {x}) {}\n----"
      expect(chapter_content(src)).to include("void f(int {x}) {}")
    end
  end

  describe 'math' do
    def chapter_content(source)
      result = convert_to_mdx("= Doc\n\n[#ch]\n== Ch\n\n#{source}")
      result['ch']
    end

    it 'renders inline stem as $...$ KaTeX' do
      expect(chapter_content('The value stem:[x = y + z] is shown.')).to include('$x = y + z$')
    end

    it 'renders a block stem as a ```math fenced block' do
      src = "[stem]\n++++\n\\sum_{i=0}^{n} x_i\n++++"
      content = chapter_content(src)
      expect(content).to include("```math\n\\sum_{i=0}^{n} x_i\n```")
    end

    it 'does not escape LaTeX braces inside math blocks' do
      src = "[stem]\n++++\n\\frac{a}{b}\n++++"
      expect(chapter_content(src)).to include('\\frac{a}{b}')
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
