# frozen_string_literal: true

class MdxConverter < Asciidoctor::Converter::Base
  register_for 'mdx'

  def convert_document(doc)
    ''
  end
end
