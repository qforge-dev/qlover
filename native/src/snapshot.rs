use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

type Stamp = [u64; 7];

#[derive(Clone)]
struct Node {
    stamp: Stamp,
    children: Vec<PathBuf>,
}

// Scoped to ONE validation phase, never reused across requests. Overlapping
// fingerprint groups share stat/directory reads while still recording their
// own complete inputs. New phases always walk the filesystem afresh.
#[derive(Default)]
pub struct Scanner {
    nodes: HashMap<PathBuf, Node>,
}

pub fn capture(roots: &[String]) -> io::Result<Vec<u8>> {
    Scanner::default().capture(roots)
}

impl Scanner {
    pub fn capture(&mut self, roots: &[String]) -> io::Result<Vec<u8>> {
        let mut entries = BTreeMap::new();
        for root in roots {
            self.visit(Path::new(root), &mut entries)?;
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

    fn visit(&mut self, path: &Path, entries: &mut BTreeMap<PathBuf, Stamp>) -> io::Result<()> {
        if entries.contains_key(path) {
            return Ok(());
        }
        let node = match self.nodes.get(path) {
            Some(node) => node.clone(),
            None => {
                let node = read_node(path)?;
                self.nodes.insert(path.to_owned(), node.clone());
                node
            }
        };
        entries.insert(path.to_owned(), node.stamp);
        for child in node.children {
            self.visit(&child, entries)?;
        }
        Ok(())
    }
}

fn read_node(path: &Path) -> io::Result<Node> {
    let meta = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return Ok(Node {
                stamp: [0; 7],
                children: Vec::new(),
            })
        }
        Err(e) => return Err(e),
    };
    let stamp = [
        meta.dev(),
        meta.ino(),
        meta.mode() as u64,
        meta.size(),
        meta.mtime() as u64,
        meta.mtime_nsec() as u64,
        (meta.ctime() as u64)
            .wrapping_mul(1_000_000_000)
            .wrapping_add(meta.ctime_nsec() as u64),
    ];
    let children = children(path, &meta)?;
    Ok(Node { stamp, children })
}

fn children(path: &Path, meta: &fs::Metadata) -> io::Result<Vec<PathBuf>> {
    if meta.file_type().is_symlink() {
        let target = path.parent().unwrap().join(fs::read_link(path)?);
        let target = match fs::canonicalize(&target) {
            Ok(canonical) => canonical,
            Err(e) if e.kind() == io::ErrorKind::NotFound => target,
            Err(e) => return Err(e),
        };
        return Ok(vec![target]);
    }
    let mut children = Vec::new();
    if meta.is_dir() {
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            if !matches!(
                entry.file_name().to_string_lossy().as_ref(),
                ".git" | ".mix" | "qlover_instrumented" | "node_modules" | "target"
            ) {
                children.push(entry.path());
            }
        }
    }
    Ok(children)
}
