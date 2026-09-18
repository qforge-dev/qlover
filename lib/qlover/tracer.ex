defmodule Qlover.Tracer do
  @moduledoc """
  Compiler tracer recording test-file → module reference edges for
  per-test-file coverage attribution.

  Enable it in the host project so both library and test compilations
  are traced:

      # mix.exs
      def project do
        [...,
         elixirc_options: [tracers: [Qlover.Tracer]],
         test_elixirc_options: [tracers: [Qlover.Tracer]]]
      end

  (`elixirc_options` covers `mix compile`; test files are required
  separately by `mix test`, so they need `test_elixirc_options`.)

  On every `:stop` event the tracer writes one record per source file to
  the refs dir (see `default_dir/0`), merging with any record already on
  disk, so the last write always holds the union for that file. Records
  are keyed by file content hash, which is what makes them safe to read
  across runs: the gate only trusts a record whose hash matches the file
  version being judged.

  The tracer never breaks compilation: every failure is swallowed and
  reported as `:ok`. A missing or corrupt record only ever degrades to a
  full-suite fallback, never to a false pass.
  """

  @ref_kinds [
    :remote_function,
    :remote_macro,
    :imported_function,
    :imported_macro,
    :imported_quoted
  ]

  @doc false
  def default_dir do
    Path.join(File.cwd!(), "cover/.qlover_refs")
  end

  @doc false
  def project_root do
    Application.get_env(:qlover, :project_root) || File.cwd!()
  end

  @doc false
  def refs_dir do
    Application.get_env(:qlover, :refs_dir) || default_dir()
  end

  @doc false
  def trace(:start, env) do
    if is_binary(env.file) do
      key = key(env.file)
      if Process.get(key) == nil, do: Process.put(key, {MapSet.new(), MapSet.new()})
    end

    :ok
  end

  @doc false
  def trace(:stop, env) do
    flush(env)
    :ok
  rescue
    _error -> :ok
  end

  @doc false
  def trace({kind, _meta, module, _name, _arity} = _event, env)
      when kind in @ref_kinds and is_atom(module) do
    note(env, module)
    :ok
  end

  @doc false
  def trace({:alias_reference, _meta, module}, env) when is_atom(module) do
    note(env, module)
    :ok
  end

  @doc false
  def trace({:struct_expansion, _meta, module, _keys}, env) when is_atom(module) do
    note(env, module)
    :ok
  end

  @doc false
  def trace(_event, _env), do: :ok

  defp note(env, module) do
    if is_binary(env.file) do
      key = key(env.file)
      {mods, defs} = Process.get(key, {MapSet.new(), MapSet.new()})
      Process.put(key, {MapSet.put(mods, module), note_defined(defs, env.module)})
    end

    :ok
  end

  defp note_defined(defs, nil), do: defs
  defp note_defined(defs, module) when is_atom(module), do: MapSet.put(defs, module)
  defp note_defined(defs, _other), do: defs

  defp flush(env) do
    if is_binary(env.file) do
      # A :stop with no entry means this process saw neither :start nor
      # events for the file, so it knows nothing: skip the write rather
      # than clobber a good record with an empty one.
      case Process.delete(key(env.file)) do
        nil -> :ok
        {mods, defs} -> write_record(env.file, mods, defs)
      end
    end

    :ok
  end

  defp write_record(file, mods, defs) do
    root = project_root()
    rel = relative_path(file, root)
    dir = refs_dir()
    File.mkdir_p!(dir)

    sha = hash_file(file)

    {mods, defs} =
      case read_record(Path.join(dir, Qlover.Attribution.record_filename(rel))) do
        %{path: ^rel, sha: ^sha, modules: old_mods, defined: old_defs} ->
          {MapSet.union(MapSet.new(old_mods), mods), MapSet.union(MapSet.new(old_defs), defs)}

        _other ->
          {mods, defs}
      end

    record = %{
      path: rel,
      sha: sha,
      modules: mods |> Enum.map(&mod_string/1) |> Enum.sort() |> Enum.uniq(),
      defined: defs |> Enum.map(&mod_string/1) |> Enum.sort() |> Enum.uniq()
    }

    File.write!(record_path(dir, rel), :erlang.term_to_binary(record))
    :ok
  end

  defp mod_string(mod) when is_atom(mod), do: Atom.to_string(mod)
  defp mod_string(name) when is_binary(name), do: name

  defp read_record(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, record} <- Qlover.Attribution.decode_record(contents) do
      record
    else
      _error -> :error
    end
  end

  defp key(file), do: {__MODULE__, file}

  defp relative_path(file, root) do
    Path.relative_to(file, root)
  end

  defp hash_file(path) do
    case File.read(path) do
      {:ok, contents} -> :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
      {:error, _reason} -> nil
    end
  end

  defp record_path(dir, rel) do
    Path.join(dir, Qlover.Attribution.record_filename(rel))
  end
end
