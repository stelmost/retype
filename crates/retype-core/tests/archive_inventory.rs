//! An incomplete inventory cannot authorize native archive publication.

use std::fs;
use std::io::Write;
use std::path::Path;

use retype_core::archive::repack;
use retype_core::execute::Cancellation;
use retype_core::registry::Native;

fn refuses(input: &Path, format: Native, target: Native) {
	let original = fs::read(input).unwrap();
	let output = input.with_file_name(format!("output.{}", target.name()));
	assert!(repack(None, format, target, input, &output, &Cancellation::default()).is_err());
	assert!(!output.exists());
	assert_eq!(fs::read(input).unwrap(), original);
}

#[test]
fn duplicate_zip_entries_are_refused_instead_of_losing_one() {
	let directory = tempfile::tempdir().unwrap();
	let input = directory.path().join("input.zip");
	let mut zip = zip::ZipWriter::new(fs::File::create(&input).unwrap());
	for (name, contents) in [("one.txt", b"first".as_slice()), ("two.txt", b"second".as_slice())] {
		zip.start_file(name, zip::write::SimpleFileOptions::default()).unwrap();
		zip.write_all(contents).unwrap();
	}
	zip.finish().unwrap();
	/* The writer rejects duplicate names; retain two real records under one name. */
	let mut bytes = fs::read(&input).unwrap();
	let positions = bytes
		.windows(7)
		.enumerate()
		.filter_map(|(at, name)| (name == b"two.txt").then_some(at));
	let positions: Vec<_> = positions.collect();
	assert_eq!(positions.len(), 2);
	for at in positions {
		bytes[at..at + 7].copy_from_slice(b"one.txt");
	}
	fs::write(&input, bytes).unwrap();
	refuses(&input, Native::Zip, Native::Tar);
}

#[test]
fn a_zip_directory_cannot_hide_bytes() {
	let directory = tempfile::tempdir().unwrap();
	let input = directory.path().join("input.zip");
	let mut zip = zip::ZipWriter::new(fs::File::create(&input).unwrap());
	zip.start_file("folder/", zip::write::SimpleFileOptions::default())
		.unwrap();
	zip.write_all(b"directory payload").unwrap();
	zip.finish().unwrap();
	refuses(&input, Native::Zip, Native::Tar);
}

#[test]
fn a_tar_directory_cannot_hide_bytes() {
	let directory = tempfile::tempdir().unwrap();
	let input = directory.path().join("input.tar");
	let mut writer = tar::Builder::new(fs::File::create(&input).unwrap());
	let mut header = tar::Header::new_gnu();
	header.set_entry_type(tar::EntryType::Directory);
	header.set_size(4);
	header.set_mode(0o755);
	header.set_cksum();
	writer.append_data(&mut header, "folder/", &b"data"[..]).unwrap();
	writer.finish().unwrap();
	drop(writer);
	refuses(&input, Native::Tar, Native::TarGz);
}
