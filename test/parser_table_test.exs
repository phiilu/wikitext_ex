defmodule WikitextEx.TableTest do
  use ExUnit.Case, async: true

  alias WikitextEx.{Parser, AST}
  alias WikitextEx.WikitextFixtures

  describe "table cell HTML content parsing" do
    test "parses HTML tags within table cell content into proper AST nodes" do
      # This is the issue we found - HTML like "64<br>2 Secret cards" should be parsed
      # into separate text nodes and HTML tag nodes, not treated as raw text
      wikitext = """
      {|
      | 64<br>2 Secret cards
      | 172 cards<br><small>14 Secret cards</small>
      |}
      """

      {:ok, asts, _, _, _, _} = Parser.parse(wikitext)

      # Find the table
      [%AST{type: :table, children: table_rows}] =
        Enum.filter(asts, fn ast -> ast.type == :table end)

      # Should have data row
      [data_row] = table_rows
      assert %AST{type: :table_row, children: data_cells} = data_row

      # First cell should parse "64<br>2 Secret cards" into structured AST
      first_cell = Enum.at(data_cells, 0)

      assert %AST{
               type: :table_cell,
               value: %AST.TableCell{type: :data},
               children: [
                 %AST{type: :text, value: %AST.Text{content: "64"}},
                 %AST{type: :html_tag, value: %AST.HtmlTag{tag: "br", attributes: %{}}},
                 %AST{type: :text, value: %AST.Text{content: "2 Secret cards"}}
               ]
             } = first_cell

      # Second cell should parse "172 cards<br><small>14 Secret cards</small>" into structured AST
      # Note: The parser treats <br> as a container tag, so the structure is:
      # - Text: "172 cards"  
      # - HTML tag: br (containing small tag and text as children)
      second_cell = Enum.at(data_cells, 1)

      assert %AST{
               type: :table_cell,
               value: %AST.TableCell{type: :data},
               children: [
                 %AST{type: :text, value: %AST.Text{content: "172 cards"}},
                 %AST{
                   type: :html_tag,
                   value: %AST.HtmlTag{tag: "br", attributes: %{}},
                   children: [
                     %AST{
                       type: :html_tag,
                       value: %AST.HtmlTag{tag: "small", attributes: %{}},
                       children: []
                     },
                     %AST{type: :text, value: %AST.Text{content: "14 Secret cards"}}
                   ]
                 }
               ]
             } = second_cell
    end
  end

  describe "table cell attribute parsing" do
    test "separates header cell attributes from content when attributes contain templates" do
      # Regression test for POK-238: Parser was treating template-containing attributes as cell content
      # This is the actual problematic case from Bulbapedia - templates in attributes
      wikitext = """
      {|
      ! style="background-color:#EEE; width:150px" {{roundytr|5px}}" | Release date
      |}
      """

      {:ok, asts, _, _, _, _} = Parser.parse(wikitext)

      # Find the table
      [%AST{type: :table, children: table_rows}] =
        Enum.filter(asts, fn ast -> ast.type == :table end)

      # Should have header row
      [header_row] = table_rows
      assert %AST{type: :table_row, children: header_cells} = header_row

      # Cell should have content "Release date", not the style attributes
      [cell] = header_cells

      assert %AST{
               type: :table_cell,
               value: %AST.TableCell{type: :header},
               children: [%AST{type: :text, value: %AST.Text{content: "Release date"}}]
             } = cell
    end

    test "separates header cell attributes from content with simple attributes" do
      wikitext = """
      {|
      ! style="background-color:#EEE; width:50px;" | Set no.
      ! Symbol
      ! style="background-color:#EEE; width:150px;" | Release date
      ! style="background-color:#EEE; width:100px;" | {{tt|Set abb.|Set abbreviation}}
      |}
      """

      {:ok, asts, _, _, _, _} = Parser.parse(wikitext)

      # Find the table
      [%AST{type: :table, children: table_rows}] =
        Enum.filter(asts, fn ast -> ast.type == :table end)

      # Should have header row
      [header_row] = table_rows
      assert %AST{type: :table_row, children: header_cells} = header_row

      # First cell should have content "Set no.", not "style=..."
      first_cell = Enum.at(header_cells, 0)

      assert %AST{
               type: :table_cell,
               value: %AST.TableCell{type: :header},
               children: [%AST{type: :text, value: %AST.Text{content: "Set no."}}]
             } = first_cell

      # Second cell should have content "Symbol" (no attributes)
      second_cell = Enum.at(header_cells, 1)

      assert %AST{
               type: :table_cell,
               value: %AST.TableCell{type: :header},
               children: [%AST{type: :text, value: %AST.Text{content: "Symbol"}}]
             } = second_cell

      # Third cell should have content "Release date"
      third_cell = Enum.at(header_cells, 2)

      assert %AST{
               type: :table_cell,
               value: %AST.TableCell{type: :header},
               children: [%AST{type: :text, value: %AST.Text{content: "Release date"}}]
             } = third_cell

      # Fourth cell should contain the template
      fourth_cell = Enum.at(header_cells, 3)

      assert %AST{
               type: :table_cell,
               value: %AST.TableCell{type: :header},
               children: [%AST{type: :template, value: %AST.Template{name: "tt"}}]
             } = fourth_cell
    end

    test "separates data cell attributes from content" do
      wikitext = """
      {|
      | style="text-align:center;" | 1
      | Basic
      | style="width:100px;" | October 9, 1996
      |}
      """

      {:ok, asts, _, _, _, _} = Parser.parse(wikitext)

      # Find the table
      [%AST{type: :table, children: table_rows}] =
        Enum.filter(asts, fn ast -> ast.type == :table end)

      # Should have data row
      [data_row] = table_rows
      assert %AST{type: :table_row, children: data_cells} = data_row

      # First cell should have content "1", not "style=..."
      first_cell = Enum.at(data_cells, 0)

      assert %AST{
               type: :table_cell,
               value: %AST.TableCell{type: :data},
               children: [%AST{type: :text, value: %AST.Text{content: "1"}}]
             } = first_cell

      # Second cell should have content "Basic" (no attributes)
      second_cell = Enum.at(data_cells, 1)

      assert %AST{
               type: :table_cell,
               value: %AST.TableCell{type: :data},
               children: [%AST{type: :text, value: %AST.Text{content: "Basic"}}]
             } = second_cell

      # Third cell should have content "October 9, 1996"
      third_cell = Enum.at(data_cells, 2)

      assert %AST{
               type: :table_cell,
               value: %AST.TableCell{type: :data},
               children: [%AST{type: :text, value: %AST.Text{content: "October 9, 1996"}}]
             } = third_cell
    end
  end

  describe "wikitext table parsing" do
    test "parses table structure with proper AST hierarchy" do
      wikitext = WikitextFixtures.load_fixture("products_table")

      {:ok, asts, _, _, _, _} = Parser.parse(wikitext)

      # Should parse as a table with proper structure
      table_asts = Enum.filter(asts, fn ast -> ast.type == :table end)
      assert [%AST{type: :table, value: %AST.Table{}, children: table_rows}] = table_asts

      # Should have header row + 3 data rows
      assert length(table_rows) == 4

      # Check header row structure
      [header_row | data_rows] = table_rows
      assert %AST{type: :table_row, children: header_cells} = header_row
      # 8 columns in our fixture
      assert length(header_cells) == 8

      # Header cells should be type :header
      for cell <- header_cells do
        assert %AST{type: :table_cell, value: %AST.TableCell{type: :header}} = cell
      end

      # Check first data row
      [first_data_row | _] = data_rows
      assert %AST{type: :table_row, children: data_cells} = first_data_row
      assert length(data_cells) == 8

      # Data cells should be type :data
      for cell <- data_cells do
        assert %AST{type: :table_cell, value: %AST.TableCell{type: :data}} = cell
      end
    end

    test "extracts set data from specific table columns" do
      wikitext = WikitextFixtures.load_fixture("products_table")

      {:ok, asts, _, _, _, _} = Parser.parse(wikitext)

      # Find the table
      [%AST{type: :table, children: table_rows}] =
        Enum.filter(asts, fn ast -> ast.type == :table end)

      # Skip header row, check data rows
      [_header_row | data_rows] = table_rows

      # Check first data row (Base Set)
      [first_row | _] = data_rows
      assert %AST{type: :table_row, children: cells} = first_row

      # 1st cell should contain set number "1"
      first_cell = Enum.at(cells, 0)

      assert %AST{
               type: :table_cell,
               children: [%AST{type: :text, value: %AST.Text{content: "1"}}]
             } = first_cell

      # 4th cell should contain {{Product|Starter Collection}} template
      fourth_cell = Enum.at(cells, 3)

      assert %AST{type: :table_cell, children: [%AST{type: :template, value: product_template}]} =
               fourth_cell

      assert %AST.Template{name: "Product", args: args} = product_template

      # Extract product name from template
      product_name = extract_first_positional_arg(args)
      assert product_name == "Starter Collection"

      # Check second data row (Jungle)
      second_row = Enum.at(data_rows, 1)
      assert %AST{type: :table_row, children: cells} = second_row

      # 1st cell should contain "2"
      first_cell = Enum.at(cells, 0)

      assert %AST{
               type: :table_cell,
               children: [%AST{type: :text, value: %AST.Text{content: "2"}}]
             } = first_cell

      # 4th cell should contain {{Product|Garden Series}}
      fourth_cell = Enum.at(cells, 3)

      assert %AST{type: :table_cell, children: [%AST{type: :template, value: product_template}]} =
               fourth_cell

      assert %AST.Template{name: "Product", args: args} = product_template
      product_name = extract_first_positional_arg(args)
      assert product_name == "Garden Series"
    end

    test "demonstrates bulk scraper AST walking pattern" do
      wikitext = WikitextFixtures.load_fixture("products_table")

      {:ok, asts, _, _, _, _} = Parser.parse(wikitext)

      # This is how the bulk scraper would walk the AST
      product_names =
        for ast <- asts,
            ast.type == :table,
            row <- ast.children,
            row.type == :table_row,
            cell <- row.children,
            cell.type == :table_cell,
            cell_ast <- cell.children,
            cell_ast.type == :template,
            cell_ast.value.name == "Product" do
          extract_first_positional_arg(cell_ast.value.args)
        end

      # Should extract all product names through AST walking
      assert "Starter Collection" in product_names
      assert "Garden Series" in product_names
      assert "Classic Collection" in product_names
      assert length(product_names) == 3
    end

    test "parses real production table data" do
      # Test with actual table content from production that was causing parsing issues
      wikitext = WikitextFixtures.load_fixture("collections_table")

      {:ok, asts, _rest, _context, _position, _offset} = Parser.parse(wikitext)

      # Should find at least one table in the real data
      tables = Enum.filter(asts, &(&1.type == :table))
      assert length(tables) >= 1

      # Should be able to extract Collection names from the real table
      collection_names =
        for ast <- asts,
            ast.type == :table,
            row <- ast.children,
            row.type == :table_row,
            cell <- row.children,
            cell.type == :table_cell,
            cell_ast <- cell.children,
            cell_ast.type == :template,
            cell_ast.value.name == "Collection" do
          extract_first_positional_arg(cell_ast.value.args)
        end

      # Real production data should contain actual collection names
      assert length(collection_names) > 0
      # Starter Set should be in the real data
      assert "Starter Set" in collection_names
    end
  end

  # Helper functions for testing
  defp extract_first_positional_arg(args) do
    case Enum.find(args, fn
           {:positional, _} -> true
           _ -> false
         end) do
      {:positional, value} -> value
      _ -> nil
    end
  end
end
