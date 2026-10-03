use crate::{protocol, snapshot};
use std::fs;
use std::io::Cursor;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT: AtomicUsize = AtomicUsize::new(0);

#[test]
fn bulk_records_keep_binary_payloads_and_unreadable_entries() {
    let dir = Directory::new();
    fs::write(dir.0.join("b.term"), [0, 255, 131]).unwrap();
    fs::write(dir.0.join("ignored.tmp"), "ignore").unwrap();
    fs::create_dir(dir.0.join("a.term")).unwrap();
    let mut bytes = Vec::new();
    crate::files::records(&dir.0, &mut bytes).unwrap();
    assert_eq!(&bytes[..4], &4_u32.to_be_bytes());
    let mut input = Cursor::new(&bytes[4..]);
    assert_eq!(protocol::read_bytes(&mut input).unwrap(), b"a.term");
    assert!(protocol::read_bytes(&mut input).unwrap().is_empty());
    assert_eq!(protocol::read_bytes(&mut input).unwrap(), b"b.term");
    assert_eq!(protocol::read_bytes(&mut input).unwrap(), [0, 255, 131]);
}

#[test]
fn native_file_hashes_preserve_relative_names_and_explicit_hidden_roots() {
    let dir = Directory::new();
    fs::create_dir_all(dir.0.join("test/nested")).unwrap();
    fs::create_dir_all(dir.0.join("test/.hidden")).unwrap();
    for name in [
        "test/a.exs",
        "test/nested/b.exs",
        "test/.hidden/ignored.exs",
    ] {
        fs::write(dir.0.join(name), "abc").unwrap();
    }
    let root = dir.0.join("test").to_string_lossy().into_owned();
    let values = crate::files::hashes(&[root.clone(), root], &dir.0).unwrap();
    let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    assert_eq!(values, ["test/a.exs", sha, "test/nested/b.exs", sha]);
    let hidden = dir
        .0
        .join("test/.hidden/ignored.exs")
        .to_string_lossy()
        .into_owned();
    assert_eq!(
        crate::files::hashes(&[hidden], &dir.0).unwrap(),
        ["test/.hidden/ignored.exs", sha]
    );
    assert!(crate::files::hashes(
        &[dir.0.join("missing").to_string_lossy().into_owned()],
        &dir.0
    )
    .unwrap()
    .is_empty());
}

#[test]
fn prewarming_preserves_custom_mix_wrappers_and_explicit_opt_out() {
    let dir = Directory::new();
    let path = dir.0.to_str().unwrap();
    let vars = [("PATH", path)];
    assert!(!crate::worker::supported(&vars));
    for name in ["mix", "elixir"] {
        let file = dir.0.join(name);
        fs::write(&file, "#!/usr/bin/env elixir\n# comment\nMix.CLI.main()\n").unwrap();
        fs::set_permissions(file, fs::Permissions::from_mode(0o755)).unwrap();
    }
    assert!(crate::worker::supported(&vars));
    assert!(!crate::worker::supported(&[
        ("PATH", path),
        ("QLOVER_PREWARM", "0")
    ]));
    fs::write(dir.0.join("mix"), "#!/bin/sh\nexec custom-mix \"$@\"\n").unwrap();
    assert!(!crate::worker::supported(&vars));
}

#[test]
fn fingerprint_memo_reuses_only_unchanged_entries_and_rejects_corruption() {
    let dir = Directory::new();
    let base = dir.0.join("receipt");
    let a = dir.0.join("a.ex");
    let b = dir.0.join("b.ex");
    fs::write(&a, "a").unwrap();
    fs::write(&b, "b").unwrap();
    let entries = vec![
        "value-a".into(),
        "1".into(),
        a.to_string_lossy().into_owned(),
        "value-b".into(),
        "1".into(),
        b.to_string_lossy().into_owned(),
    ];
    protocol::write_strings(
        &mut fs::File::create(base.with_extension("memo.raw")).unwrap(),
        &entries,
    )
    .unwrap();
    crate::memo::save(&base).unwrap();
    fs::write(&a, "modified").unwrap();
    let target = base.with_extension("restored");
    crate::memo::restore(&base.with_extension("memo"), &target).unwrap();
    assert_eq!(
        protocol::read_strings(&mut fs::File::open(&target).unwrap()).unwrap(),
        vec!["value-b"]
    );
    fs::write(base.with_extension("memo"), "corrupt").unwrap();
    crate::memo::restore(&base.with_extension("memo"), &target).unwrap();
    assert!(protocol::read_strings(&mut fs::File::open(target).unwrap())
        .unwrap()
        .is_empty());
}

struct Directory(std::path::PathBuf);
impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "qlover-unit-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst)
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn capture(&self) -> Vec<u8> {
        snapshot::capture(&[self.0.to_string_lossy().into_owned()]).unwrap()
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn protocol_preserves_empty_and_unicode_fields_and_rejects_corruption() {
    let fields = vec!["".into(), "λ\n\0".into(), "--seed=1".into()];
    let mut bytes = Vec::new();
    protocol::write_strings(&mut bytes, &fields).unwrap();
    assert_eq!(
        protocol::read_strings(&mut Cursor::new(&bytes)).unwrap(),
        fields
    );
    for n in 0..bytes.len() {
        assert!(protocol::read_strings(&mut Cursor::new(&bytes[..n])).is_err());
    }
    assert!(protocol::read_bytes(&mut Cursor::new(u32::MAX.to_be_bytes())).is_err());
    assert!(protocol::read_strings(&mut Cursor::new(u32::MAX.to_be_bytes())).is_err());
}

#[test]
fn snapshots_detect_edits_even_when_size_and_mtime_are_restored() {
    let dir = Directory::new();
    let file = dir.0.join("source.ex");
    fs::write(&file, "before").unwrap();
    let before = dir.capture();
    let modified = fs::metadata(&file).unwrap().modified().unwrap();
    std::thread::sleep(std::time::Duration::from_millis(2));
    fs::write(&file, "after!").unwrap();
    fs::File::options()
        .write(true)
        .open(&file)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(modified))
        .unwrap();
    assert_ne!(before, dir.capture());
    assert_eq!(dir.capture(), dir.capture());
}

#[test]
fn snapshots_follow_symlinks_and_detect_added_deleted_and_replaced_inputs() {
    let dir = Directory::new();
    let target = Directory::new();
    symlink(&target.0, dir.0.join("dependency")).unwrap();
    let before = dir.capture();
    fs::write(target.0.join("new.ex"), "new").unwrap();
    let added = dir.capture();
    assert_ne!(before, added);
    fs::remove_file(target.0.join("new.ex")).unwrap();
    assert_ne!(added, dir.capture());
    fs::remove_file(dir.0.join("dependency")).unwrap();
    symlink(dir.0.join("missing"), dir.0.join("dependency")).unwrap();
    assert_ne!(before, dir.capture());
}

#[test]
fn overlapping_roots_have_the_same_snapshot_as_their_parent() {
    let dir = Directory::new();
    fs::create_dir(dir.0.join("lib")).unwrap();
    fs::write(dir.0.join("lib/file.ex"), "code").unwrap();
    let overlapping = snapshot::capture(&[
        dir.0.to_string_lossy().into_owned(),
        dir.0.join("lib").to_string_lossy().into_owned(),
    ])
    .unwrap();
    assert_eq!(dir.capture(), overlapping);
}
