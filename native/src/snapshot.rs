use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

// Nanosecond ctime as well as mtime makes timestamp-preserving replacements
// observable. Walk every directory on every request: no watcher delivery race,
// and additions, deletions, symlink changes and atomic saves are all visible.
pub fn capture(roots: &[String]) -> io::Result<Vec<u8>> {
    let mut entries = BTreeMap::new();
    for root in roots {
        visit(Path::new(root), &mut entries, &mut Vec::new())?;
    }
    let mut out = Vec::new();
    for (path, stamp) in entries {
        crate::protocol::write_bytes(&mut out, path.as_os_str().as_encoded_bytes())?;
        for n in stamp {
            out.extend(n.to_be_bytes());
        }
    }
    Ok(out)
}

fn visit(
    path: &Path,
    entries: &mut BTreeMap<PathBuf, [u64; 7]>,
    ancestors: &mut Vec<PathBuf>,
) -> io::Result<()> {
    if entries.contains_key(path) {
        return Ok(());
    }
    let meta = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            entries.insert(path.to_owned(), [0; 7]);
            return Ok(());
        }
        Err(e) => return Err(e),
    };
    entries.insert(
        path.to_owned(),
        [
            meta.dev(),
            meta.ino(),
            meta.mode() as u64,
            meta.size(),
            meta.mtime() as u64,
            meta.mtime_nsec() as u64,
            (meta.ctime() as u64)
                .wrapping_mul(1_000_000_000)
                .wrapping_add(meta.ctime_nsec() as u64),
        ],
    );
    if meta.file_type().is_symlink() {
        let target = fs::read_link(path)?;
        return visit_target(&path.parent().unwrap().join(target), entries, ancestors);
    }
    if meta.is_dir() {
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            if !ignored(&entry.file_name().to_string_lossy()) {
                visit(&entry.path(), entries, ancestors)?;
            }
        }
    }
    Ok(())
}

fn visit_target(
    path: &Path,
    entries: &mut BTreeMap<PathBuf, [u64; 7]>,
    ancestors: &mut Vec<PathBuf>,
) -> io::Result<()> {
    let canonical = match fs::canonicalize(path) {
        Ok(path) => path,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            entries.insert(path.to_owned(), [0; 7]);
            return Ok(());
        }
        Err(e) => return Err(e),
    };
    if ancestors.contains(&canonical) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "cyclic input symlink",
        ));
    }
    ancestors.push(canonical.clone());
    let result = visit(&canonical, entries, ancestors);
    ancestors.pop();
    result
}

fn ignored(name: &str) -> bool {
    matches!(
        name,
        ".git" | ".mix" | "qlover_instrumented" | "node_modules" | "target"
    )
}
