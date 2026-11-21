//! Journal repair must never modify a file reached through a state-file alias.

use std::fs;

use retype_core::journal::Journal;

const ORIGINAL: &[u8] = b"unrelated private document\n";

#[test]
fn journal_repair_refuses_a_hard_link_to_unrelated_data() {
	let directory = tempfile::tempdir().unwrap();
	let original = directory.path().join("document.txt");
	let journal = directory.path().join("jobs.jsonl");
	fs::write(&original, ORIGINAL).unwrap();
	fs::hard_link(&original, &journal).unwrap();
	assert!(Journal::open(&journal).is_err());
	assert_eq!(fs::read(original).unwrap(), ORIGINAL);
}

#[cfg(unix)]
#[test]
fn journal_repair_refuses_a_symlink_to_unrelated_data() {
	let directory = tempfile::tempdir().unwrap();
	let original = directory.path().join("document.txt");
	let journal = directory.path().join("jobs.jsonl");
	fs::write(&original, ORIGINAL).unwrap();
	std::os::unix::fs::symlink(&original, &journal).unwrap();
	assert!(Journal::open(&journal).is_err());
	assert_eq!(fs::read(original).unwrap(), ORIGINAL);
}
