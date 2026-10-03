use crate::{protocol, snapshot, worker};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc, Mutex,
};
use std::time::{Duration, Instant};

struct Cached {
    request: Vec<String>,
    roots: Vec<String>,
    snapshot: Vec<u8>,
    output: String,
    code: i32,
}

struct Spare {
    worker: worker::Worker,
    request: Vec<String>,
    roots: Vec<String>,
    snapshot: Vec<u8>,
}

type Arguments<'a> = (&'a [String], Vec<(&'a str, &'a str)>);

struct State {
    cached: Mutex<Option<Cached>>,
    active: AtomicUsize,
    stopped: AtomicBool,
    touched: Mutex<Instant>,
    child: Mutex<Option<u32>>,
    spare: Mutex<Option<Spare>>,
    directory: PathBuf,
    project: String,
    revision: String,
}

pub fn serve(directory: &Path) -> io::Result<i32> {
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(directory.join("lock"))?;
    // The OS releases the lock after crashes. Only its owner may remove a stale
    // socket, so simultaneous first clients cannot launch competing daemons.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Ok(0);
    }
    let socket = directory.join("socket");
    let _ = fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket)?;
    let state = Arc::new(State {
        cached: Mutex::new(None),
        active: AtomicUsize::new(0),
        stopped: AtomicBool::new(false),
        touched: Mutex::new(Instant::now()),
        child: Mutex::new(None),
        spare: Mutex::new(None),
        directory: directory.into(),
        project: env::current_dir()?.to_string_lossy().into_owned(),
        revision: crate::revision()?,
    });
    let timeout = env::var("QLOVER_IDLE_TIMEOUT")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(600);
    listen(&listener, &state, Duration::from_secs(timeout))?;
    terminate(&state.child);
    state.spare.lock().unwrap().take();
    let _ = fs::remove_file(socket);
    Ok(0)
}

fn listen(listener: &UnixListener, state: &Arc<State>, timeout: Duration) -> io::Result<()> {
    while !state.stopped.load(Ordering::SeqCst) {
        if state.active.load(Ordering::SeqCst) == 0
            && state.touched.lock().unwrap().elapsed() >= timeout
        {
            break;
        }
        let mut poll = libc::pollfd {
            fd: listener.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let ready = unsafe { libc::poll(&mut poll, 1, 100) };
        if ready < 0 {
            return Err(io::Error::last_os_error());
        }
        if ready == 0 {
            continue;
        }
        let (stream, _) = listener.accept()?;
        let state = Arc::clone(state);
        state.active.fetch_add(1, Ordering::SeqCst);
        std::thread::spawn(move || {
            if let Err(e) = handle(stream, &state) {
                eprintln!("qlover request: {e}");
            }
            *state.touched.lock().unwrap() = Instant::now();
            state.active.fetch_sub(1, Ordering::SeqCst);
        });
    }
    Ok(())
}

fn handle(mut stream: UnixStream, state: &Arc<State>) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let request = protocol::read_strings(&mut stream)?;
    stream.set_read_timeout(None)?;
    let (args, vars) = parse(&request, &state.project)?;
    if args == ["--stop"] {
        state.stopped.store(true, Ordering::SeqCst);
        terminate(&state.child);
        state.spare.lock().unwrap().take();
        protocol::event(&mut stream, 1, b"qlover: daemon stopped\n")?;
        return protocol::event(&mut stream, 3, &0_i32.to_be_bytes());
    }
    if args == ["--status"] {
        let spare = state.spare.lock().unwrap();
        let pid = spare.as_ref().map(|s| s.worker.child.id());
        let msg = format!(
            "qlover: daemon {} for {} (spare worker: {:?})\n",
            std::process::id(),
            state.project,
            pid
        );
        protocol::event(&mut stream, 1, msg.as_bytes())?;
        return protocol::event(&mut stream, 3, &0_i32.to_be_bytes());
    }
    // Per-project request serialization, never a global lock across worktrees.
    let mut cached = state.cached.lock().unwrap();
    if state.stopped.load(Ordering::SeqCst) {
        return protocol::event(&mut stream, 4, b"restart");
    }
    let revision = vars
        .iter()
        .find(|(k, _)| *k == "QLOVER_CLIENT_REVISION")
        .map(|(_, v)| *v);
    if revision != Some(state.revision.as_str()) {
        state.stopped.store(true, Ordering::SeqCst);
        return protocol::event(&mut stream, 4, b"restart");
    }
    if let Some(entry) = &*cached {
        if entry.request == request && snapshot::capture(&entry.roots)? == entry.snapshot {
            protocol::event(
                &mut stream,
                1,
                b"qlover: unchanged inputs; reusing verified coverage (daemon).\n",
            )?;
            protocol::event(&mut stream, 1, entry.output.as_bytes())?;
            return protocol::event(&mut stream, 3, &entry.code.to_be_bytes());
        }
    }
    if cached.as_ref().map(|entry| &entry.request) != Some(&request) {
        let _ = fs::remove_file(state.directory.join("receipt.memo"));
    }
    *cached = None;
    let code = execute(&mut stream, state, &request, args, &vars)?;
    if !args.iter().any(|s| s == "--no-stale" || s == "--dry") {
        *cached = match cache_result(state, request.clone(), code) {
            Ok(entry) => Some(entry),
            Err(e) => {
                eprintln!("cache not retained: {e}");
                None
            }
        };
    }
    if let Err(e) = replenish(state, request.clone(), args, &vars) {
        eprintln!("worker not prewarmed: {e}");
    }
    protocol::event(&mut stream, 3, &code.to_be_bytes())
}

fn parse<'a>(request: &'a [String], project: &str) -> io::Result<Arguments<'a>> {
    let count = request.get(1).and_then(|s| s.parse::<usize>().ok());
    match count {
        Some(n)
            if request.first().map(String::as_str) == Some(project)
                && n <= request.len() - 2
                && (request.len() - 2 - n) % 2 == 0 =>
        {
            let vars = request[2 + n..]
                .chunks_exact(2)
                .map(|s| (s[0].as_str(), s[1].as_str()))
                .collect();
            Ok((&request[2..2 + n], vars))
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid request or wrong project",
        )),
    }
}

fn execute(
    stream: &mut UnixStream,
    state: &Arc<State>,
    request: &[String],
    args: &[String],
    vars: &[(&str, &str)],
) -> io::Result<i32> {
    let receipt = state.directory.join("receipt");
    for suffix in ["", ".before", ".roots"] {
        let _ = fs::remove_file(format!("{}{suffix}", receipt.display()));
    }
    let mut worker = match take_spare(state, request) {
        Some(worker) => {
            protocol::event(stream, 1, b"qlover: using prewarmed isolated worker.\n")?;
            worker
        }
        _ => worker::Worker::spawn(&state.project, &receipt, args, vars, false)?,
    };
    let child = &mut worker.child;
    *state.child.lock().unwrap() = Some(child.id());
    let socket = Arc::new(Mutex::new(stream.try_clone()?));
    let out = pump(child.stdout.take().unwrap(), Arc::clone(&socket), 1);
    let err = pump(child.stderr.take().unwrap(), socket, 2);
    let done = Arc::new(AtomicBool::new(false));
    monitor(stream.try_clone()?, Arc::clone(state), Arc::clone(&done));
    let status = child.wait()?;
    // A killed guardian or a port surviving BEAM shutdown must not keep the
    // output pipes (or the project queue) open indefinitely.
    worker::kill_group(child.id());
    done.store(true, Ordering::SeqCst);
    *state.child.lock().unwrap() = None;
    out.join().unwrap()?;
    err.join().unwrap()?;
    Ok(status.code().unwrap_or(1))
}

fn take_spare(state: &State, request: &[String]) -> Option<worker::Worker> {
    let mut spare = state.spare.lock().unwrap().take()?;
    if spare.request == request
        && snapshot::capture(&spare.roots).ok()? == spare.snapshot
        && spare.worker.child.try_wait().ok()?.is_none()
        && spare.worker.activate().is_ok()
    {
        Some(spare.worker)
    } else {
        None
    }
}

fn replenish(
    state: &State,
    request: Vec<String>,
    args: &[String],
    vars: &[(&str, &str)],
) -> io::Result<()> {
    if !worker::supported(vars) || state.stopped.load(Ordering::SeqCst) {
        return Ok(());
    }
    let receipt = state.directory.join("receipt");
    let roots = protocol::read_strings(&mut File::open(receipt.with_extension("toolchain"))?)?;
    let snapshot = snapshot::capture(&roots)?;
    let mut spare = state.spare.lock().unwrap();
    if !state.stopped.load(Ordering::SeqCst) {
        *spare = Some(Spare {
            worker: worker::Worker::spawn(&state.project, &receipt, args, vars, true)?,
            request,
            roots,
            snapshot,
        });
    }
    Ok(())
}

fn pump(
    mut source: impl Read + Send + 'static,
    output: Arc<Mutex<UnixStream>>,
    tag: u8,
) -> std::thread::JoinHandle<io::Result<()>> {
    std::thread::spawn(move || {
        let mut buffer = [0; 8192];
        loop {
            let n = source.read(&mut buffer)?;
            if n == 0 {
                return Ok(());
            }
            protocol::event(&mut *output.lock().unwrap(), tag, &buffer[..n])?;
        }
    })
}

fn monitor(mut stream: UnixStream, state: Arc<State>, done: Arc<AtomicBool>) {
    std::thread::spawn(move || {
        let mut byte = [0];
        let _ = stream.read(&mut byte);
        if !done.load(Ordering::SeqCst) {
            terminate(&state.child);
        }
    });
}

fn terminate(child: &Mutex<Option<u32>>) {
    if let Some(pid) = *child.lock().unwrap() {
        // Kill the whole isolated worker group, including ports it spawned.
        unsafe {
            libc::kill(-(pid as i32), libc::SIGKILL);
        }
    }
}

fn cache_result(state: &State, request: Vec<String>, code: i32) -> io::Result<Cached> {
    let receipt = state.directory.join("receipt");
    let fields = protocol::read_strings(&mut File::open(&receipt)?)?;
    if fields.len() != 4 || fields[0].parse::<i32>().ok() != Some(code) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "worker did not verify coverage",
        ));
    }
    let mut roots = protocol::read_strings(&mut File::open(receipt.with_extension("roots"))?)?;
    let before = fs::read(receipt.with_extension("before"))?;
    let mut scanner = snapshot::Scanner::default();
    if scanner.capture(&roots)? != before {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "inputs changed during tests",
        ));
    }
    roots.extend(fields[2..].iter().cloned());
    let snapshot = scanner.capture(&roots)?;
    let _ = crate::memo::save_with(&receipt, &mut scanner);
    Ok(Cached {
        request,
        roots,
        snapshot,
        output: fields[1].clone(),
        code,
    })
}
