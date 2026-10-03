use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};

// Warm only the runtime/tooling. Project configuration, compilation, aliases,
// applications, helpers and tests all execute AFTER activation, exactly once.
const BOOT: &str = r#"
Mix.start()
for app <- [:mix, :ex_unit] do
  Application.load(app)
  {:ok, modules} = :application.get_key(app, :modules)
  :code.ensure_modules_loaded(modules)
end
Qlover.Native.prewarm()
case IO.read(:stdio, :line) do
  "run\n" -> Mix.CLI.main(System.argv())
  _ -> System.halt(1)
end
"#;

pub struct Worker {
    pub child: Child,
    heartbeat: ChildStdin,
}

impl Worker {
    pub fn spawn(
        project: &str,
        receipt: &Path,
        args: &[String],
        vars: &[(&str, &str)],
        warm: bool,
    ) -> io::Result<Self> {
        let mut child = Command::new(env::current_exe()?)
            .arg(if warm { "--warm-worker" } else { "--worker" })
            .args(args)
            .current_dir(project)
            .env_clear()
            .envs(vars.iter().copied())
            .env("MIX_ENV", "test")
            .env("QLOVER_IN_PROCESS", "1")
            .env("QLOVER_RECEIPT", receipt)
            .env("QLOVER_CLIENT", env::current_exe()?)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0)
            .spawn()?;
        let heartbeat = child.stdin.take().unwrap();
        Ok(Self { child, heartbeat })
    }

    pub fn activate(&mut self) -> io::Result<()> {
        self.heartbeat.write_all(b"r")
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        if !matches!(self.child.try_wait(), Ok(Some(_))) {
            kill_group(self.child.id());
            let _ = self.child.wait();
        }
    }
}

pub fn run(args: &[String], warm: bool) -> io::Result<i32> {
    let mut command = if warm {
        let mut command = Command::new("elixir");
        let receipt = PathBuf::from(env::var_os("QLOVER_RECEIPT").unwrap());
        let preload =
            crate::protocol::read_strings(&mut fs::File::open(receipt.with_extension("preload"))?)?;
        let code = preload.first().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "missing prewarm code path")
        })?;
        command.args(["-pa", code]);
        command.args(["-e", BOOT, "--", "test.qlover"]);
        command.stdin(Stdio::piped());
        command
    } else {
        let mut command = Command::new("mix");
        command.arg("test.qlover").stdin(Stdio::null());
        command
    };
    let mut child = command.args(args).spawn()?;
    let input = child.stdin.take();
    // The pipe is both a one-shot activation channel and a lifetime guardian.
    // EOF also kills a spare that has never executed a request.
    std::thread::spawn(move || {
        if let Some(mut input) = input {
            let mut byte = [0];
            if io::stdin().read_exact(&mut byte).is_ok() && byte == [b'r'] {
                let _ = input.write_all(b"run\n");
            } else {
                kill_group(std::process::id());
                return;
            }
        }
        let mut byte = [0];
        let _ = io::stdin().read(&mut byte);
        kill_group(std::process::id());
    });
    Ok(child.wait()?.code().unwrap_or(1))
}

pub fn kill_group(pid: u32) {
    unsafe {
        libc::kill(-(pid as i32), libc::SIGKILL);
    }
}

pub fn supported(vars: &[(&str, &str)]) -> bool {
    if vars.contains(&("QLOVER_PREWARM", "0")) {
        return false;
    }
    let path = vars.iter().find(|(key, _)| *key == "PATH").map(|(_, v)| *v);
    let Some(mix) = path.and_then(|path| executable(path, "mix")) else {
        return false;
    };
    // Preserve custom Mix wrappers: only bypass the standard Elixir entrypoint.
    fs::read_to_string(mix).is_ok_and(|body| {
        body.lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
            .eq(["Mix.CLI.main()"])
    }) && path.and_then(|path| executable(path, "elixir")).is_some()
}

fn executable(path: &str, name: &str) -> Option<PathBuf> {
    env::split_paths(path)
        .map(|dir| dir.join(name))
        .find(|path| {
            fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
}
