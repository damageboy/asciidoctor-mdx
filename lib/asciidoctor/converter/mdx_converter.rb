# frozen_string_literal: true

require 'json'
require 'yaml'
require 'pathname'

class MdxConverter < Asciidoctor::Converter::Base
  register_for 'mdx'

  def convert_document(doc)
    @xref_map      = {}   # anchor_id (String) -> chapter_slug (String)
    @chapter_slugs = {}   # section object_id -> slug (String)
    @current_chapter = nil
    @sidebar_dir   = doc.attr('mdx-sidebar-dir', nil, false)
    @sidebar_tree  = []   # array of sidebar node hashes, one per top-level section

    # Pass 1: collect all anchor IDs and build sidebar tree
    doc.sections.each do |section|
      slug = section_slug(section)
      @chapter_slugs[section.object_id] = slug
      collect_anchors(section, slug)
      @sidebar_tree << collect_sidebar_node(section, slug) if @sidebar_dir
    end

    # Replay attribute entries from the preamble and other pre-section blocks.
    # Asciidoctor stores body attribute-entry lines (e.g. :check: ✓ from the
    # included symbols.adoc) in the attributes of the block immediately after
    # them. Those entries are played back via Document#playback_attributes when
    # a block's #convert is called. Because we skip the preamble in our
    # two-pass rendering, those attributes would otherwise remain unresolved.
    # Converting the pre-section blocks and discarding the output replays the
    # entries as a side effect, making {check}, {ge}, {le}, etc. available.
    doc.blocks.each do |block|
      break if block.context == :section
      block.convert
    end

    # Pass 2: emit one .mdx file per top-level section
    outdir = doc.attr('mdxdir') || doc.options[:to_dir] || doc.attr('outdir', '.')
    doc.sections.each_with_index do |section, idx|
      slug = @chapter_slugs[section.object_id]
      @current_chapter = slug
      content = render_chapter(section, idx + 1)
      File.write(File.join(outdir, "#{slug}.mdx"), content)
    end

    # Write sidebar.json when mdx-sidebar-dir is set
    if @sidebar_dir
      sidebar_data = @sidebar_tree.map { |node| build_sidebar_item(node) }
      File.write(File.join(outdir, 'sidebar.json'), JSON.pretty_generate(sidebar_data))
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

  def collect_sidebar_node(section, chapter_slug)
    return nil if section.level > 3  # level 1=chapter(==), 2=section(===), 3=subsection(====); skip level 4+
    children = section.sections.filter_map { |sub| collect_sidebar_node(sub, chapter_slug) }
    { title: section.title, anchor_id: section.id && sanitize_anchor_id(section.id),
      chapter_slug: chapter_slug, level: section.level, children: children }
  end

  def build_sidebar_item(node)
    title = node[:title]
    slug  = node[:chapter_slug]
    id    = "#{@sidebar_dir}/#{slug}"

    if node[:level] == 1
      if node[:children].empty?
        { 'type' => 'doc', 'id' => id, 'label' => title }
      else
        { 'type' => 'category', 'label' => title,
          'link' => { 'type' => 'doc', 'id' => id },
          'collapsible' => true, 'collapsed' => false,
          'items' => node[:children].map { |c| build_sidebar_item(c) } }
      end
    else
      anchor = node[:anchor_id]
      href   = (anchor && !anchor.empty?) ? "#{@sidebar_dir}/#{slug}##{anchor}" : "#{@sidebar_dir}/#{slug}"
      if node[:children].empty?
        { 'type' => 'link', 'label' => title, 'href' => href }
      else
        { 'type' => 'category', 'label' => title,
          'collapsible' => true, 'collapsed' => false,
          'items' => [{ 'type' => 'link', 'label' => title, 'href' => href }] +
                     node[:children].map { |c| build_sidebar_item(c) } }
      end
    end
  end

  def render_chapter(section, position)
    # Replay any attribute entries stored directly on this section node.
    # This handles the case where body attribute entries (e.g. from an include
    # immediately before the first section with no preamble text) are attached
    # to the section block rather than to a preamble sub-block.
    section.document.playback_attributes(section.attributes)
    doc = section.document
    slug = @chapter_slugs[section.object_id]
    title = section.title
    frontmatter_lines = [
      '---',
      "title: #{title.to_yaml.strip.sub(/\A--- /, '')}",
      "sidebar_label: #{title.to_yaml.strip.sub(/\A--- /, '')}",
      "sidebar_position: #{position}",
      "id: #{slug}",
    ]
    edit_url = build_custom_edit_url(section, doc)
    frontmatter_lines << "custom_edit_url: #{edit_url}" if edit_url
    frontmatter_lines += ['---', '']
    frontmatter = frontmatter_lines.join("\n")
    "#{frontmatter}\n#{section.content}\n"
  end

  # Builds the custom_edit_url front matter value for a chapter section.
  #
  # Requires the document attribute +github-edit-url-base+ to be set (e.g.
  # https://github.com/riscv/riscv-isa-manual/blob/main).  An optional
  # +github-local-root+ attribute names the local directory that corresponds
  # to the root of the GitHub repository; it defaults to the parent of
  # +docdir+ (one level above the directory containing the main .adoc file).
  def build_custom_edit_url(section, doc)
    base_url = doc.attr('github-edit-url-base', nil, false)
    return nil unless base_url

    source_file = section.source_location&.file
    return nil unless source_file

    # Local root: explicit attribute, or parent of docdir (i.e. repo root
    # when source files live in a subdirectory such as src/).
    local_root = doc.attr('github-local-root', nil, false) ||
                 File.dirname(doc.attr('docdir', '.'))

    rel_path = Pathname.new(File.expand_path(source_file))
                       .relative_path_from(Pathname.new(File.expand_path(local_root)))
                       .to_s
    "#{base_url.chomp('/')}/#{rel_path}"
  rescue ArgumentError
    nil
  end

  def convert_section(node)
    hashes    = '#' * node.level
    title     = escape_mdx(node.title)
    id_suffix = node.id ? " {##{sanitize_anchor_id(node.id)}}" : ''
    "#{hashes} #{title}#{id_suffix}\n\n#{node.content}"
  end
  def convert_listing(node)
    lang = node.attr('language', nil, false)
    lang ||= node.style if node.style && !%w[source listing].include?(node.style)
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
  #
  # For cells that span multiple rows (rowspan > 1):
  #   - colspan == 1: the column shows spaces with + at both ends (standard rowspan)
  #   - colspan >  1: the spanned columns are merged into one block with spaces and
  #     a | at the right boundary (not +). This follows the @adobe/remark-gridtables
  #     convention where col spans are indicated by missing | delimiters.
  def render_grid_separator(col_widths, grid, r_above, r_below, nrows, use_equals)
    ncols = col_widths.size
    line = '+'
    c = 0
    while c < ncols
      slot = (r_above >= 0 && r_below < nrows) ? grid[r_above][c] : nil
      spans_down = slot &&
        (slot[:cell].rowspan || 1) > 1 &&
        slot[:origin_row] + (slot[:cell].rowspan || 1) - 1 >= r_below

      if spans_down && slot[:origin_col] == c && (slot[:cell].colspan || 1) > 1
        # Multi-column span: merge all spanned columns into one space block, | at right
        colspan = slot[:cell].colspan || 1
        combined_w = col_widths[c...(c + colspan)].sum + (colspan - 1)
        line += ' ' * combined_w + '|'
        c += colspan
      elsif spans_down && slot[:origin_col] == c
        # Single-column span: spaces with + at right boundary
        line += ' ' * col_widths[c] + '+'
        c += 1
      else
        # Non-spanning column (or interior of a span — unreachable via jumping)
        fill = use_equals ? '=' : '-'
        line += fill * col_widths[c] + '+'
        c += 1
      end
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
      elsif slot[:origin_row] < r && slot[:origin_col] == c
        # Rowspan continuation at the origin column of the span.
        # For colspan > 1, merge all spanned columns into one space block.
        colspan = slot[:cell].colspan || 1
        combined_w = colspan > 1 ? col_widths[c...(c + colspan)].sum + (colspan - 1) : col_widths[c]
        line += ' ' * combined_w + '|'
        c += colspan
      elsif slot[:origin_row] < r
        # Interior column of a multi-colspan continuation — skip (origin branch jumped here)
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
    path = build_mdx_image_path(node)
    "![#{alt}](#{path})\n\n"
  end

  # Returns the image URL to embed in MDX output.
  #
  # When the +mdx-images-url+ document attribute is set, images are rewritten
  # to site-root-relative URLs suitable for Docusaurus static serving:
  #
  #   mdx-images-url   Base URL under which images are served (e.g. /img/riscv-isa/)
  #   mdx-images-root  Local filesystem root that corresponds to mdx-images-url.
  #                    Defaults to docdir joined with imagesdir.
  #
  # Without +mdx-images-url+, falls back to the standard Asciidoctor image_uri
  # (which respects the :imagesdir: document attribute).
  def build_mdx_image_path(node)
    target      = node.attr('target')
    images_url  = node.document.attr('mdx-images-url', nil, false)
    return node.image_uri(target) unless images_url

    doc       = node.document
    docdir    = doc.attr('docdir', '.', false).to_s
    imagesdir = doc.attr('imagesdir', '', false).to_s

    # Resolve the absolute filesystem path of the image.
    abs_image = File.expand_path(File.join(imagesdir, target), docdir)

    # Make it relative to the images root (local counterpart of mdx-images-url).
    images_root = doc.attr('mdx-images-root', nil, false)
    images_root ||= File.expand_path(imagesdir, docdir)
    rel_path = Pathname.new(abs_image)
                       .relative_path_from(Pathname.new(File.expand_path(images_root)))
                       .to_s

    "#{images_url.chomp('/')}/#{rel_path}"
  rescue ArgumentError
    node.image_uri(target)
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
    hashes    = '#' * node.level
    id_suffix = node.id ? " {##{sanitize_anchor_id(node.id)}}" : ''
    "#{hashes} #{escape_mdx(node.title)}#{id_suffix}\n\n"
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
    else text
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

  def sanitize_anchor_id(id)
    id.to_s.gsub(':', '-').gsub(/-+/, '-').gsub(/^-+|-+$/, '')
  end

  def resolve_xref(node)
    target  = node.attr('refid') || node.target.to_s.sub(/^#/, '')
    text    = presence(node.text) || target
    chapter = @xref_map&.fetch(target, nil)
    anchor  = sanitize_anchor_id(target)
    if chapter.nil? || chapter == @current_chapter
      "[#{escape_mdx(text)}](##{anchor})"
    elsif chapter == target
      # target IS the chapter (top-level section); no anchor fragment needed
      "[#{escape_mdx(text)}](./#{chapter})"
    else
      "[#{escape_mdx(text)}](./#{chapter}##{anchor})"
    end
  end
end
