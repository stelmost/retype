//! Real pseudo-terminal input, without a graphical desktop or a real login claim.
#![cfg(target_os = "linux")]
use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

struct Fixture {
	root: tempfile::TempDir,
	state: std::path::PathBuf,
	config: std::path::PathBuf,
	job: String,
	child: Option<Child>,
	terminal: Option<File>,
}
impl Fixture {
	fn new() -> Self {
		let root = tempfile::tempdir().unwrap();
		let state = root.path().join("state");
		let config = root.path().join("config.toml");
		fs::write(&config, "version = 'retype-config-1'\n[notify]\nenabled = false\n").unwrap();
		let job = Self::park(&state, &config, &root.path().join("original.tar"));
		Self {
			root,
			state,
			config,
			job,
			child: None,
			terminal: None,
		}
	}
	fn park(state: &Path, config: &Path, source: &Path) -> String {
		let mut tar = tar::Builder::new(File::create(source).unwrap());
		let mut header = tar::Header::new_gnu();
		header.set_size(7);
		header.set_mode(0o600);
		header.set_mtime(1);
		header.set_cksum();
		tar.append_data(&mut header, "entry", &b"payload"[..]).unwrap();
		tar.finish().unwrap();
		drop(tar);
		let output = Command::new(env!("CARGO_BIN_EXE_retype"))
			.arg("convert")
			.arg(source)
			.args(["zip+ask", "--json", "--state-dir"])
			.arg(state)
			.env("RETYPE_CONFIG", config)
			.env("RETYPE_TEST_SESSION", "terminal")
			.stdin(Stdio::null())
			.output()
			.unwrap();
		assert_eq!(output.status.code(), Some(7), "{output:?}");
		let answer: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
		answer["error"]["detail"]["id"].as_str().unwrap().to_string()
	}
	fn start(&mut self, options: &[&str]) {
		let mut command = Command::new(env!("CARGO_BIN_EXE_retype"));
		command.arg("watch").arg(self.root.path()).args(options);
		self.start_command(command);
	}
	fn start_command(&mut self, mut command: Command) {
		let (mut master, mut slave) = (-1, -1);
		assert_eq!(
			unsafe {
				libc::openpty(
					&mut master,
					&mut slave,
					std::ptr::null_mut(),
					std::ptr::null(),
					std::ptr::null(),
				)
			},
			0
		);
		let terminal = unsafe { File::from_raw_fd(master) };
		let slave = unsafe { File::from_raw_fd(slave) };
		command
			.arg("--state-dir")
			.arg(&self.state)
			.env("RETYPE_CONFIG", &self.config)
			.env("RETYPE_TEST_SESSION", "terminal")
			.env_remove("RETYPE_NO_SPAWN")
			.stdin(slave.try_clone().unwrap())
			.stdout(slave.try_clone().unwrap())
			.stderr(slave);
		unsafe {
			command.pre_exec(move || {
				if libc::setsid() < 0 {
					return Err(std::io::Error::last_os_error());
				}
				if libc::ioctl(libc::STDIN_FILENO, libc::TIOCSCTTY, 0) < 0 {
					return Err(std::io::Error::last_os_error());
				}
				Ok(())
			});
		}
		self.child = Some(command.spawn().unwrap());
		unsafe {
			libc::fcntl(terminal.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK);
		}
		self.terminal = Some(terminal);
		self.wait_for_prompt();
	}
	fn wait_for_prompt(&mut self) {
		let deadline = Instant::now() + Duration::from_secs(10);
		let mut output = String::new();
		while !output.contains("[n]ow") {
			let mut buffer = [0; 4096];
			match self.terminal.as_mut().unwrap().read(&mut buffer) {
				Ok(count) => output.push_str(&String::from_utf8_lossy(&buffer[..count])),
				Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
				other => panic!("terminal failed: {other:?}; {output}"),
			}
			assert!(
				self.child.as_mut().unwrap().try_wait().unwrap().is_none(),
				"command exited: {output}"
			);
			assert!(Instant::now() < deadline, "prompt did not appear: {output}");
			std::thread::sleep(Duration::from_millis(20));
		}
	}
	fn detach(&mut self) {
		self.terminal.as_mut().unwrap().write_all(&[3]).unwrap();
		let deadline = Instant::now() + Duration::from_secs(5);
		loop {
			if let Some(status) = self.child.as_mut().unwrap().try_wait().unwrap() {
				assert!(status.success());
				break;
			}
			assert!(Instant::now() < deadline, "interrupt did not detach during a prompt");
			std::thread::sleep(Duration::from_millis(20));
		}
	}
}
impl Drop for Fixture {
	fn drop(&mut self) {
		if let Some(child) = &mut self.child {
			let _ = child.kill();
			let _ = child.wait();
		}
		if let Ok(mut client) = retype_cli::client::connect(&self.state) {
			let _ = client.shutdown(&retype_ipc::ShutdownRequest { now: true, force: true });
		}
		retype_cli::client::wait_for_stop(&self.state, Duration::from_secs(3));
	}
}

#[test]
fn interrupt_during_a_real_prompt_detaches_and_preserves_the_pending_ask() {
	let mut fixture = Fixture::new();
	fixture.start(&["--no-spawn"]);
	fixture.detach();
	let job = retype_cli::client::connect(&fixture.state)
		.unwrap()
		.jobs_get(&fixture.job)
		.unwrap();
	assert_eq!(job.state, retype_core::job::JobState::NeedsAttention);
	assert!(!fixture.root.path().join("original.zip").exists());
}

#[test]
fn terminal_eof_is_not_consent_and_stale_prompt_does_not_resolve_twice() {
	let mut fixture = Fixture::new();
	fixture.start(&["--no-spawn"]);
	fixture.terminal.as_mut().unwrap().write_all(&[4]).unwrap();
	std::thread::sleep(Duration::from_millis(100));
	assert_eq!(
		retype_cli::client::connect(&fixture.state)
			.unwrap()
			.jobs_get(&fixture.job)
			.unwrap()
			.state,
		retype_core::job::JobState::NeedsAttention
	);
	fixture.detach();

	let mut fixture = Fixture::new();
	fixture.start(&["--no-spawn"]);
	retype_cli::client::connect(&fixture.state)
		.unwrap()
		.jobs_cancel(&fixture.job)
		.unwrap();
	fixture.terminal.as_mut().unwrap().write_all(b"n\n").unwrap();
	std::thread::sleep(Duration::from_millis(100));
	assert!(!fixture.root.path().join("original.zip").exists());
	assert!(fixture.child.as_mut().unwrap().try_wait().unwrap().is_none());
	fixture.detach();
}

#[test]
fn a_crash_during_a_prompt_refreshes_without_replaying_the_answer() {
	let mut fixture = Fixture::new();
	fixture.start(&[]);
	let pid = retype_cli::client::connect(&fixture.state)
		.unwrap()
		.status()
		.unwrap()
		.pid;
	assert_eq!(unsafe { libc::kill(pid as i32, libc::SIGKILL) }, 0);
	fixture.terminal.as_mut().unwrap().write_all(b"n\n").unwrap();
	fixture.wait_for_prompt();

	let mut client = retype_cli::client::connect(&fixture.state).unwrap();
	assert_ne!(client.status().unwrap().pid, pid);
	let job = client.jobs_get(&fixture.job).unwrap();
	assert_eq!(job.state, retype_core::job::JobState::NeedsAttention);
	assert!(fixture.root.path().join("original.tar").is_file());
	assert!(!fixture.root.path().join("original.zip").exists());
	fixture.detach();
}

#[test]
fn a_stale_parked_decision_cannot_cancel_or_resolve_the_current_job() {
	let fixture = Fixture::new();
	let mut client = retype_cli::client::connect(&fixture.state).unwrap();
	let job = client.jobs_get(&fixture.job).unwrap();
	let previous = Some(retype_ipc::ParkedVersion {
		state: job.state,
		updated: job.updated - 1,
	});
	assert_eq!(
		client.jobs_cancel_matching(&fixture.job, previous).unwrap_err().code(),
		Some(&retype_core::error::Code::JobState)
	);
	assert_eq!(
		client
			.jobs_resolve_matching(&fixture.job, retype_ipc::ResolveMode::Now, false, previous)
			.unwrap_err()
			.code(),
		Some(&retype_core::error::Code::JobState)
	);
	assert_eq!(client.jobs_get(&fixture.job).unwrap(), job);
}

#[test]
fn standalone_prompt_refreshes_the_parked_list_after_a_stale_answer() {
	use retype_core::job::JobState;

	let mut fixture = Fixture::new();
	let mut command = Command::new(env!("CARGO_BIN_EXE_retype"));
	command.args(["jobs", "--interactive", "--no-spawn"]);
	fixture.start_command(command);
	let second = Fixture::park(&fixture.state, &fixture.config, &fixture.root.path().join("second.tar"));
	let mut client = retype_cli::client::connect(&fixture.state).unwrap();
	client.jobs_cancel(&fixture.job).unwrap();
	drop(client);

	fixture.terminal.as_mut().unwrap().write_all(b"n\n").unwrap();
	fixture.wait_for_prompt();
	let mut client = retype_cli::client::connect(&fixture.state).unwrap();
	assert_eq!(client.jobs_get(&fixture.job).unwrap().state, JobState::Cancelled);
	assert_eq!(client.jobs_get(&second).unwrap().state, JobState::NeedsAttention);
	assert!(!fixture.root.path().join("second.zip").exists());
}
