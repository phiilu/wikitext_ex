ExUnit.start(exclude: [:corpus])

Application.ensure_all_started(:credo)

"credo_checks/**/*.ex"
|> Path.wildcard()
|> Enum.each(&Code.require_file/1)
