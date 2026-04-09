# frozen_string_literal: true

require 'yaml'

class MdxConverter < Asciidoctor::Converter::Base
  register_for 'mdx'

  def convert_document(doc)
    @xref_map = {}        # anchor_id (String) -> chapter_slug (String)
    @chapter_slugs = {}   # section object_id -> slug (String)
    @current_chapter = nil

    # Pass 1: collect all anchor IDs and map them to their chapter slug
    doc.sections.each do |section|
      slug = section_slug(section)
      @chapter_slugs[section.object_id] = slug
      collect_anchors(section, slug)
    end

    # Pass 2: emit one .mdx file per top-level section
    outdir = doc.attr('mdxdir') || doc.options[:to_dir] || doc.attr('outdir', '.')
    doc.sections.each_with_index do |section, idx|
      slug = @chapter_slugs[section.object_id]
      @current_chapter = slug
      content = render_chapter(section, idx + 1)
      File.write(File.join(outdir, "#{slug}.mdx"), content)
    end

    '' # Asciidoctor expects a string return; multi-file output is a side effect
  end

  private

  def section_slug(section)
    explicit_id = section.attributes['id']
    base = if explicit_id && !explicit_id.empty?
      explicit_id
    else
      section.title.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-+|-+$/, '')
    end
    # Sanitize for use as a filename and URL slug: replace non-alphanumeric/hyphen chars
    base.gsub(':', '-').gsub(/[^a-z0-9\-_]/, '-').gsub(/-+/, '-').gsub(/^-+|-+$/, '')
  end

  def collect_anchors(node, chapter_slug)
    return unless node.respond_to?(:id)
    @xref_map[node.id] = chapter_slug if node.id && !node.id.empty?
    return unless node.respond_to?(:blocks)
    node.blocks.each { |b| collect_anchors(b, chapter_slug) }
  end

  def render_chapter(section, position)
    slug = @chapter_slugs[section.object_id]
    title = section.title
    frontmatter = [
      '---',
      "title: #{title.to_yaml.strip.sub(/\A--- /, '')}",
      "sidebar_label: #{title.to_yaml.strip.sub(/\A--- /, '')}",
      "sidebar_position: #{position}",
      "id: #{slug}",
      '---',
      ''
    ].join("\n")
    "#{frontmatter}\n#{section.content}\n"
  end

  def convert_section(node)
    hashes     = '#' * node.level
    title      = escape_mdx(node.title)
    id_comment = node.id ? " {/* ##{node.id} */}" : ''
    "#{hashes} #{title}#{id_comment}\n\n#{node.content}"
  end
  def convert_listing(node)
    lang = node.attr('language', nil, false)
    fence = lang ? "```#{lang}" : '```'
    "#{fence}\n#{node.source}\n```\n\n"
  end

  def convert_literal(node)
    "```\n#{node.source}\n```\n\n"
  end
  def convert_stem(node)
    "```math\n#{node.content}\n```\n\n"
  end
  def convert_table(node)
    rows = []

    if node.rows.head.any?
      header_cells = node.rows.head.first.map { |cell| escape_inline_content(cell.text.strip).gsub('|', '\|') }
      rows << "| #{header_cells.join(' | ')} |"
      rows << "| #{header_cells.map { '---' }.join(' | ')} |"
    end

    node.rows.body.each do |row|
      cells = row.map { |cell| escape_inline_content(cell.text.strip).gsub('|', '\\|') }
      rows << "| #{cells.join(' | ')} |"
    end

    node.rows.foot.each do |row|
      cells = row.map { |cell| escape_inline_content(cell.text.strip).gsub('|', '\\|') }
      rows << "| #{cells.join(' | ')} |"
    end

    "#{rows.join("\n")}\n\n"
  end

  def convert_image(node)
    alt  = escape_mdx(node.attr('alt', node.attr('target'), false).to_s)
    path = node.image_uri(node.attr('target'))
    "![#{alt}](#{path})\n\n"
  end
  ADMONITION_TYPES = {
    'NOTE'      => 'note',
    'TIP'       => 'tip',
    'IMPORTANT' => 'info',
    'WARNING'   => 'warning',
    'CAUTION'   => 'danger'
  }.freeze

  def convert_admonition(node)
    type    = ADMONITION_TYPES.fetch(node.attr('name', nil, false).to_s.upcase, 'note')
    content = node.blocks.empty? ? escape_inline_content(node.content) : node.content
    ":::#{type}\n\n#{content}\n\n:::\n\n"
  end
  def list_depth(node)
    depth = 0
    p = node.parent
    while p
      depth += 1 if p.respond_to?(:context) && p.context == :list_item
      p = p.respond_to?(:parent) ? p.parent : nil
    end
    depth
  end

  def convert_ulist(node)
    indent = '  ' * list_depth(node)
    items  = node.items.map { |item| "#{indent}- #{escape_inline_content(item.text)}\n#{item.content}" }
    "#{items.join}\n"
  end

  def convert_olist(node)
    items = node.items.each_with_index.map do |item, idx|
      "#{idx + 1}. #{escape_inline_content(item.text)}\n#{item.content}"
    end
    "#{items.join}\n"
  end

  def convert_dlist(node)
    items = node.items.map do |terms, dd|
      term_text = Array(terms).map { |t| escape_inline_content(t.text) }.join(', ')
      desc = dd ? dd.text.to_s : ''
      "**#{term_text}**\n#{escape_inline_content(desc)}\n"
    end
    "#{items.join("\n")}\n"
  end
  def convert_open(node)
    "#{node.content}\n"
  end

  def convert_example(node)
    ":::note\n\n#{node.content}\n\n:::\n\n"
  end

  def convert_quote(node)
    attribution = node.attr('attribution', nil, false)
    lines = node.content.lines.map { |l| "> #{l.chomp}\n" }
    result = lines.join
    result += "\n> — #{escape_mdx(attribution)}\n" if attribution
    "#{result}\n"
  end

  def convert_verse(node)
    convert_quote(node)
  end

  def convert_sidebar(node)
    ":::info\n\n#{node.content}\n\n:::\n\n"
  end

  def convert_thematic_break(node) = "---\n\n"
  def convert_toc(node)            = ''

  def convert_pass(node)
    "#{node.content}\n\n"
  end

  def convert_preamble(node)
    "#{node.content}\n\n"
  end

  def convert_floating_title(node)
    hashes     = '#' * node.level
    id_comment = node.id ? " {/* ##{node.id} */}" : ''
    "#{hashes} #{escape_mdx(node.title)}#{id_comment}\n\n"
  end
  def convert_page_break(node)      = ''
  def convert_inline_image(node)   = ''
  def convert_inline_break(node)   = "  \n"
  def convert_inline_indexterm(node) = ''
  def convert_inline_callout(node)   = ''
  def convert_inline_footnote(node)  = ''

  def convert_paragraph(node)
    # node.content assembles inline-converted output; HTML entities come from
    # Asciidoctor encoding bare < as &lt;. Unescape those into \< for MDX.
    # Also escape bare { which Asciidoctor leaves as-is for unresolved attributes.
    content = node.content
                  .gsub('&amp;', '&')
                  .gsub('&gt;', '>')
                  .gsub('&lt;', '\<')
                  .gsub('{', '\{')
                  .gsub('}', '\}')
    "#{content}\n\n"
  end

  def convert_inline_quoted(node)
    text = node.text.to_s
    case node.type
    when :strong      then "**#{text}**"
    when :emphasis    then "_#{text}_"
    when :monospaced  then "`#{text}`"
    when :superscript then "<sup>#{text}</sup>"
    when :subscript   then "<sub>#{text}</sub>"
    when :latexmath   then "$#{text}$"
    when :asciimath   then "$#{text}$"
    when :mark        then "**#{text}**"
    else escape_mdx(text)
    end
  end

  def convert_inline_anchor(node)
    case node.type
    when :link
      text = presence(node.text) || node.target
      "[#{escape_mdx(text)}](#{node.target})"
    when :xref
      resolve_xref(node)
    when :ref
      ''
    when :bibref
      escape_mdx(node.text.to_s)
    else
      escape_mdx(node.text.to_s)
    end
  end

  def escape_inline_content(str)
    str.to_s
       .gsub('&lt;', '\<')
       .gsub('&gt;', '\>')
       .gsub('&amp;', '&')
       .gsub('{', '\{')
       .gsub('}', '\}')
  end

  def escape_mdx(str)
    str.to_s
       .gsub('\\', '\\\\\\\\')  # backslash first
       .gsub('<', '\<')          # bare < is a JSX tag open
       .gsub('{', '\{')          # bare { is a JSX expression
       .gsub('}', '\}')          # bare } closes JSX expression
  end

  def presence(str)
    str && !str.to_s.strip.empty? ? str.to_s : nil
  end

  def resolve_xref(node)
    target  = node.attr('refid') || node.target.to_s.sub(/^#/, '')
    text    = presence(node.text) || target
    chapter = @xref_map&.fetch(target, nil)
    if chapter.nil? || chapter == @current_chapter
      "[#{escape_mdx(text)}](##{target})"
    elsif chapter == target
      # target IS the chapter (top-level section); no anchor fragment needed
      "[#{escape_mdx(text)}](./#{chapter})"
    else
      "[#{escape_mdx(text)}](./#{chapter}##{target})"
    end
  end
end
