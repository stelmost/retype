use std::ffi::c_void;
use std::fs::{self, File};
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::MetadataExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};

use windows_sys::Win32::Foundation::{ERROR_INSUFFICIENT_BUFFER, LocalFree};
use windows_sys::Win32::Security::Authorization::{
	ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo, SDDL_REVISION_1,
	SE_FILE_OBJECT,
};
use windows_sys::Win32::Security::{
	ACCESS_ALLOWED_ACE, ACE_HEADER, DACL_SECURITY_INFORMATION, EqualSid, GetAce, GetTokenInformation, INHERIT_ONLY_ACE,
	IsValidAcl, IsValidSid, IsWellKnownSid, OWNER_SECURITY_INFORMATION, PSID, SECURITY_ATTRIBUTES, TOKEN_QUERY,
	TOKEN_USER, TokenUser, WinBuiltinAdministratorsSid, WinCreatorOwnerSid, WinLocalSystemSid,
};
use windows_sys::Win32::Storage::FileSystem::{
	CreateDirectoryW, FILE_ATTRIBUTE_REPARSE_POINT, FILE_READ_ATTRIBUTES, READ_CONTROL,
};
use windows_sys::Win32::System::SystemServices::ACCESS_ALLOWED_ACE_TYPE;
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

struct LocalAllocation<T>(*mut T);

impl<T> Drop for LocalAllocation<T> {
	fn drop(&mut self) {
		if !self.0.is_null() {
			unsafe { LocalFree(self.0.cast()) };
		}
	}
}

struct UserSid(Vec<usize>);

impl UserSid {
	fn current() -> io::Result<Self> {
		let mut handle = null_mut();
		if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut handle) } == 0 {
			return Err(io::Error::last_os_error());
		}
		let token = unsafe { OwnedHandle::from_raw_handle(handle) };
		let mut size = 0;
		if unsafe { GetTokenInformation(token.as_raw_handle(), TokenUser, null_mut(), 0, &mut size) } == 0 {
			let error = io::Error::last_os_error();
			if error.raw_os_error() != Some(ERROR_INSUFFICIENT_BUFFER as i32) {
				return Err(error);
			}
		}
		let mut storage = vec![0usize; (size as usize).div_ceil(std::mem::size_of::<usize>())];
		if unsafe {
			GetTokenInformation(
				token.as_raw_handle(),
				TokenUser,
				storage.as_mut_ptr().cast(),
				size,
				&mut size,
			)
		} == 0
		{
			return Err(io::Error::last_os_error());
		}
		Ok(Self(storage))
	}

	fn sid(&self) -> PSID {
		unsafe { (*self.0.as_ptr().cast::<TOKEN_USER>()).User.Sid }
	}

	fn descriptor(&self) -> io::Result<LocalAllocation<c_void>> {
		security_descriptor(&format!("O:{0}D:P(A;OICI;FA;;;{0})", self.text()?))
	}

	fn text(&self) -> io::Result<String> {
		let mut text = LocalAllocation(null_mut());
		if unsafe { ConvertSidToStringSidW(self.sid(), &mut text.0) } == 0 {
			return Err(io::Error::last_os_error());
		}
		let length = (0..).find(|offset| unsafe { *text.0.add(*offset) == 0 }).unwrap();
		Ok(String::from_utf16_lossy(unsafe {
			std::slice::from_raw_parts(text.0, length)
		}))
	}
}

fn security_descriptor(sddl: &str) -> io::Result<LocalAllocation<c_void>> {
	let wide: Vec<_> = sddl.encode_utf16().chain([0]).collect();
	let mut descriptor = LocalAllocation(null_mut());
	if unsafe {
		ConvertStringSecurityDescriptorToSecurityDescriptorW(
			wide.as_ptr(),
			SDDL_REVISION_1,
			&mut descriptor.0,
			null_mut(),
		)
	} == 0
	{
		return Err(io::Error::last_os_error());
	}
	Ok(descriptor)
}

fn create_directory(path: &Path, descriptor: &LocalAllocation<c_void>) -> io::Result<()> {
	let path: Vec<_> = path.as_os_str().encode_wide().chain([0]).collect();
	if path[..path.len() - 1].contains(&0) {
		return Err(io::Error::new(
			io::ErrorKind::InvalidInput,
			"directory path contains a NUL",
		));
	}
	let attributes = SECURITY_ATTRIBUTES {
		nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
		lpSecurityDescriptor: descriptor.0,
		bInheritHandle: 0,
	};
	if unsafe { CreateDirectoryW(path.as_ptr(), &attributes) } == 0 {
		return Err(io::Error::last_os_error());
	}
	Ok(())
}

#[derive(Debug)]
pub struct StagingDirectory {
	path: PathBuf,
	guard: Option<File>,
}

impl StagingDirectory {
	pub fn path(&self) -> &Path {
		&self.path
	}

	pub fn keep(mut self) -> PathBuf {
		std::mem::take(&mut self.path)
	}
}

impl Drop for StagingDirectory {
	fn drop(&mut self) {
		drop(self.guard.take());
		if !self.path.as_os_str().is_empty() {
			let _ = fs::remove_dir_all(&self.path);
		}
	}
}

pub(crate) fn staging_directory(parent: &Path, prefix: &str) -> io::Result<StagingDirectory> {
	let native = fs::canonicalize(parent)?;
	let owner = UserSid::current()?;
	let descriptor = owner.descriptor()?;
	for _ in 0..10 {
		let mut random = [0; 16];
		getrandom::fill(&mut random).map_err(|error| io::Error::other(error.to_string()))?;
		let name = format!("{prefix}{:032x}", u128::from_ne_bytes(random));
		match create_directory(&native.join(&name), &descriptor) {
			Ok(()) => {
				let path = parent.join(name);
				let guard = super::open_directory(&path, READ_CONTROL | FILE_READ_ATTRIBUTES)?;
				super::check_directory(&guard)?;
				check_access(&guard, &owner)?;
				return Ok(StagingDirectory {
					path,
					guard: Some(guard),
				});
			}
			Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
			Err(error) => return Err(error),
		}
	}
	Err(io::Error::new(
		io::ErrorKind::AlreadyExists,
		"cannot allocate a private staging directory",
	))
}

pub(crate) fn ensure_state_directory(path: &Path) -> io::Result<()> {
	let absolute = std::path::absolute(path)?;
	let parent = absolute
		.parent()
		.ok_or_else(|| io::Error::other("state directory cannot be a volume root"))?;
	super::super::create_dir_all_durable(parent)?;
	let parent = super::Directory::open(parent)?;
	let owner = UserSid::current()?;
	let path = super::super::entry_path(&absolute)?;
	match create_directory(&path, &owner.descriptor()?) {
		Ok(()) => {
			check_state_tree(&path, &owner)?;
			super::Directory::open(&path)?.sync()?;
			parent.sync()
		}
		Err(error) if error.kind() == io::ErrorKind::AlreadyExists => check_state_tree(&path, &owner),
		Err(error) => Err(error),
	}
}

fn check_state_tree(path: &Path, owner: &UserSid) -> io::Result<()> {
	let file = super::open_directory(path, READ_CONTROL | FILE_READ_ATTRIBUTES)?;
	super::check_directory(&file)?;
	check_entry(path, &file, owner)
}

fn check_entry(path: &Path, file: &File, owner: &UserSid) -> io::Result<()> {
	let metadata = file.metadata()?;
	if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return Err(io::Error::new(
			io::ErrorKind::PermissionDenied,
			format!("state contains a reparse point: {}", path.display()),
		));
	}
	check_access(file, owner).map_err(|error| io::Error::new(error.kind(), format!("{}: {error}", path.display())))?;
	if metadata.is_dir() {
		for entry in fs::read_dir(path)? {
			let child = entry?.path();
			let file = super::open_directory(&child, READ_CONTROL | FILE_READ_ATTRIBUTES)?;
			check_entry(&child, &file, owner)?;
		}
	}
	Ok(())
}

pub(crate) fn require_private(file: &File) -> io::Result<()> {
	check_access(file, &UserSid::current()?)
}

fn check_access(file: &File, user: &UserSid) -> io::Result<()> {
	let mut owner = null_mut();
	let mut acl = null_mut();
	let mut descriptor = LocalAllocation(null_mut());
	let result = unsafe {
		GetSecurityInfo(
			file.as_raw_handle(),
			SE_FILE_OBJECT,
			OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
			&mut owner,
			null_mut(),
			&mut acl,
			null_mut(),
			&mut descriptor.0,
		)
	};
	if result != 0 {
		return Err(io::Error::from_raw_os_error(result as i32));
	}
	if owner.is_null() || acl.is_null() || unsafe { EqualSid(owner, user.sid()) == 0 || IsValidAcl(acl) == 0 } {
		return Err(shared());
	}
	for index in 0..unsafe { (*acl).AceCount } {
		let mut ace = null_mut();
		if unsafe { GetAce(acl, index.into(), &mut ace) } == 0 {
			return Err(io::Error::last_os_error());
		}
		if !unsafe { private_ace(ace, user.sid()) } {
			return Err(shared());
		}
	}
	Ok(())
}

unsafe fn private_ace(ace: *mut c_void, owner: PSID) -> bool {
	let header = unsafe { &*ace.cast::<ACE_HEADER>() };
	let offset = std::mem::offset_of!(ACCESS_ALLOWED_ACE, SidStart);
	if u32::from(header.AceType) != ACCESS_ALLOWED_ACE_TYPE || usize::from(header.AceSize) < offset + 8 {
		return false;
	}
	let sid = unsafe { ace.cast::<u8>().add(offset) };
	let size = 8 + 4 * usize::from(unsafe { *sid.add(1) });
	if usize::from(header.AceSize) < offset + size || unsafe { IsValidSid(sid.cast()) } == 0 {
		return false;
	}
	let sid = sid.cast();
	unsafe {
		EqualSid(sid, owner) != 0
			|| IsWellKnownSid(sid, WinLocalSystemSid) != 0
			|| IsWellKnownSid(sid, WinBuiltinAdministratorsSid) != 0
			|| (u32::from(header.AceFlags) & INHERIT_ONLY_ACE != 0 && IsWellKnownSid(sid, WinCreatorOwnerSid) != 0)
	}
}

fn shared() -> io::Error {
	io::Error::new(
		io::ErrorKind::PermissionDenied,
		"Windows permissions do not establish private ownership",
	)
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn staging_and_new_state_refuse_shared_parent_inheritance() {
		let root = tempfile::tempdir().unwrap();
		let shared = fs::canonicalize(root.path()).unwrap().join("shared");
		let owner = UserSid::current().unwrap().text().unwrap();
		let broad = security_descriptor(&format!("O:{owner}D:P(A;OICI;FA;;;{owner})(A;OICI;GRGW;;;WD)")).unwrap();
		create_directory(&shared, &broad).unwrap();
		let stage = staging_directory(&shared, ".private.").unwrap();
		let child = stage.path().join("child");
		fs::write(&child, b"private").unwrap();
		require_private(&File::open(&child).unwrap()).unwrap();

		let state = shared.join("state");
		ensure_state_directory(&state).unwrap();
		fs::write(state.join("private"), b"state").unwrap();
		ensure_state_directory(&state).unwrap();
		let inherited = shared.join("inherited");
		fs::create_dir(&inherited).unwrap();
		assert_eq!(
			ensure_state_directory(&inherited).unwrap_err().kind(),
			io::ErrorKind::PermissionDenied
		);
		let source = shared.join("source");
		fs::write(&source, b"retain shared source").unwrap();
		let expected = crate::safety::Fingerprint::of(&source).unwrap();
		assert!(crate::safety::remove_owned(&source, &expected).is_err());
		assert_eq!(fs::read(&source).unwrap(), b"retain shared source");

		let exposed_child = state.join("exposed");
		create_directory(&exposed_child, &broad).unwrap();
		assert_eq!(
			ensure_state_directory(&state).unwrap_err().kind(),
			io::ErrorKind::PermissionDenied
		);
	}
}
