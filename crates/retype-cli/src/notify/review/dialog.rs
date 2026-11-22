use std::io;
use std::process::{Command, Stdio};
use std::time::Duration;

use super::super::wait_for_helper;

const UNDO_RESPONSE: i32 = 42;

#[cfg(unix)]
fn ordinary_local_user() -> bool {
	let uid = unsafe { libc::getuid() };
	uid != 0
		&& uid == unsafe { libc::geteuid() }
		&& ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"]
			.iter()
			.all(|key| std::env::var_os(key).is_none())
}

#[cfg(target_os = "linux")]
const ZENITY: &str = "/usr/bin/zenity";

#[cfg(target_os = "linux")]
fn has_display() -> bool {
	["WAYLAND_DISPLAY", "DISPLAY"]
		.iter()
		.any(|name| std::env::var_os(name).is_some_and(|value| !value.is_empty()))
}

#[cfg(target_os = "linux")]
pub(in crate::notify) fn batch_available() -> bool {
	has_display() && super::super::has_command("zenity")
}

#[cfg(target_os = "linux")]
pub(in crate::notify) fn local_desktop() -> bool {
	use std::path::Path;

	if !ordinary_local_user() || !has_display() || !Path::new(ZENITY).is_file() {
		return false;
	}
	/* `auto` finds this process's session or its user's graphical session under the user manager. */
	let args = [
		"--no-pager",
		"--no-ask-password",
		"show-session",
		"auto",
		"-pUser",
		"-pClass",
		"-pType",
		"-pState",
		"-pRemote",
	]
	.map(Into::into);
	let timeout = retype_core::execute::Cancellation::default().bounded(Duration::from_secs(2));
	let loginctl = Path::new("/usr/bin/loginctl");
	retype_core::execute::run_child_output("loginctl", loginctl, &args, &timeout, 4096)
		.is_ok_and(|session| local_graphical_session(&session, unsafe { libc::geteuid() }))
}

#[cfg(target_os = "linux")]
fn local_graphical_session(session: &str, uid: u32) -> bool {
	let field = |key| session.lines().find_map(|line| line.strip_prefix(key));
	field("User=").and_then(|value| value.parse::<u32>().ok()) == Some(uid)
		&& matches!(field("Class="), Some("user" | "user-early"))
		&& matches!(field("Type="), Some("wayland" | "x11"))
		&& field("State=") == Some("active")
		&& field("Remote=") == Some("no")
}

#[cfg(target_os = "macos")]
pub(in crate::notify) fn local_desktop() -> bool {
	use std::os::unix::fs::MetadataExt;

	/* The bundled helper also checks its own active WindowServer session. */
	ordinary_local_user()
		&& std::fs::metadata("/dev/console").is_ok_and(|console| console.uid() == unsafe { libc::geteuid() })
}

#[cfg(windows)]
pub(in crate::notify) fn local_desktop() -> bool {
	use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};

	use windows_sys::Win32::Security::{GetTokenInformation, TOKEN_ELEVATION, TOKEN_QUERY, TokenElevation};
	use windows_sys::Win32::System::RemoteDesktop::{ProcessIdToSessionId, WTSGetActiveConsoleSessionId};
	use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

	let mut session = 0;
	if unsafe { ProcessIdToSessionId(std::process::id(), &mut session) } == 0
		|| session == 0
		|| session != unsafe { WTSGetActiveConsoleSessionId() }
	{
		return false;
	}
	let mut token = std::ptr::null_mut();
	if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
		return false;
	}
	let token = unsafe { OwnedHandle::from_raw_handle(token) };
	let mut elevation = TOKEN_ELEVATION { TokenIsElevated: 0 };
	let mut returned = 0;
	let size = size_of::<TOKEN_ELEVATION>() as u32;
	let read = unsafe {
		GetTokenInformation(
			token.as_raw_handle(),
			TokenElevation,
			(&raw mut elevation).cast(),
			size,
			&mut returned,
		)
	};
	/* The WinForms helper additionally checks the active input desktop. */
	read != 0 && returned == size && elevation.TokenIsElevated == 0
}

#[cfg(windows)]
pub(in crate::notify) fn windows_powershell() -> Option<std::path::PathBuf> {
	use std::os::windows::ffi::OsStringExt;
	use windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW;

	let mut directory = [0u16; 260];
	let size = unsafe { GetSystemDirectoryW(directory.as_mut_ptr(), directory.len() as u32) } as usize;
	if size == 0 || size >= directory.len() {
		return None;
	}
	let path = std::path::PathBuf::from(std::ffi::OsString::from_wide(&directory[..size]))
		.join(r"WindowsPowerShell\v1.0\powershell.exe");
	path.is_file().then_some(path)
}

#[cfg(target_os = "linux")]
pub(super) fn show(text: &str, undo_label: Option<&str>) -> io::Result<bool> {
	zenity(ZENITY, text, undo_label)
}

#[cfg(target_os = "linux")]
pub(super) fn show_batch(text: &str, undo_label: Option<&str>) -> io::Result<bool> {
	zenity("zenity", text, undo_label)
}

#[cfg(target_os = "linux")]
fn zenity(program: &str, text: &str, undo_label: Option<&str>) -> io::Result<bool> {
	let mut command = Command::new(program);
	command.args(["--title=retype Review", "--no-markup", "--timeout=60", "--text", text]);
	if let Some(label) = undo_label {
		command.args([
			"--question",
			"--default-cancel",
			"--cancel-label=Close",
			"--ok-label",
			label,
		]);
	} else {
		command.args(["--info", "--ok-label=Close"]);
	}
	/* Debian 13 Zenity maps Yes to ZENITY_OK; ordinary exit 0 does not authorize an Undo. */
	command.env("ZENITY_OK", UNDO_RESPONSE.to_string()).envs([
		("ZENITY_CANCEL", "1"),
		("ZENITY_ESC", "1"),
		("ZENITY_ERROR", "255"),
		("ZENITY_TIMEOUT", "5"),
	]);
	let status = dialog_status(command)?;
	match status.code() {
		Some(UNDO_RESPONSE) => Ok(undo_label.is_some()),
		Some(1 | 5) => Ok(false),
		Some(0) if undo_label.is_none() => Ok(false),
		_ => Err(io::Error::other(format!("zenity exited {status}"))),
	}
}

#[cfg(target_os = "macos")]
pub(super) fn show(text: &str, undo_label: Option<&str>) -> io::Result<bool> {
	let helper = super::super::installed_macos_notifier()
		.ok_or_else(|| io::Error::other("Review requires the installed macOS notifier"))?;
	let mut command = Command::new(helper);
	command.args(["review", text]).args(undo_label);
	decision(command, undo_label)
}

#[cfg(windows)]
pub(super) fn show(text: &str, undo_label: Option<&str>) -> io::Result<bool> {
	let helper = windows_powershell().ok_or_else(|| io::Error::other("system PowerShell is unavailable"))?;
	let script = include_str!("../../../../../packaging/windows/review.ps1");
	let mut command = Command::new(helper);
	command
		.args(["-NoLogo", "-STA", "-NoProfile", "-NonInteractive", "-EncodedCommand"])
		.arg(super::super::encoded_command(script))
		.env("RETYPE_REVIEW_TEXT", text)
		.env("RETYPE_REVIEW_UNDO_LABEL", undo_label.unwrap_or_default());
	retype_core::process::hide_console(&mut command);
	decision(command, undo_label)
}

#[cfg(any(target_os = "macos", windows))]
fn decision(command: Command, undo_label: Option<&str>) -> io::Result<bool> {
	let status = dialog_status(command)?;
	match status.code() {
		Some(UNDO_RESPONSE) => Ok(undo_label.is_some()),
		Some(0) => Ok(false),
		_ => Err(io::Error::other(format!(
			"native Review unavailable: helper exited {status}"
		))),
	}
}

fn dialog_status(mut command: Command) -> io::Result<std::process::ExitStatus> {
	let child = command
		.stdin(Stdio::null())
		.stdout(Stdio::null())
		.stderr(Stdio::null())
		.spawn()?;
	wait_for_helper(child, Duration::from_secs(65), "review dialog")
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
	use super::local_graphical_session;

	#[test]
	fn review_needs_an_active_graphical_login_owned_by_this_user() {
		let login = "User=1000\nClass=user\nType=wayland\nState=active\nRemote=no\n";
		assert!(local_graphical_session(login, 1000));
		assert!(!local_graphical_session(login, 1001));
		for (field, invalid) in [
			("wayland", "tty"),
			("active", "online"),
			("Remote=no", "Remote=yes"),
			("Class=user", "Class=greeter"),
		] {
			assert!(!local_graphical_session(&login.replace(field, invalid), 1000));
		}
		assert!(!local_graphical_session("User=1000\nType=wayland\n", 1000));
	}
}
