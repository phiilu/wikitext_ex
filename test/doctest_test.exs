defmodule WikitextExDoctestTest do
  use ExUnit.Case
  
  doctest WikitextEx
  doctest WikitextEx.AST
  doctest WikitextEx.Parser
end