defmodule Qlover.Coverage.Instrumenter do
  @moduledoc false

  # sys_coverage is the same (undocumented) executable-line transform used by
  # OTP cover. Fail closed if its representation changes.
  def instrument!(directory, ignores) do
    files = directory |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".beam"))
    collect!(directory, files, ignores, true)
  end

  # Extract the identical cover probe inventory without loading any module or
  # running a test. Used to reject obviously uncovered, unreferenced new code.
  def inventory!(directory, beams, ignores) do
    collect!(directory, beams, ignores, false)
  end

  defp collect!(directory, files, ignores, load?) do
    unless System.otp_release() == "29" and
             Code.ensure_loaded?(:sys_coverage) and
             function_exported?(:sys_coverage, :cover_transform, 2) do
      raise "attributed coverage requires the tested OTP 29 cover transform"
    end

    files
    |> Enum.sort()
    |> Enum.reduce(%{}, fn file, acc ->
      module = file |> Path.rootname() |> String.to_atom()

      if module in [Qlover.Coverage.Runtime, Qlover.Coverage.Instrumenter] or
           ignored?(module, ignores) do
        acc
      else
        path = Path.join(directory, file)

        case :beam_lib.chunks(String.to_charlist(path), [:abstract_code, :compile_info]) do
          {:ok, {^module, chunks}} ->
            {:raw_abstract_v1, forms} = Keyword.fetch!(chunks, :abstract_code)
            info = Keyword.fetch!(chunks, :compile_info)

            source =
              info[:source]
              |> to_string()
              |> Qlover.Coverage.Evidence.source_path()
              |> then(fn source -> if source, do: Path.relative_to_cwd(source), else: file end)

            map = :ets.new(:qlover_probe_map, [:set, :private])

            try do
              index = fn _mod, fun, arity, clause, line ->
                key = {fun, arity, clause, line}

                case :ets.lookup(map, key) do
                  [{^key, id}] ->
                    id

                  [] ->
                    id = :ets.info(map, :size) + 1
                    :ets.insert(map, {key, id})
                    id
                end
              end

              {:ok, marked} = :sys_coverage.cover_transform(forms, index)
              probes = :ets.tab2list(map) |> Map.new(fn {{_, _, _, line}, id} -> {id, line} end)

              if load? do
                rewritten = rewrite(marked, module)
                opts = [:binary, :return_errors, :return_warnings, {:source, to_charlist(source)}]

                case :compile.forms(rewritten, opts) do
                  {:ok, ^module, binary} -> load!(module, binary)
                  {:ok, ^module, binary, []} -> load!(module, binary)
                  other -> raise "cannot instrument #{inspect(module)}: #{inspect(other)}"
                end
              end

              Map.put(acc, Atom.to_string(module), %{
                source: source,
                lines:
                  probes |> Map.values() |> Enum.reject(&(&1 == 0)) |> Enum.uniq() |> Enum.sort(),
                probes: probes
              })
            after
              :ets.delete(map)
            end

          other ->
            raise "cannot read coverage abstract code for #{path}: #{inspect(other)}"
        end
      end
    end)
  end

  defp load!(module, binary) do
    case :code.load_binary(module, ~c"qlover_instrumented", binary) do
      {:module, ^module} -> :ok
      other -> raise "cannot load instrumented #{inspect(module)}: #{inspect(other)}"
    end
  end

  defp rewrite({:executable_line, anno, id}, module) do
    {:call, anno, {:remote, anno, {:atom, anno, Qlover.Coverage.Runtime}, {:atom, anno, :hit}},
     [{:atom, anno, module}, {:integer, anno, id}]}
  end

  defp rewrite(tuple, module) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&rewrite(&1, module)) |> List.to_tuple()
  end

  defp rewrite(list, module) when is_list(list), do: Enum.map(list, &rewrite(&1, module))
  defp rewrite(other, _module), do: other

  defp ignored?(module, ignores) do
    Enum.any?(ignores, fn
      %Regex{} = regex -> Regex.match?(regex, inspect(module))
      other -> module == other
    end)
  end
end
