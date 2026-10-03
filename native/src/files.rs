use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

pub fn hashes(roots: &[String], project: &Path) -> io::Result<Vec<String>> {
    let mut files = BTreeMap::new();
    for root in roots {
        visit(Path::new(root), project, &mut HashSet::new(), &mut files)?;
    }
    Ok(files
        .into_iter()
        .flat_map(|(path, hash)| [path, hash])
        .collect())
}

pub fn records(directory: &Path, output: &mut impl Write) -> io::Result<()> {
    let mut names = Vec::new();
    if let Ok(entries) = fs::read_dir(directory) {
        for entry in entries {
            let name = entry?.file_name().to_string_lossy().into_owned();
            if name.ends_with(".term") {
                names.push(name);
            }
        }
    }
    names.sort();
    output.write_all(&((names.len() * 2) as u32).to_be_bytes())?;
    for name in names {
        let bytes = fs::read(directory.join(&name)).unwrap_or_default();
        crate::protocol::write_bytes(output, name.as_bytes())?;
        crate::protocol::write_bytes(output, &bytes)?;
    }
    Ok(())
}

fn visit(
    path: &Path,
    project: &Path,
    active: &mut HashSet<PathBuf>,
    files: &mut BTreeMap<String, String>,
) -> io::Result<()> {
    let metadata = match fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    if metadata.is_file() {
        let name = path
            .strip_prefix(project)
            .unwrap_or(path)
            .to_string_lossy()
            .into_owned();
        if let std::collections::btree_map::Entry::Vacant(entry) = files.entry(name) {
            entry.insert(hex(&Sha256::digest(fs::read(path)?)));
        }
    } else if metadata.is_dir() {
        let real = fs::canonicalize(path)?;
        if active.insert(real.clone()) {
            for entry in fs::read_dir(path)? {
                let entry = entry?;
                if !entry.file_name().as_encoded_bytes().starts_with(b".") {
                    visit(&entry.path(), project, active, files)?;
                }
            }
            active.remove(&real);
        }
    }
    Ok(())
}

fn hex(bytes: &[u8]) -> String {
    let digits = b"0123456789abcdef";
    let mut result = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        result.push(digits[(byte >> 4) as usize] as char);
        result.push(digits[(byte & 15) as usize] as char);
    }
    result
}
