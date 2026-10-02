use crate::{protocol, snapshot};
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::Path;

// Values are opaque, versioned Erlang terms. Only exact input metadata matches
// admit them; missing/corrupt data always falls back to recomputing fingerprints.
pub fn save(base: &Path) -> io::Result<()> {
    let raw = protocol::read_strings(&mut File::open(base.with_extension("memo.raw"))?)?;
    let mut iter = raw.into_iter();
    let mut output = Vec::new();
    while let Some(value) = iter.next() {
        let count = iter
            .next()
            .and_then(|s| s.parse::<usize>().ok())
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid memo roots"))?;
        let roots: Vec<_> = iter.by_ref().take(count).collect();
        if roots.len() != count {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "truncated memo"));
        }
        protocol::write_strings(&mut output, &roots)?;
        protocol::write_bytes(&mut output, &snapshot::capture(&roots)?)?;
        protocol::write_bytes(&mut output, value.as_bytes())?;
    }
    let checksum = blake3::hash(&output);
    output.extend_from_slice(checksum.as_bytes());
    fs::write(base.with_extension("memo.tmp"), output)?;
    fs::rename(base.with_extension("memo.tmp"), base.with_extension("memo"))
}

pub fn restore(source: &Path, target: &Path) -> io::Result<()> {
    let mut values = Vec::new();
    // Parse completely before returning values. A partial/corrupt memo isn't a
    // partially trustworthy result.
    if let Ok(bytes) = fs::read(source) {
        if let Ok(found) = verified(&bytes) {
            values = found;
        }
    }
    protocol::write_strings(&mut File::create(target)?, &values)
}

fn verified(bytes: &[u8]) -> io::Result<Vec<String>> {
    if bytes.len() < 32 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "truncated memo checksum",
        ));
    }
    let (bytes, checksum) = bytes.split_at(bytes.len() - 32);
    if blake3::hash(bytes).as_bytes() != checksum {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "memo checksum mismatch",
        ));
    }
    let mut input = io::Cursor::new(bytes);
    let mut result = Vec::new();
    while input.position() < bytes.len() as u64 {
        let roots = protocol::read_strings(&mut input)?;
        let stamp = read_stamp(&mut input)?;
        let value = protocol::read_bytes(&mut input)?;
        if snapshot::capture(&roots)? == stamp {
            result.push(
                String::from_utf8(value)
                    .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?,
            );
        }
    }
    Ok(result)
}

fn read_stamp(input: &mut impl Read) -> io::Result<Vec<u8>> {
    protocol::read_bytes(input)
}
