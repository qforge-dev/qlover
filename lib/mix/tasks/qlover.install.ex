defmodule Mix.Tasks.Qlover.Install do
  use Mix.Task
  @shortdoc "Install the native qlover daemon/client"
  @moduledoc "Installs a checksum-verified native release. Use --source to build locally and --path to override ~/.local/bin/qlover."

  @impl true
  def run(args) do
    {opts, []} =
      OptionParser.parse!(args, strict: [path: :string, source: :boolean, force: :boolean])

    source = Qlover.Binary.install!(opts)
    path = Path.expand(opts[:path] || "~/.local/bin/qlover")
    File.mkdir_p!(Path.dirname(path))
    temp = path <> ".#{System.pid()}.tmp"
    File.cp!(source, temp)
    File.chmod!(temp, 0o755)
    File.rename!(temp, path)

    Mix.shell().info(
      "Installed #{path}. Run qlover in a Mix project; qlover --stop shuts down its daemon."
    )
  end
end
