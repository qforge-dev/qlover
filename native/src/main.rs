mod memo;
mod protocol;
mod server;
mod snapshot;
#[cfg(test)]
mod tests;
mod worker;

use std::env;
use std::fs::{self, File};
use std::hash::{Hash, Hasher};
use std::io::{self, Read};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn main() {
    let code = match run() {
        Ok(code) => code,
        Err(e) => {
            eprintln!("qlover: {e}");
            1
        }
    };
    std::process::exit(code);
}

fn run() -> io::Result<i32> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--prepare") && args.len() == 3 {
        let roots = protocol::read_strings(&mut File::open(&args[1])?)?;
        let base = std::path::Path::new(&args[2]);
        let mut scanner = snapshot::Scanner::default();
        fs::write(base.with_extension("before"), scanner.capture(&roots)?)?;
        memo::restore_with(
            &base.with_extension("memo"),
            &base.with_extension("restored"),
            &mut scanner,
        )?;
        return Ok(0);
    }
    if matches!(
        args.first().map(String::as_str),
        Some("--worker" | "--warm-worker")
    ) {
        return worker::run(&args[1..], args[0] == "--warm-worker");
    }
    if args.first().map(String::as_str) == Some("--memo-restore") && args.len() == 3 {
        memo::restore(
            std::path::Path::new(&args[1]),
            std::path::Path::new(&args[2]),
        )?;
        return Ok(0);
    }
    if args.first().map(String::as_str) == Some("--snapshot") {
        let roots = protocol::read_strings(&mut File::open(&args[1])?)?;
        fs::write(&args[2], snapshot::capture(&roots)?)?;
        return Ok(0);
    }
    if args == ["--help"] {
        println!("qlover [Mix test.qlover arguments]\nqlover --stop\nqlover --status\n\nPersistent native coordinator; isolated BEAM worker per changed run.\nQLOVER_IDLE_TIMEOUT: idle lifetime in seconds (default 600).");
        return Ok(0);
    }
    let directory = state_directory()?;
    if args == ["--serve"] {
        return server::serve(&directory);
    }
    let control = args == ["--stop"] || args == ["--status"];
    let mut connection = match UnixStream::connect(directory.join("socket")) {
        Ok(stream) => stream,
        Err(_) if control => {
            println!("qlover: daemon is not running");
            return Ok(0);
        }
        Err(_) => start(&directory)?,
    };
    let mut request = vec![env::current_dir()?.to_string_lossy().into_owned()];
    request.push(args.len().to_string());
    request.extend(args);
    let mut vars: Vec<_> = env::vars()
        .filter(|(k, _)| !matches!(k.as_str(), "_" | "SHLVL" | "OLDPWD"))
        .collect();
    vars.sort();
    vars.push(("QLOVER_CLIENT_REVISION".into(), revision()?));
    for (k, v) in vars {
        request.push(k);
        request.push(v);
    }
    protocol::write_strings(&mut connection, &request)?;
    let code = receive(&mut connection)?;
    if code == -1 {
        drop(connection);
        std::thread::sleep(Duration::from_millis(150));
        let mut connection = start(&directory)?;
        protocol::write_strings(&mut connection, &request)?;
        return receive(&mut connection);
    }
    Ok(code)
}

pub fn revision() -> io::Result<String> {
    let executable = env::current_exe()?;
    let metadata = fs::metadata(&executable)?;
    Ok(format!(
        "{}:{:?}:{}",
        executable.display(),
        metadata.modified()?,
        metadata.len()
    ))
}

fn receive(connection: &mut UnixStream) -> io::Result<i32> {
    loop {
        let mut tag = [0];
        connection.read_exact(&mut tag)?;
        let bytes = protocol::read_bytes(connection)?;
        match tag[0] {
            1 => {
                use io::Write;
                io::stdout().write_all(&bytes)?;
            }
            2 => {
                use io::Write;
                io::stderr().write_all(&bytes)?;
            }
            3 if bytes.len() == 4 => return Ok(i32::from_be_bytes(bytes.try_into().unwrap())),
            4 => return Ok(-1),
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "invalid daemon response",
                ))
            }
        }
    }
}

fn state_directory() -> io::Result<PathBuf> {
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    env::current_dir()?.canonicalize()?.hash(&mut hash);
    let root = env::var_os("QLOVER_DAEMON_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var_os("HOME").unwrap()).join(".cache/qlover/run"));
    let dir = root.join(format!("{:016x}", hash.finish()));
    fs::create_dir_all(&dir)?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    Ok(dir)
}

fn start(directory: &std::path::Path) -> io::Result<UnixStream> {
    let log = File::create(directory.join("daemon.log"))?;
    Command::new(env::current_exe()?)
        .arg("--serve")
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log)
        .process_group(0)
        .spawn()?;
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(stream) = UnixStream::connect(directory.join("socket")) {
            return Ok(stream);
        }
        if Instant::now() > deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "daemon startup failed; inspect daemon.log",
            ));
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}
