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

    it 'renders subsections as ## headings with Docusaurus heading ID' do
      result = convert_to_mdx(source)
      expect(result['intro']).to include('## Overview {#overview}')
    end

    it 'renders level 3 subsections as ### headings' do
      result = convert_to_mdx(source)
      expect(result['intro']).to include('### Details {#details}')
    end

    it 'does not emit a heading for the top-level chapter section itself' do
      result = convert_to_mdx(source)
      expect(result['intro']).not_to include('# Introduction')
    end

    it 'escapes curly braces in heading titles' do
      src = "= Doc\n\n[#ch]\n== Ch\n\n[#h2]\n=== Heading {foo}\n\nText."
      result = convert_to_mdx(src)
      expect(result['ch']).to include('## Heading \{foo\} {#h2}')
    end

    context 'with :sectnums:' do
      let(:source) do
        <<~ADOC
          = Doc
          :sectnums:

          [#chone]
          == Chapter One

          [#sec1]
          === Section One

          Text.

          [#sec2]
          === Section Two

          Text.

          [#chtwo]
          == Chapter Two

          [#sec3]
          === Section Three

          Text.
        ADOC
      end

      it 'prefixes subsection headings with dotted numbers' do
        result = convert_to_mdx(source)
        expect(result['chone']).to include('## 1.1 Section One {#sec1}')
        expect(result['chone']).to include('## 1.2 Section Two {#sec2}')
        expect(result['chtwo']).to include('## 2.1 Section Three {#sec3}')
      end

      it 'includes chapter number in frontmatter title and sidebar_label' do
        result = convert_to_mdx(source)
        expect(result['chone']).to include('title: 1 Chapter One')
        expect(result['chone']).to include('sidebar_label: 1 Chapter One')
        expect(result['chtwo']).to include('title: 2 Chapter Two')
      end

      it 'does not add numbers when :sectnums: is absent' do
        src = "= Doc\n\n[#ch]\n== Chapter\n\n[#s1]\n=== Section\n\nText."
        result = convert_to_mdx(src)
        expect(result['ch']).to include('## Section {#s1}')
        expect(result['ch']).not_to match(/## \d/)
        expect(result['ch']).to include('title: Chapter')
      end
    end
  end

  describe 'heading ID sanitization' do
    it 'replaces colons in section heading IDs with hyphens' do
      src = "= Doc\n\n[#ch]\n== Ch\n\n[#sec:overview]\n=== Overview\n\nText."
      result = convert_to_mdx(src)
      expect(result['ch']).to include('{#sec-overview}')
      expect(result['ch']).not_to include('{#sec:overview}')
    end

    it 'replaces multiple colons in a heading ID' do
      src = "= Doc\n\n[#ch]\n== Ch\n\n[#sec:memory:acqrel]\n=== Acqrel\n\nText."
      result = convert_to_mdx(src)
      expect(result['ch']).to include('{#sec-memory-acqrel}')
    end

    it 'leaves IDs without colons unchanged in headings' do
      src = "= Doc\n\n[#ch]\n== Ch\n\n[#_csr_instructions]\n=== CSR\n\nText."
      result = convert_to_mdx(src)
      expect(result['ch']).to include('{#_csr_instructions}')
    end

    it 'sanitizes anchor in same-chapter xref link' do
      src = <<~ADOC
        = Doc

        [#ch]
        == Ch

        See <<sec:overview,Overview>>.

        [#sec:overview]
        === Overview

        Text.
      ADOC
      result = convert_to_mdx(src)
      expect(result['ch']).to include('[Overview](#sec-overview)')
      expect(result['ch']).not_to include('#sec:overview')
    end

    it 'sanitizes anchor in cross-chapter xref link' do
      src = <<~ADOC
        = Doc

        [#ch-a]
        == Chapter A

        See <<sec:detail,Detail>>.

        [#ch-b]
        == Chapter B

        [#sec:detail]
        === Detail

        Text.
      ADOC
      result = convert_to_mdx(src)
      expect(result['ch-a']).to include('[Detail](./ch-b#sec-detail)')
      expect(result['ch-a']).not_to include('#sec:detail')
    end

    it 'sanitizes colon IDs in sidebar anchor hrefs' do
      src = <<~ADOC
        = Doc

        [#ch1]
        == Chapter One

        [#sec:one]
        === Section One

        Content.
      ADOC
      data = convert_to_sidebar(src, dir: 'unprivileged')
      chapter = data.first
      expect(chapter['items'].first['href']).to eq('unprivileged/ch1#sec-one')
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

  describe 'diagram blocks (Kroki)' do
    def chapter_content(source)
      result = convert_to_mdx("= Doc\n\n[#ch]\n== Ch\n\n#{source}")
      result['ch']
    end

    it 'renders a graphviz listing as a graphviz fenced block' do
      src = "[source,graphviz]\n----\ndigraph G { A -> B }\n----"
      expect(chapter_content(src)).to include("```graphviz\ndigraph G { A -> B }\n```")
    end

    it 'renders a plantuml listing as a plantuml fenced block' do
      src = "[source,plantuml]\n----\n@startuml\nA -> B\n@enduml\n----"
      expect(chapter_content(src)).to include("```plantuml\n@startuml")
    end

    it 'does not escape diagram source content' do
      src = "[source,graphviz]\n----\ndigraph G { A [label=\"test\"]; }\n----"
      expect(chapter_content(src)).to include('{')
    end
  end

  describe 'admonitions' do
    def chapter_content(source)
      result = convert_to_mdx("= Doc\n\n[#ch]\n== Ch\n\n#{source}")
      result['ch']
    end

    it 'renders NOTE as :::note' do
      expect(chapter_content('NOTE: This is a note.')).to include(":::note\n")
    end

    it 'renders TIP as :::tip' do
      expect(chapter_content('TIP: This is a tip.')).to include(":::tip\n")
    end

    it 'renders IMPORTANT as :::info' do
      expect(chapter_content('IMPORTANT: This is important.')).to include(":::info\n")
    end

    it 'renders WARNING as :::warning' do
      expect(chapter_content('WARNING: This is a warning.')).to include(":::warning\n")
    end

    it 'renders CAUTION as :::danger' do
      expect(chapter_content('CAUTION: Take caution.')).to include(":::danger\n")
    end
  end

  describe 'lists' do
    def chapter_content(source)
      result = convert_to_mdx("= Doc\n\n[#ch]\n== Ch\n\n#{source}")
      result['ch']
    end

    it 'renders an unordered list' do
      src = "* Alpha\n* Beta\n* Gamma"
      content = chapter_content(src)
      expect(content).to include("- Alpha\n")
      expect(content).to include("- Beta\n")
      expect(content).to include("- Gamma\n")
    end

    it 'renders an ordered list' do
      src = ". First\n. Second\n. Third"
      content = chapter_content(src)
      expect(content).to include("1. First\n")
      expect(content).to include("2. Second\n")
      expect(content).to include("3. Third\n")
    end

    it 'renders a definition list as bold term + paragraph' do
      src = "term:: definition text"
      content = chapter_content(src)
      expect(content).to include('**term**')
      expect(content).to include('definition text')
    end

    it 'renders nested unordered lists with indentation' do
      src = "* Top\n** Nested\n*** Deep"
      content = chapter_content(src)
      expect(content).to include("- Top\n")
      expect(content).to include("  - Nested\n")
      expect(content).to include("    - Deep\n")
    end

    it 'escapes curly braces in list item text' do
      src = "* The {rd} register\n* Value < 10"
      content = chapter_content(src)
      expect(content).to include('- The \{rd\} register')
      expect(content).to include('- Value \< 10')
    end
  end

  describe 'tables' do
    def chapter_content(source)
      result = convert_to_mdx("= Doc\n\n[#ch]\n== Ch\n\n#{source}")
      result['ch']
    end

    let(:simple_table) do
      <<~ADOC
        [cols="1,1",options="header"]
        |===
        | Name | Value
        | foo  | 1
        | bar  | 2
        |===
      ADOC
    end

    it 'renders a table with a header row' do
      content = chapter_content(simple_table)
      expect(content).to include('| Name | Value |')
      expect(content).to include('| --- | --- |')
      expect(content).to include('| foo | 1 |')
      expect(content).to include('| bar | 2 |')
    end

    it 'separates header from body with a GFM separator row' do
      content = chapter_content(simple_table)
      lines = content.lines.map(&:strip)
      header_idx = lines.index { |l| l.include?('Name') && l.include?('Value') }
      expect(lines[header_idx + 1]).to match(/^\|(\s*---\s*\|)+$/)
    end

    describe 'grid tables (colspan/rowspan)' do
      def chapter_content(source)
        result = convert_to_mdx("= Doc\n\n[#ch]\n== Ch\n\n#{source}")
        result['ch']
      end

      it 'uses GFM pipe table for simple tables (no spans)' do
        src = <<~ADOC
          [cols="1,1",options="header"]
          |===
          | Name | Value
          | foo  | 1
          |===
        ADOC
        content = chapter_content(src)
        expect(content).to include('| Name | Value |')
        expect(content).not_to include('+---')
      end

      it 'uses grid table format for tables with colspan' do
        src = <<~ADOC
          [cols="1,1,1"]
          |===
          2+| Span Two | C
          | A | B      | C
          |===
        ADOC
        content = chapter_content(src)
        expect(content).to include('+')
        expect(content).to include('---')
      end

      it 'uses grid table format for tables with rowspan' do
        src = <<~ADOC
          [cols="1,1"]
          |===
          .2+| Tall | B1
                   | B2
          |===
        ADOC
        content = chapter_content(src)
        expect(content).to include('+')
      end

      it 'renders separator lines with + at every column boundary' do
        src2 = <<~ADOC
          [cols="1,1,1"]
          |===
          2+| Span | C
          | A | B  | C
          |===
        ADOC
        content2 = chapter_content(src2)
        lines = content2.lines.map(&:rstrip)
        # Top border: first line starting with +, contains only +, -, chars
        top_border = lines.find { |l| l.start_with?('+') }
        expect(top_border).to match(/^\+[-+]+\+$/)
        # Content line with colspan: has exactly 3 pipe chars (left + after span + after C)
        span_line = lines.find { |l| l.include?('Span') }
        expect(span_line.count('|')).to eq(3)
      end

      it 'renders = separator after header rows' do
        src = <<~ADOC
          [cols="1,1",options="header"]
          |===
          | Head1 | Head2
          2+| Span body
          |===
        ADOC
        content = chapter_content(src)
        expect(content).to match(/\+[=+]+\+/)
      end

      it 'renders spaces in separator where a rowspan cell continues' do
        src = <<~ADOC
          [cols="1,1"]
          |===
          .2+| Tall | B1
                    | B2
          |===
        ADOC
        content = chapter_content(src)
        lines = content.lines.map(&:rstrip)
        # The separator between the two body rows must have spaces for col 0 (spanning)
        # and dashes for col 1 (not spanning). Pattern: +<spaces>+<dashes>+
        mid_sep = lines.find { |l| l.match?(/^\+\s+\+[-]+\+$/) }
        expect(mid_sep).not_to be_nil
      end

      it 'renders correct separator for a cell with colspan and rowspan combined' do
        src = <<~ADOC
          [cols="1,1,1"]
          |===
          2.2+| Big | C1
                    | C2
          | A  | B  | C
          |===
        ADOC
        content = chapter_content(src)
        lines = content.lines.map(&:rstrip)
        # Separator between rows 0 and 1: Big spans cols 0-1 with rowspan=2.
        # Multi-column span collapses to one space block + | boundary; col 2 gets dashes.
        # Pattern: +<spaces>|<dashes>+
        mid_sep = lines.find { |l| l.match?(/^\+\s+\|[-]+\+$/) }
        expect(mid_sep).not_to be_nil
      end
    end
  end

  describe 'cross-references' do
    let(:source) do
      <<~ADOC
        = Doc

        [#chapter-a]
        == Chapter A

        See <<chapter-b,Chapter B>> for details.
        Also see <<local-section,this section>>.

        [#local-section]
        === Local Section

        Text here.

        [#chapter-b]
        == Chapter B

        See <<local-section,the local section in A>>.
      ADOC
    end

    it 'renders a cross-chapter xref as a relative MDX link' do
      result = convert_to_mdx(source)
      expect(result['chapter-a']).to include('[Chapter B](./chapter-b)')
    end

    it 'renders a same-chapter xref as an anchor-only link' do
      result = convert_to_mdx(source)
      expect(result['chapter-a']).to include('[this section](#local-section)')
    end

    it 'renders a cross-chapter xref to a subsection with chapter and anchor' do
      result = convert_to_mdx(source)
      expect(result['chapter-b']).to include('[the local section in A](./chapter-a#local-section)')
    end
  end

  describe 'remaining block types' do
    def chapter_content(source)
      result = convert_to_mdx("= Doc\n\n[#ch]\n== Ch\n\n#{source}")
      result['ch']
    end

    it 'renders an image macro' do
      expect(chapter_content('image::diagram.png[Architecture diagram]')).to \
        include('![Architecture diagram](diagram.png)')
    end

    it 'renders a quote block as a blockquote' do
      src = "[quote,Linus Torvalds]\n____\nTalk is cheap.\n____"
      expect(chapter_content(src)).to include('> Talk is cheap.')
    end

    it 'renders a sidebar as :::info' do
      src = "****\nSidebar content.\n****"
      expect(chapter_content(src)).to include(':::info')
      expect(chapter_content(src)).to include('Sidebar content.')
    end

    it 'renders an example block as :::note' do
      src = "====\nExample content.\n===="
      expect(chapter_content(src)).to include(':::note')
      expect(chapter_content(src)).to include('Example content.')
    end

    it 'renders a pass block as raw content' do
      src = "++++\n<em>raw html</em>\n++++"
      expect(chapter_content(src)).to include('<em>raw html</em>')
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

  describe 'sidebar generation' do
    it 'does not write sidebar.json when mdx-sidebar-dir is absent' do
      Dir.mktmpdir do |tmpdir|
        Asciidoctor.convert(
          "= Doc\n\n[#ch]\n== Chapter\n\nContent.",
          backend: 'mdx', safe: :safe, standalone: true, to_file: false,
          attributes: { 'mdxdir' => tmpdir }
        )
        expect(File.exist?(File.join(tmpdir, 'sidebar.json'))).to be false
      end
    end

    it 'writes a doc item for a leaf chapter (no sub-sections)' do
      src = "= Doc\n\n[#ch1]\n== Chapter One\n\nContent."
      data = convert_to_sidebar(src, dir: 'unprivileged')
      expect(data).to eq([
        { 'type' => 'doc', 'id' => 'unprivileged/ch1', 'label' => 'Chapter One' }
      ])
    end

    it 'writes a category with doc link for a chapter with level-2 sections' do
      src = <<~ADOC
        = Doc

        [#ch1]
        == Chapter One

        [#sec1]
        === Section One

        Content.

        [#sec2]
        === Section Two

        Content.
      ADOC
      data = convert_to_sidebar(src, dir: 'unprivileged')
      chapter = data.first
      expect(chapter['type']).to eq('category')
      expect(chapter['label']).to eq('Chapter One')
      expect(chapter['link']).to eq({ 'type' => 'doc', 'id' => 'unprivileged/ch1' })
      expect(chapter['collapsible']).to eq(true)
      expect(chapter['collapsed']).to eq(true)
      expect(chapter['items']).to eq([
        { 'type' => 'link', 'label' => 'Section One', 'href' => 'unprivileged/ch1#sec1' },
        { 'type' => 'link', 'label' => 'Section Two', 'href' => 'unprivileged/ch1#sec2' }
      ])
    end

    it 'wraps a level-2 section with children in a category, self-link first' do
      src = <<~ADOC
        = Doc

        [#ch1]
        == Chapter One

        [#sec1]
        === Section One

        [#sub1]
        ==== Sub One

        [#sub2]
        ==== Sub Two

        Content.
      ADOC
      data = convert_to_sidebar(src, dir: 'unprivileged')
      chapter = data.first
      sec1 = chapter['items'].first
      expect(sec1['type']).to eq('category')
      expect(sec1['label']).to eq('Section One')
      expect(sec1['collapsible']).to eq(true)
      expect(sec1['collapsed']).to eq(false)
      expect(sec1['items']).to eq([
        { 'type' => 'link', 'label' => 'Section One', 'href' => 'unprivileged/ch1#sec1' },
        { 'type' => 'link', 'label' => 'Sub One',     'href' => 'unprivileged/ch1#sub1' },
        { 'type' => 'link', 'label' => 'Sub Two',     'href' => 'unprivileged/ch1#sub2' }
      ])
    end

    it 'does not include sections deeper than level 3' do
      src = <<~ADOC
        = Doc

        [#ch1]
        == Chapter One

        [#sec1]
        === Section One

        [#sub1]
        ==== Sub One

        [#deep1]
        ===== Deep Section

        Content.
      ADOC
      data = convert_to_sidebar(src, dir: 'unprivileged')
      all_labels = flatten_labels(data)
      expect(all_labels).to include('Chapter One', 'Section One', 'Sub One')
      expect(all_labels).not_to include('Deep Section')
    end

    it 'prefixes sidebar labels with section numbers when :sectnums: is set' do
      src = <<~ADOC
        = Doc
        :sectnums:

        [#ch1]
        == Chapter One

        [#sec1]
        === Section One

        Content.

        [#ch2]
        == Chapter Two

        Content.
      ADOC
      data = convert_to_sidebar(src, dir: 'unprivileged')
      expect(data[0]['label']).to eq('1 Chapter One')
      expect(data[1]['label']).to eq('2 Chapter Two')
      expect(data[0]['items'][0]['label']).to eq('1.1 Section One')
    end

    def flatten_labels(items)
      items.flat_map do |item|
        labels = item['label'] ? [item['label']] : []
        labels + (item['items'] ? flatten_labels(item['items']) : [])
      end
    end
  end
end
