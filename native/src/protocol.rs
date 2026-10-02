use std::io::{self, Read, Write};

const LIMIT: usize = 16 * 1024 * 1024;

pub fn read_bytes(input: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut size = [0; 4];
    input.read_exact(&mut size)?;
    let size = u32::from_be_bytes(size) as usize;
    if size > LIMIT {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "oversized frame",
        ));
    }
    let mut bytes = vec![0; size];
    input.read_exact(&mut bytes)?;
    Ok(bytes)
}

pub fn write_bytes(output: &mut impl Write, bytes: &[u8]) -> io::Result<()> {
    output.write_all(&(bytes.len() as u32).to_be_bytes())?;
    output.write_all(bytes)
}

pub fn read_strings(input: &mut impl Read) -> io::Result<Vec<String>> {
    let mut count = [0; 4];
    input.read_exact(&mut count)?;
    let count = u32::from_be_bytes(count) as usize;
    if count > 65536 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "too many fields",
        ));
    }
    (0..count)
        .map(|_| {
            String::from_utf8(read_bytes(input)?)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
        })
        .collect()
}

pub fn write_strings(output: &mut impl Write, strings: &[String]) -> io::Result<()> {
    output.write_all(&(strings.len() as u32).to_be_bytes())?;
    for s in strings {
        write_bytes(output, s.as_bytes())?;
    }
    Ok(())
}

pub fn event(output: &mut impl Write, tag: u8, bytes: &[u8]) -> io::Result<()> {
    output.write_all(&[tag])?;
    write_bytes(output, bytes)
}
