# frozen_string_literal: true

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
    # Use explicit id if one was set in the source (auto-generated ids are not in attributes)
    explicit_id = section.attributes['id']
    return explicit_id if explicit_id && !explicit_id.empty?

    section.title.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-+|-+$/, '')
  end

  def collect_anchors(node, chapter_slug)
    @xref_map[node.id] = chapter_slug if node.id && !node.id.empty?
    return unless node.respond_to?(:blocks)
    node.blocks.each { |b| collect_anchors(b, chapter_slug) }
  end

  def render_chapter(section, position)
    slug = @chapter_slugs[section.object_id]
    frontmatter = <<~YAML
      ---
      title: #{section.title.inspect}
      sidebar_label: #{section.title.inspect}
      sidebar_position: #{position}
      id: #{slug}
      ---
    YAML
    "#{frontmatter}\n#{section.content}\n"
  end

  # Stub — remaining convert_* methods return empty string until implemented
  def convert_section(node)        = ''
  def convert_paragraph(node)      = ''
  def convert_listing(node)        = ''
  def convert_literal(node)        = ''
  def convert_stem(node)           = ''
  def convert_table(node)          = ''
  def convert_image(node)          = ''
  def convert_admonition(node)     = ''
  def convert_ulist(node)          = ''
  def convert_olist(node)          = ''
  def convert_dlist(node)          = ''
  def convert_example(node)        = ''
  def convert_quote(node)          = ''
  def convert_verse(node)          = ''
  def convert_sidebar(node)        = ''
  def convert_pass(node)           = ''
  def convert_preamble(node)       = ''
  def convert_floating_title(node) = ''
  def convert_inline_quoted(node)  = node.text.to_s
  def convert_inline_anchor(node)  = node.text.to_s
  def convert_inline_image(node)   = ''
  def convert_inline_break(node)   = "\n"
  def convert_inline_indexterm(node) = ''
  def convert_inline_callout(node)   = ''
  def convert_inline_footnote(node)  = ''
end
