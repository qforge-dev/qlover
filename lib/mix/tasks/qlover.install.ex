defmodule Mix.Tasks.Qlover.Install do
  use Mix.Task
  @shortdoc "Build and install the native qlover daemon/client"
  @moduledoc "Builds the locked Rust client. Use --path to override ~/.local/bin/qlover."

  @impl true
  def run(args) do
    {opts, []} = OptionParser.parse!(args, strict: [path: :string])
    source = Mix.Project.deps_paths()[:qlover] || File.cwd!()
    native = Path.join(source, "native")

    {_, code} =
      System.cmd("cargo", ["build", "--release", "--locked"],
        cd: native,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if code != 0, do: Mix.raise("native qlover build failed (exit #{code})")
    path = Path.expand(opts[:path] || "~/.local/bin/qlover")
    File.mkdir_p!(Path.dirname(path))
    temp = path <> ".#{System.pid()}.tmp"
    File.cp!(Path.join(native, "target/release/qlover"), temp)
    File.chmod!(temp, 0o755)
    File.rename!(temp, path)

    Mix.shell().info(
      "Installed #{path}. Run qlover in a Mix project; qlover --stop shuts down its daemon."
    )
  end
end
