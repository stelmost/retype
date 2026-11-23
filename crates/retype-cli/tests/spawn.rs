//! The binary end to end, which is the only way to test auto-start: start a
//! daemon, ask it something, stop it.

use std::path::{Path, PathBuf};
use std::process::Command;

fn retype() -> Command {
	Command::new(env!("CARGO_BIN_EXE_retype"))
}

/// Stops the daemon when the test ends, including when it fails.
struct Daemon {
	state: PathBuf,
}

impl Daemon {
	fn start(state: &Path) -> Self {
		let output = retype()
			.arg("daemon")
			.arg("start")
			.arg("--state-dir")
			.arg(state)
			.arg("--json")
			.output()
			.unwrap();

		assert!(
			output.status.success(),
			"daemon start failed: {}",
			String::from_utf8_lossy(&output.stderr)
		);

		Self {
			state: state.to_path_buf(),
		}
	}
}

impl Drop for Daemon {
	fn drop(&mut self) {
		let _ = retype()
			.arg("daemon")
			.arg("stop")
			.arg("--state-dir")
			.arg(&self.state)
			.output();
	}
}

#[test]
fn the_binary_starts_a_daemon_and_stops_it() {
	let dir = tempfile::tempdir().unwrap();
	let daemon = Daemon::start(dir.path());

	let status = retype()
		.args(["daemon", "status"])
		.arg("--state-dir")
		.arg(dir.path())
		.arg("--json")
		.output()
		.unwrap();
	assert!(status.status.success(), "{}", String::from_utf8_lossy(&status.stderr));

	let value: serde_json::Value = serde_json::from_slice(&status.stdout).unwrap();
	assert!(value["pid"].as_u64().unwrap() > 0);
	assert_eq!(value["jobs"], 0);
	assert!(
		dir.path().join("endpoint").exists(),
		"the daemon published where it listens"
	);

	let stop = retype()
		.args(["daemon", "stop"])
		.arg("--state-dir")
		.arg(dir.path())
		.output()
		.unwrap();
	assert!(stop.status.success(), "{}", String::from_utf8_lossy(&stop.stderr));
	assert!(
		!dir.path().join("endpoint").exists(),
		"a stopped daemon leaves no endpoint"
	);

	drop(daemon);
}

#[cfg(unix)]
#[test]
fn a_disconnected_client_does_not_terminate_the_real_daemon() {
	use std::net::Shutdown;
	use std::os::unix::net::UnixStream;
	use std::time::Duration;

	let dir = tempfile::tempdir().unwrap();
	let daemon = Daemon::start(dir.path());
	let endpoint = retype_cli::state::read_endpoint(dir.path()).unwrap();
	for _ in 0..5 {
		let mut stream = UnixStream::connect(&endpoint).unwrap();
		let hello = retype_ipc::Request::new(1, "hello")
			.with_params(retype_ipc::Hello {
				ipc: retype_ipc::IPC_VERSION.to_string(),
				client: "disconnect-test".to_string(),
				features: Vec::new(),
			})
			.unwrap();
		retype_ipc::write_frame(&mut stream, &hello).unwrap();
		stream.shutdown(Shutdown::Both).unwrap();
		drop(stream);
		std::thread::sleep(Duration::from_millis(50));
		let status = retype()
			.args(["daemon", "status", "--no-spawn"])
			.arg("--state-dir")
			.arg(dir.path())
			.output()
			.unwrap();
		assert!(status.status.success(), "{}", String::from_utf8_lossy(&status.stderr));
	}
	drop(daemon);
}

#[cfg(unix)]
#[test]
fn a_foreground_process_group_interrupt_does_not_stop_the_spawned_daemon() {
	use std::os::unix::process::CommandExt;
	use std::process::Stdio;
	use std::time::{Duration, Instant};

	let dir = tempfile::tempdir().unwrap();
	let daemon = Daemon {
		state: dir.path().to_path_buf(),
	};
	let mut shell = Command::new("sh");
	shell
		.args([
			"-c",
			"\"$RETYPE\" daemon start --state-dir \"$STATE\" && : > \"$STATE/foreground-ready\"; exec sleep 30",
		])
		.env("RETYPE", env!("CARGO_BIN_EXE_retype"))
		.env("STATE", dir.path())
		.env_remove("RETYPE_NO_SPAWN")
		.stdout(Stdio::null())
		.stderr(Stdio::null())
		.process_group(0);
	let mut foreground = shell.spawn().unwrap();
	let deadline = Instant::now() + Duration::from_secs(8);
	while !dir.path().join("foreground-ready").exists() && Instant::now() < deadline {
		std::thread::sleep(Duration::from_millis(20));
	}
	if !dir.path().join("foreground-ready").exists() {
		let _ = foreground.kill();
		let _ = foreground.wait();
		panic!("the detached daemon did not start");
	}

	// The shell keeps this group alive after its `daemon start` command returns.
	assert_eq!(unsafe { libc::kill(-(foreground.id() as i32), libc::SIGINT) }, 0);
	let deadline = Instant::now() + Duration::from_secs(3);
	while foreground.try_wait().unwrap().is_none() {
		if Instant::now() >= deadline {
			let _ = foreground.kill();
			let _ = foreground.wait();
			panic!("the foreground process did not stop after SIGINT");
		}
		std::thread::sleep(Duration::from_millis(20));
	}
	std::thread::sleep(Duration::from_millis(200));
	let status = retype()
		.args(["daemon", "status", "--no-spawn"])
		.arg("--state-dir")
		.arg(dir.path())
		.output()
		.unwrap();
	assert!(status.status.success(), "{}", String::from_utf8_lossy(&status.stderr));
	drop(daemon);
}

#[cfg(unix)]
#[test]
fn startup_retries_a_child_that_lost_the_shutdown_lock_handoff() {
	use std::os::fd::AsRawFd;
	use std::time::{Duration, Instant};

	let dir = tempfile::tempdir().unwrap();
	let state = dir.path().join("state");
	std::fs::create_dir(&state).unwrap();
	let config = dir.path().join("retype.toml");
	std::fs::write(&config, "version = 'retype-config-1'\n[notify]\nenabled = false\n").unwrap();
	let held = std::fs::File::create(state.join("lock")).unwrap();
	assert_eq!(
		unsafe { libc::flock(held.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
		0
	);
	let context = retype_client::Context::new(&state)
		.unwrap()
		.with_daemon(retype_client::Daemon::at(env!("CARGO_BIN_EXE_retype")))
		.with_config(Some(config));
	let _cleanup = Daemon { state: state.clone() };
	let mut spawned = retype_client::spawn_detached(&context).unwrap();
	let deadline = Instant::now() + Duration::from_secs(3);
	while !std::fs::read_to_string(state.join("daemon.log"))
		.unwrap_or_default()
		.contains("another daemon owns")
	{
		assert!(Instant::now() < deadline, "child did not encounter the held lock");
		std::thread::sleep(Duration::from_millis(10));
	}
	drop(held);
	let mut client = retype_client::wait_for(&context, &mut spawned).unwrap();
	assert!(client.status().unwrap().pid > 0);
}

#[cfg(unix)]
fn refuse_greeting(listener: &std::os::unix::net::UnixListener) {
	use retype_core::error::Code;
	use std::io::BufReader;
	use std::time::{Duration, Instant};

	let deadline = Instant::now() + Duration::from_secs(5);
	listener.set_nonblocking(true).unwrap();
	let mut stream = loop {
		match listener.accept() {
			Ok((stream, _)) => break stream,
			Err(error) if error.kind() == std::io::ErrorKind::WouldBlock && Instant::now() < deadline => {
				std::thread::sleep(Duration::from_millis(5));
			}
			Err(error) => panic!("client did not connect: {error}"),
		}
	};
	stream.set_nonblocking(false).unwrap();
	stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
	let request = retype_ipc::read_frame(&mut BufReader::new(&stream)).unwrap().unwrap();
	assert_eq!(request["method"], "hello");
	let response = retype_ipc::Response::error(
		request["id"].as_u64().unwrap(),
		retype_ipc::WireError::new(Code::IpcVersion, "this daemon speaks retype-ipc-2"),
	);
	retype_ipc::write_frame(&mut stream, &response).unwrap();
}

#[cfg(unix)]
#[test]
fn cli_reports_an_existing_daemons_protocol_refusal_without_starting_again() {
	use std::os::unix::net::UnixListener;

	let dir = tempfile::tempdir().unwrap();
	let endpoint = retype_cli::state::socket_path(dir.path()).unwrap();
	let listener = UnixListener::bind(&endpoint).unwrap();
	retype_cli::state::publish_endpoint(dir.path(), endpoint.to_str().unwrap()).unwrap();
	for args in [&["status"][..], &["status", "--no-spawn"], &["start"]] {
		std::thread::scope(|scope| {
			let daemon = scope.spawn(|| refuse_greeting(&listener));
			let output = retype()
				.arg("daemon")
				.args(args)
				.arg("--state-dir")
				.arg(dir.path())
				.arg("--json")
				.env_remove("RETYPE_NO_SPAWN")
				.output()
				.unwrap();
			daemon.join().unwrap();
			assert!(!output.status.success(), "{output:?}");
			let answer: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
			assert_eq!(answer["error"]["code"], "E_IPC_VERSION", "{answer}");
			assert_eq!(answer["error"]["message"], "this daemon speaks retype-ipc-2");
			assert!(!dir.path().join("daemon.log").exists());
			assert!(!dir.path().join("lifecycle.json").exists());
		});
	}
}

#[cfg(unix)]
#[test]
fn startup_reports_the_protocol_refusal_of_a_daemon_that_wins_the_race() {
	use std::os::unix::net::UnixListener;

	let dir = tempfile::tempdir().unwrap();
	let endpoint = retype_cli::state::socket_path(dir.path()).unwrap();
	let listener = UnixListener::bind(&endpoint).unwrap();
	let context = retype_client::Context::new(dir.path())
		.unwrap()
		.with_daemon(retype_client::Daemon::at("true"));
	let mut spawned = retype_client::spawn_detached(&context).unwrap();
	retype_cli::state::publish_endpoint(dir.path(), endpoint.to_str().unwrap()).unwrap();
	std::thread::scope(|scope| {
		let daemon = scope.spawn(|| refuse_greeting(&listener));
		let error = retype_client::wait_for(&context, &mut spawned).unwrap_err();
		daemon.join().unwrap();
		assert_eq!(error.code(), retype_core::error::Code::IpcVersion);
	});
}

#[test]
fn starting_twice_is_not_an_error() {
	let dir = tempfile::tempdir().unwrap();
	let daemon = Daemon::start(dir.path());

	let again = retype()
		.args(["daemon", "start"])
		.arg("--state-dir")
		.arg(dir.path())
		.output()
		.unwrap();

	assert!(again.status.success(), "{}", String::from_utf8_lossy(&again.stderr));

	drop(daemon);
}

#[test]
fn status_shows_the_config_path_selected_by_the_daemon() {
	let dir = tempfile::tempdir().unwrap();
	let work = dir.path().join("daemon working directory");
	std::fs::create_dir(&work).unwrap();
	let config = work.join("selected.toml");
	std::fs::write(&config, "version = 'retype-config-1'\n[notify]\nenabled = false\n").unwrap();
	let state = dir.path().join("state");
	let _daemon = Daemon { state: state.clone() };
	let started = retype()
		.args(["daemon", "start", "--config", "selected.toml", "--state-dir"])
		.arg(&state)
		.current_dir(&work)
		.output()
		.unwrap();
	assert!(started.status.success(), "{started:?}");
	let report = retype()
		.args(["daemon", "status", "--no-spawn", "--json", "--state-dir"])
		.arg(&state)
		.current_dir(dir.path())
		.env("RETYPE_CONFIG", "other.toml")
		.output()
		.unwrap();
	assert!(report.status.success(), "{report:?}");
	let status: retype_ipc::Status = serde_json::from_slice(&report.stdout).unwrap();
	let selected = status.config_path.unwrap();
	assert!(selected.is_absolute(), "{selected:?}");
	assert_eq!(selected.canonicalize().unwrap(), config.canonicalize().unwrap());
}

#[test]
fn suppressed_spawn_reports_the_daemon_missing() {
	let dir = tempfile::tempdir().unwrap();

	let output = retype()
		.args(["daemon", "status"])
		.arg("--state-dir")
		.arg(dir.path())
		.env("RETYPE_NO_SPAWN", "1")
		.output()
		.unwrap();

	assert_eq!(output.status.code(), Some(6));
	assert!(String::from_utf8_lossy(&output.stderr).contains("not running"));
}

#[test]
fn no_spawn_is_honoured_on_the_command_line() {
	let dir = tempfile::tempdir().unwrap();

	let output = retype()
		.args(["daemon", "status", "--no-spawn"])
		.arg("--state-dir")
		.arg(dir.path())
		.output()
		.unwrap();

	assert_eq!(output.status.code(), Some(6));
}
