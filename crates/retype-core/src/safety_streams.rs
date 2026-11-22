//! Read the Windows data-stream inventory without resolving the file's path again.

use super::StreamProtection;

const HEADER_BYTES: usize = 24;
const COLON: &[u8] = b":\0";
const DATA: &[u8] = b":\0$\0D\0A\0T\0A\0";

#[cfg(windows)]
pub(super) fn inspect(file: &std::fs::File) -> Option<StreamProtection> {
	use std::os::windows::io::AsRawHandle;
	use windows_sys::Win32::Storage::FileSystem::{FILE_STREAM_INFO, FileStreamInfo, GetFileInformationByHandleEx};

	const _: () = assert!(std::mem::offset_of!(FILE_STREAM_INFO, StreamName) == HEADER_BYTES);
	/* shortcut: Oversized inventories are unverified; increase the bound if the keep reason is insufficient. */
	let mut buffer = [0_u64; 512];
	let size = std::mem::size_of_val(&buffer);
	let pointer = buffer.as_mut_ptr().cast::<u8>();
	if unsafe { GetFileInformationByHandleEx(file.as_raw_handle(), FileStreamInfo, pointer.cast(), size as u32) } == 0 {
		return Some(StreamProtection::InspectionUnavailable);
	}
	/* The API returns variable-length records in an aligned, zero-initialized buffer. */
	inspect_inventory(unsafe { std::slice::from_raw_parts(pointer, size) })
}

fn inspect_inventory(bytes: &[u8]) -> Option<StreamProtection> {
	match has_named_stream(bytes) {
		Some(true) => Some(StreamProtection::NamedStreams),
		Some(false) => None,
		None => Some(StreamProtection::InspectionUnavailable),
	}
}

/// A clear result requires a single, well-formed unnamed data stream.
fn has_named_stream(mut bytes: &[u8]) -> Option<bool> {
	let mut saw_unnamed = false;
	loop {
		let next = u32::from_le_bytes(bytes.get(..4)?.try_into().ok()?) as usize;
		let length = u32::from_le_bytes(bytes.get(4..8)?.try_into().ok()?) as usize;
		let end = HEADER_BYTES.checked_add(length)?;
		if length % 2 != 0 || (next != 0 && next < end) {
			return None;
		}
		let name = bytes.get(HEADER_BYTES..end)?.strip_prefix(COLON)?.strip_suffix(DATA)?;
		if !name.is_empty() {
			return name.chunks_exact(2).all(|unit| unit != [0, 0]).then_some(true);
		}
		if saw_unnamed {
			return None;
		}
		if next == 0 {
			return Some(false);
		}
		saw_unnamed = true;
		bytes = bytes.get(next..)?;
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn entry(name: &str) -> Vec<u8> {
		let name = name.encode_utf16().flat_map(u16::to_le_bytes).collect::<Vec<_>>();
		let mut entry = vec![0; HEADER_BYTES];
		entry[4..8].copy_from_slice(&(name.len() as u32).to_le_bytes());
		entry.extend(name);
		entry
	}

	#[test]
	fn a_named_stream_counts_even_if_its_length_is_zero() {
		let unnamed = entry("::$DATA");
		assert_eq!(inspect_inventory(&unnamed), None);
		for name in [":empty:$DATA", ":Zone.Identifier:$DATA", ":名:$DATA"] {
			let mut inventory = unnamed.clone();
			inventory.resize(inventory.len().next_multiple_of(8), 0);
			let next = inventory.len() as u32;
			inventory[..4].copy_from_slice(&next.to_le_bytes());
			inventory.extend(entry(name));
			assert_eq!(inspect_inventory(&inventory), Some(StreamProtection::NamedStreams));
		}
	}

	#[test]
	fn an_incomplete_or_unrecognized_inventory_cannot_authorize_removal() {
		let mut out_of_bounds = entry("::$DATA");
		out_of_bounds[..4].copy_from_slice(&512_u32.to_le_bytes());
		let mut overlaps = entry("::$DATA");
		overlaps[..4].copy_from_slice(&8_u32.to_le_bytes());
		for bytes in [vec![], overlaps, out_of_bounds, entry("::$OTHER"), entry("::\0:$DATA")] {
			assert_eq!(inspect_inventory(&bytes), Some(StreamProtection::InspectionUnavailable));
		}
	}
}
