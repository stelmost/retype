//! The ZIP reader indexes entries by name. Check that its index did not hide records.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

use super::{Cancellation, Result, check_entry_count, malformed, stop_if_cancelled};

pub(super) fn check(file: &mut File, archive: &zip::ZipArchive<File>, cancellation: &Cancellation) -> Result<()> {
	file.seek(SeekFrom::Start(archive.central_directory_start()))?;
	let mut count = 0;
	loop {
		stop_if_cancelled(cancellation)?;
		let mut signature = [0; 4];
		file.read_exact(&mut signature)?;
		match &signature {
			b"PK\x01\x02" => {
				count += 1;
				check_entry_count(count)?;
				if count > archive.len() {
					return Err(malformed(
						"the zip",
						&"the directory contains duplicate or unindexed entries",
					));
				}
				let mut header = [0; 42];
				file.read_exact(&mut header)?;
				let fields = header[24..30].chunks_exact(2);
				let skip: i64 = fields
					.map(|field| i64::from(u16::from_le_bytes([field[0], field[1]])))
					.sum();
				file.seek(SeekFrom::Current(skip))?;
			}
			/* End of directory, with or without ZIP64 records or a directory signature. */
			b"PK\x05\x06" | b"PK\x06\x06" | b"PK\x05\x05" if count == archive.len() => return Ok(()),
			_ => return Err(malformed("the zip", &"the central directory does not match its index")),
		}
	}
}
