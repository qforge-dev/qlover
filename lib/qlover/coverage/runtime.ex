defmodule Qlover.Coverage.Runtime do
  @moduledoc false
  @table :qlover_attributed_hits

  def start! do
    :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])
    tracer = spawn_link(fn -> trace_loop(%{parents: %{}, contexts: %{}}) end)
    session = :trace.session_create(:qlover_coverage, tracer, [])

    unless :trace.function(session, {ExUnit.Runner, :exec_test_setup, 2}, true, [:local]) == 1 and
             :trace.function(session, {ExUnit.Runner, :run_module, 5}, true, [:local]) == 1 do
      raise "unsupported ExUnit runner: cannot establish synchronous test ownership"
    end

    :trace.process(session, :all, true, [:procs, :call, :set_on_spawn])
    {session, tracer, self()}
  end

  def hit(module, id) do
    :ets.insert(@table, {{self(), module, id}})
    :ok
  end

  def finish!({session, tracer, suite_pid}, inventory) do
    {:message_queue_len, pending} = Process.info(tracer, :message_queue_len)
    ref = :trace.delivered(session, :all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    after
      10_000 -> raise "attributed coverage trace did not drain"
    end

    send(tracer, {:snapshot, self()})

    state =
      receive do
        {:trace_snapshot, ^tracer, state} -> state
      after
        10_000 -> raise "attributed coverage collector did not respond"
      end

    :trace.session_destroy(session)

    unsettled =
      for {pid, _} <- state.parents,
          owner(pid, state) != nil,
          Process.alive?(pid),
          do: pid

    if unsettled != [] do
      raise "attributed coverage has #{length(unsettled)} unfinished test descendant(s)"
    end

    records = :ets.tab2list(@table)

    {hits, suite} =
      records
      |> Enum.reduce({%{}, %{}}, fn {{pid, module, id}}, {files, suite} ->
        with %{probes: probes} <- inventory[Atom.to_string(module)],
             line when is_integer(line) and line > 0 <- probes[id] do
          name = Atom.to_string(module)

          cond do
            pid == suite_pid ->
              {files, Map.update(suite, name, MapSet.new([line]), &MapSet.put(&1, line))}

            is_binary(file = owner(pid, state)) ->
              files =
                Map.update(files, file, %{name => MapSet.new([line])}, fn modules ->
                  Map.update(modules, name, MapSet.new([line]), &MapSet.put(&1, line))
                end)

              {files, suite}

            true ->
              {files, suite}
          end
        else
          _ -> {files, suite}
        end
      end)

    normalize = fn modules ->
      Map.new(modules, fn {mod, lines} -> {mod, lines |> MapSet.to_list() |> Enum.sort()} end)
    end

    stats = %{
      hit_records: length(records),
      traced_processes: map_size(state.parents),
      unknown_hit_records:
        Enum.count(records, fn {{pid, _, _}} -> pid != suite_pid and owner(pid, state) == nil end),
      pending_traces_at_seal: pending,
      collector_bytes:
        :ets.info(@table, :memory) * :erlang.system_info(:wordsize) +
          elem(Process.info(tracer, :memory), 1)
    }

    {Map.new(hits, fn {file, modules} -> {file, normalize.(modules)} end), normalize.(suite),
     stats}
  end

  defp owner(pid, state) do
    case state.contexts[pid] do
      nil ->
        case state.parents[pid] do
          nil -> nil
          {_parent, inherited} -> inherited
        end

      file ->
        file
    end
  end

  defp trace_loop(state) do
    receive do
      {:snapshot, from} ->
        send(from, {:trace_snapshot, self(), state})
        trace_loop(state)

      {:trace, pid, :spawn, child, _mfa} ->
        inherited = owner(pid, state)
        trace_loop(put_in(state, [:parents, child], {pid, inherited}))

      {:trace, pid, :call, {ExUnit.Runner, :run_module, [_config, mod | _]}} when is_atom(mod) ->
        trace_loop(context(state, pid, mod))

      {:trace, pid, :call, {ExUnit.Runner, :exec_test_setup, [%ExUnit.Test{module: mod} | _]}} ->
        trace_loop(context(state, pid, mod))

      {:trace, pid, :call, {mod, :__ex_unit__, [:setup_all, _]}} ->
        trace_loop(context(state, pid, mod))

      _other ->
        trace_loop(state)
    end
  end

  defp context(state, pid, module) do
    source = module.module_info(:compile)[:source] |> to_string() |> Path.relative_to_cwd()
    put_in(state, [:contexts, pid], source)
  end
end
