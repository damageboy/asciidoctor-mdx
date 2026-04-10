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
    "#{fence}\n#{escape_code_block(node.source)}\n```\n\n"
  end

  def convert_literal(node)
    lang = node.style == 'literal' ? nil : node.style
    fence = lang ? "```#{lang}" : '```'
    "#{fence}\n#{escape_code_block(node.source)}\n```\n\n"
  end
  def convert_stem(node)
    "```math\n#{node.content}\n```\n\n"
  end
  def table_is_complex?(node)
    [node.rows.head, node.rows.body, node.rows.foot].each do |section|
      section.each do |row|
        row.each do |cell|
          return true if (cell.colspan || 1) > 1 || (cell.rowspan || 1) > 1
        end
      end
    end
    false
  end

  # Renders one separator line (the +---+ lines between rows).
  # r_above: logical row above (-1 for top border)
  # r_below: logical row below (nrows for bottom border)
  # use_equals: true for the header/body separator
  def render_grid_separator(col_widths, grid, r_above, r_below, nrows, use_equals)
    line = '+'
    col_widths.each_with_index do |w, c|
      spans_down = if r_above >= 0 && r_below < nrows
        slot = grid[r_above][c]
        slot &&
          (slot[:cell].rowspan || 1) > 1 &&
          (slot[:origin_row] + (slot[:cell].rowspan || 1) - 1) >= r_below
      else
        false
      end
      fill = spans_down ? ' ' : (use_equals ? '=' : '-')
      line += fill * w + '+'
    end
    line
  end

  # Renders one content line for logical row r.
  def render_grid_content_row(col_widths, grid, r, ncols)
    line = '|'
    c = 0
    while c < ncols
      slot = grid[r][c]
      if slot.nil?
        line += ' ' * col_widths[c] + '|'
        c += 1
      elsif slot[:origin_row] < r
        # Rowspan continuation — blank
        line += ' ' * col_widths[c] + '|'
        c += 1
      else
        # Interior colspan columns are never reached here: the origin branch does
        # c += colspan, which skips past them entirely.
        # Origin cell for this row — emit content
        cell = slot[:cell]
        colspan = cell.colspan || 1
        # Combined width: sum of column widths + (colspan-1) for the | chars between them
        combined_width = col_widths[c...(c + colspan)].sum + (colspan - 1)
        text = table_cell_text(cell)
        # One space padding on left, left-align text, fill to combined_width - 1
        line += ' ' + text.ljust(combined_width - 1) + '|'
        c += colspan
      end
    end
    line
  end

  def convert_table_gridtable(node)
    ncols            = node.columns.size
    grid, nrows, nhead = build_grid(node)
    col_widths       = compute_col_widths(grid, ncols, nrows)
    lines            = []

    # Top border
    lines << render_grid_separator(col_widths, grid, -1, 0, nrows, false)

    nrows.times do |r|
      lines << render_grid_content_row(col_widths, grid, r, ncols)
      use_equals = nhead > 0 && r == nhead - 1
      lines << render_grid_separator(col_widths, grid, r, r + 1, nrows, use_equals)
    end

    lines.join("\n") + "\n\n"
  end

  def build_grid(node)
    ncols = node.columns.size
    nhead = node.rows.head.size
    all_rows = node.rows.head + node.rows.body + node.rows.foot
    nrows = all_rows.size
    grid = Array.new(nrows) { Array.new(ncols) }
    # pending[col] = { cell:, origin_row:, origin_col:, rows_left: }
    pending = {}

    all_rows.each_with_index do |row, row_idx|
      cell_queue = row.dup
      col = 0
      while col < ncols
        if pending[col]
          entry = pending[col]
          colspan = entry[:cell].colspan || 1
          colspan.times { |col_offset| grid[row_idx][col + col_offset] = { cell: entry[:cell], origin_row: entry[:origin_row], origin_col: entry[:origin_col] } }
          entry[:rows_left] -= 1
          pending.delete(col) if entry[:rows_left] == 0
          col += colspan
        else
          cell = cell_queue.shift
          break unless cell
          colspan = cell.colspan || 1
          rowspan = cell.rowspan || 1
          colspan.times { |col_offset| grid[row_idx][col + col_offset] = { cell: cell, origin_row: row_idx, origin_col: col } }
          pending[col] = { cell: cell, origin_row: row_idx, origin_col: col, rows_left: rowspan - 1 } if rowspan > 1
          col += colspan
        end
      end
    end

    [grid, nrows, nhead]
  end

  def compute_col_widths(grid, ncols, nrows)
    widths = Array.new(ncols, 3)

    # Pass 1: single-spanning cells set the baseline width for each column.
    nrows.times do |r|
      ncols.times do |c|
        slot = grid[r][c]
        next unless slot
        next unless slot[:origin_row] == r && slot[:origin_col] == c
        next unless (slot[:cell].colspan || 1) == 1
        text = table_cell_text(slot[:cell])
        widths[c] = [widths[c], text.length + 2].max
      end
    end

    # Pass 2: multi-spanning cells — if the content doesn't fit within the
    # combined width of the spanned columns, distribute the deficit evenly.
    # Process shorter spans first so their widths feed into wider spans.
    spanning_cells = []
    nrows.times do |r|
      ncols.times do |c|
        slot = grid[r][c]
        next unless slot && slot[:origin_row] == r && slot[:origin_col] == c
        colspan = slot[:cell].colspan || 1
        next unless colspan > 1
        spanning_cells << [colspan, c, slot[:cell]]
      end
    end
    spanning_cells.sort_by { |colspan, _, _| colspan }.each do |colspan, c, cell|
      text = table_cell_text(cell)
      needed = text.length + 2
      current = widths[c...(c + colspan)].sum + (colspan - 1)
      next unless needed > current
      deficit = needed - current
      extra, remainder = deficit.divmod(colspan)
      colspan.times do |i|
        widths[c + i] += extra
        widths[c + i] += 1 if i < remainder
      end
    end

    widths
  end

  def convert_table(node)
    return convert_table_gridtable(node) if table_is_complex?(node)

    rows = []
    if node.rows.head.any?
      header_cells = node.rows.head.first.map { |cell| table_cell_text(cell).gsub('|', '\|') }
      rows << "| #{header_cells.join(' | ')} |"
      rows << "| #{header_cells.map { '---' }.join(' | ')} |"
    end
    node.rows.body.each do |row|
      cells = row.map { |cell| table_cell_text(cell).gsub('|', '\\|') }
      rows << "| #{cells.join(' | ')} |"
    end
    node.rows.foot.each do |row|
      cells = row.map { |cell| table_cell_text(cell).gsub('|', '\\|') }
      rows << "| #{cells.join(' | ')} |"
    end
    "#{rows.join("\n")}\n\n"
  end

  # Convert a table cell to a plain string suitable for a GFM table cell.
  # For asciidoc-style cells (which may contain nested tables or blocks),
  # convert the inner document blocks and flatten to a single line.
  def table_cell_text(cell)
    if cell.style == :asciidoc && cell.inner_document
      # Convert inner blocks through our converter and collapse to one line
      inner = cell.inner_document.blocks.map { |b| convert(b) }.join(' ').strip
      inner.gsub(/\n+/, ' ').gsub(/\s{2,}/, ' ')
    else
      # Collapse internal newlines (e.g. from AsciiDoc + continuation lines)
      # to single spaces so grid-table rows stay on one line.
      escaped = escape_inline_content(cell.text.strip)
      escaped.gsub(/\n+/, ' ').gsub(/  +/, ' ')
    end
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
  def convert_embedded(node)       = node.content

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
    # Use negative lookbehind to avoid double-escaping already-escaped braces.
    content = node.content
                  .gsub('&amp;', '&')
                  .gsub('&gt;', '>')
                  .gsub('&lt;', '\<')
                  .gsub(/(?<!\\)\{/, '\{')
                  .gsub(/(?<!\\)\}/, '\}')
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

  # MDX v3 parses < as a JSX tag open even inside fenced code blocks.
  # Escape it as \< so the MDX parser accepts it; JS template literals
  # treat \< as a plain < at runtime, so the rendered code is correct.
  def escape_code_block(str)
    str.to_s.gsub('<', '\<')
  end

  def escape_inline_content(str)
    str.to_s
       .gsub('&lt;', '\<')
       .gsub('&gt;', '\>')
       .gsub(/(?<!\\)\{/, '\{')
       .gsub(/(?<!\\)\}/, '\}')
  end

  def escape_mdx(str)
    str.to_s
       .gsub('<', '\<')              # bare < is a JSX tag open
       .gsub(/(?<!\\)\{/, '\{')     # bare { is a JSX expression (not already escaped)
       .gsub(/(?<!\\)\}/, '\}')     # bare } closes a JSX expression (not already escaped)
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
