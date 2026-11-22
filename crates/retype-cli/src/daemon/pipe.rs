//! The named-pipe transport, `docs/dev/architecture/ipc.md` §4.
//!
//! Pipe instances are owned by the listener until connection, then by a bounded peer worker.

use std::ffi::OsStr;
use std::fs::File;
use std::io::{self, BufReader, Read, Write};
use std::mem::size_of;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle};
use std::ptr;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{
	ERROR_BROKEN_PIPE, ERROR_NO_DATA, ERROR_PIPE_CONNECTED, ERROR_PIPE_LISTENING, ERROR_PIPE_NOT_CONNECTED, HANDLE,
	INVALID_HANDLE_VALUE, LocalFree,
};
use windows_sys::Win32::Security::Authorization::{
	ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
};
use windows_sys::Win32::Security::{
	GetTokenInformation, PSECURITY_DESCRIPTOR, RevertToSelf, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER, TokenUser,
};
use windows_sys::Win32::Storage::FileSystem::{PIPE_ACCESS_DUPLEX, ReadFile, WriteFile};
use windows_sys::Win32::System::Pipes::{
	ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, ImpersonateNamedPipeClient, PIPE_NOWAIT,
	PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

use super::server::{Server, write_response};
use super::{connections, signals};
use crate::error::{Error, Result};

/// Owner may read and write, nobody else may do anything. `P` makes the DACL
/// protected, so inherited permissions cannot widen it.
const OWNER_ONLY: &str = "D:P(A;;GA;;;OW)";

const SDDL_REVISION_1: u32 = 1;
const BUFFER_BYTES: u32 = 64 * 1024;
const IO_POLL: Duration = Duration::from_millis(10);
const NUL: u16 = 0;

/// `\\.\pipe\retype-<machine>-<user>`, `docs/dev/architecture/ipc.md` §4.
pub fn name(machine: &str) -> String {
	format!(r"\\.\pipe\retype-{machine}-{}", user_token())
}

pub fn serve(name: &str, server: &mut Server, seen: &mut signals::Seen) -> Result<()> {
	let name = wide(name);
	let descriptor = Descriptor::create()?;
	let attributes = SECURITY_ATTRIBUTES {
		nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
		lpSecurityDescriptor: descriptor.0,
		bInheritHandle: 0,
	};
	let mut listener = instance(&name, &attributes)?;
	connections::serve(
		server,
		seen,
		move || accept(&mut listener, &name, &attributes),
		serve_client,
	)
}

fn instance(name: &[u16], attributes: &SECURITY_ATTRIBUTES) -> io::Result<File> {
	let handle = unsafe {
		CreateNamedPipeW(
			name.as_ptr(),
			PIPE_ACCESS_DUPLEX,
			PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
			/* The worker pool, not client-owned closing ends, bounds the daemon's active instances. */
			PIPE_UNLIMITED_INSTANCES,
			BUFFER_BYTES,
			BUFFER_BYTES,
			0,
			attributes,
		)
	};
	if handle == INVALID_HANDLE_VALUE {
		return Err(io::Error::last_os_error());
	}
	Ok(unsafe { File::from_raw_handle(handle) })
}

fn accept(listener: &mut File, name: &[u16], attributes: &SECURITY_ATTRIBUTES) -> Result<Option<File>> {
	/* In PIPE_NOWAIT mode success enables listening; ERROR_PIPE_CONNECTED transfers ownership. */
	if unsafe { ConnectNamedPipe(listener.as_raw_handle(), ptr::null_mut()) } != 0 {
		return Ok(None);
	}
	let error = io::Error::last_os_error();
	match error.raw_os_error().map(|code| code as u32) {
		Some(ERROR_PIPE_LISTENING) => Ok(None),
		Some(ERROR_PIPE_CONNECTED) => Ok(Some(std::mem::replace(listener, instance(name, attributes)?))),
		Some(ERROR_NO_DATA | ERROR_PIPE_NOT_CONNECTED) => {
			*listener = instance(name, attributes)?;
			Ok(None)
		}
		_ => Err(error.into()),
	}
}

fn serve_client(file: File, server: &Mutex<&mut Server>, stopping: &AtomicBool) -> Result<()> {
	let mut reader = BufReader::new(PipeIo::new(&file, Some(stopping)));
	let mut writer = PipeIo::new(&file, None);

	/* The first read supplies the client context for impersonation. No request runs before that check. */
	let Some(first) = read_request(&mut reader, stopping).unwrap_or_else(|error| {
		eprintln!("retype: refused a pipe client that sent no readable frame: {error}");
		None
	}) else {
		unsafe { DisconnectNamedPipe(file.as_raw_handle()) };
		return Ok(());
	};
	if unsafe { ImpersonateNamedPipeClient(file.as_raw_handle()) } == 0 {
		let error = io::Error::last_os_error();
		unsafe { DisconnectNamedPipe(file.as_raw_handle()) };
		return Err(io::Error::new(error.kind(), format!("cannot impersonate the pipe client: {error}")).into());
	}
	if unsafe { RevertToSelf() } == 0 {
		/* Never dispatch a request or reuse this thread under the client's token. */
		return Err(io::Error::other(format!(
			"cannot leave pipe client impersonation: {}",
			io::Error::last_os_error()
		))
		.into());
	}

	/* Close the owned end rather than flushing until the peer reads or discarding unread replies with Disconnect. */
	Server::serve_peer(
		server,
		|| read_request(&mut reader, stopping),
		|response| {
			writer.begin_frame();
			write_response(&mut writer, response)
		},
		Some(first),
	)
}

fn read_request(
	reader: &mut BufReader<PipeIo<'_>>,
	stopping: &AtomicBool,
) -> std::result::Result<Option<serde_json::Value>, retype_ipc::FrameError> {
	if stopping.load(Ordering::Relaxed) {
		return Ok(None);
	}
	reader.get_mut().begin_frame();
	let result = retype_ipc::read_frame(reader);
	if stopping.load(Ordering::Relaxed) {
		Ok(None)
	} else {
		result
	}
}

struct PipeIo<'a> {
	file: &'a File,
	stopping: Option<&'a AtomicBool>,
	deadline: Instant,
}

impl<'a> PipeIo<'a> {
	fn new(file: &'a File, stopping: Option<&'a AtomicBool>) -> Self {
		Self {
			file,
			stopping,
			deadline: Instant::now(),
		}
	}

	fn begin_frame(&mut self) {
		self.deadline = Instant::now() + connections::FRAME_TIMEOUT;
	}

	fn transfer(&self, mut step: impl FnMut() -> io::Result<usize>) -> io::Result<usize> {
		loop {
			if self.stopping.is_some_and(|stopping| stopping.load(Ordering::Relaxed)) {
				return Err(io::ErrorKind::ConnectionAborted.into());
			}
			let remaining = self.deadline.saturating_duration_since(Instant::now());
			if remaining.is_zero() {
				return Err(io::Error::new(io::ErrorKind::TimedOut, "IPC frame deadline elapsed"));
			}
			match step() {
				Err(error) if error.kind() == io::ErrorKind::WouldBlock => std::thread::sleep(remaining.min(IO_POLL)),
				result => return result,
			}
		}
	}
}

impl Read for PipeIo<'_> {
	fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
		if buffer.is_empty() {
			return Ok(0);
		}
		self.transfer(|| {
			let mut read = 0;
			/* Synchronous PIPE_NOWAIT calls never retain a pointer to the buffer. */
			let success = unsafe {
				ReadFile(
					self.file.as_raw_handle(),
					buffer.as_mut_ptr(),
					buffer.len().min(u32::MAX as usize) as u32,
					&mut read,
					ptr::null_mut(),
				)
			};
			if success != 0 {
				return Ok(read as usize);
			}
			let error = io::Error::last_os_error();
			match error.raw_os_error().map(|code| code as u32) {
				Some(ERROR_BROKEN_PIPE | ERROR_PIPE_NOT_CONNECTED) => Ok(0),
				Some(ERROR_NO_DATA) => Err(io::ErrorKind::WouldBlock.into()),
				_ => Err(error),
			}
		})
	}
}

impl Write for PipeIo<'_> {
	fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
		if buffer.is_empty() {
			return Ok(0);
		}
		self.transfer(|| {
			let mut written = 0;
			let success = unsafe {
				WriteFile(
					self.file.as_raw_handle(),
					buffer.as_ptr(),
					buffer.len().min(u32::MAX as usize) as u32,
					&mut written,
					ptr::null_mut(),
				)
			};
			if success == 0 {
				Err(io::Error::last_os_error())
			} else if written == 0 {
				Err(io::ErrorKind::WouldBlock.into())
			} else {
				Ok(written as usize)
			}
		})
	}

	fn flush(&mut self) -> io::Result<()> {
		Ok(())
	}
}

fn wide(text: &str) -> Vec<u16> {
	OsStr::new(text).encode_wide().chain(Some(NUL)).collect()
}

fn user_token() -> String {
	// The SID is stable across a rename and unique on a machine that is not
	// single-user. A short FNV-1a digest keeps the pipe name readable without
	// exposing the account identifier in a name another local process can list.
	sid()
		.map(|sid| format!("{:016x}", fnv(sid.as_bytes())))
		.or_else(|| std::env::var("USERNAME").ok())
		.map(|token| {
			token
				.chars()
				.filter(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.'))
				.take(24)
				.collect::<String>()
		})
		.filter(|token| !token.is_empty())
		.unwrap_or_else(|| "user".to_string())
}

fn fnv(bytes: &[u8]) -> u64 {
	let mut hash = 0xcbf2_9ce4_8422_2325u64;
	for byte in bytes {
		hash ^= u64::from(*byte);
		hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
	}
	hash
}

/// The current user's SID as text, or none when the token cannot be read.
fn sid() -> Option<String> {
	unsafe {
		let mut token: HANDLE = ptr::null_mut();
		if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
			return None;
		}

		let mut needed = 0u32;
		GetTokenInformation(token, TokenUser, ptr::null_mut(), 0, &mut needed);
		let mut buffer = vec![0u8; needed as usize];
		let read = GetTokenInformation(token, TokenUser, buffer.as_mut_ptr().cast(), needed, &mut needed);
		close(token);

		if read == 0 {
			return None;
		}

		let user = &*buffer.as_ptr().cast::<TOKEN_USER>();
		let mut text = ptr::null_mut();
		if ConvertSidToStringSidW(user.User.Sid, &mut text) == 0 {
			return None;
		}

		let mut length = 0usize;
		while *text.add(length) != 0 {
			length += 1;
		}
		let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, length));
		LocalFree(text.cast());
		Some(sid)
	}
}

unsafe fn close(handle: HANDLE) {
	unsafe {
		windows_sys::Win32::Foundation::CloseHandle(handle);
	}
}

/// Freed when it goes out of scope, which is after the last instance is created.
struct Descriptor(PSECURITY_DESCRIPTOR);

impl Descriptor {
	fn create() -> Result<Self> {
		let sddl = wide(OWNER_ONLY);
		let mut descriptor: PSECURITY_DESCRIPTOR = ptr::null_mut();
		let mut size = 0u32;

		let converted = unsafe {
			ConvertStringSecurityDescriptorToSecurityDescriptorW(
				sddl.as_ptr(),
				SDDL_REVISION_1,
				&mut descriptor,
				&mut size,
			)
		};

		if converted == 0 {
			return Err(Error::Io(std::io::Error::last_os_error()));
		}

		Ok(Self(descriptor))
	}
}

impl Drop for Descriptor {
	fn drop(&mut self) {
		unsafe {
			windows_sys::Win32::Foundation::LocalFree(self.0);
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn the_pipe_name_carries_the_machine_and_the_user() {
		let name = name("7f3c1a2b");

		assert!(name.starts_with(r"\\.\pipe\retype-7f3c1a2b-"));
	}

	#[test]
	fn a_user_token_is_never_empty_and_never_contains_a_separator() {
		let token = user_token();

		assert!(!token.is_empty());
		assert!(!token.contains('\\'));
	}
}
