//! Ordinary Windows clients against an isolated daemon and pipe.

#![cfg(windows)]

use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

use retype_core::job::{Job, JobError, Source};
use retype_ipc::{Client, Hello, IPC_VERSION, Request, read_frame, write_frame};

const WAIT: Duration = Duration::from_secs(6);
const TICK: Duration = Duration::from_millis(20);

struct Daemon {
	child: Child,
	directory: Option<tempfile::TempDir>,
	endpoint: PathBuf,
}

impl Daemon {
	fn start(job: Option<Job>) -> Self {
		let directory = tempfile::Builder::new()
			.prefix("retype-pipe-progress-")
			.tempdir()
			.unwrap();
		let state = directory.path().join("state");
		let config = directory.path().join("config.toml");
		fs::create_dir(&state).unwrap();
		fs::write(&config, "version = 'retype-config-1'\n[notify]\nenabled = false\n").unwrap();
		if let Some(job) = job {
			fs::write(state.join("jobs.jsonl"), format!("{}\n", job.to_line().unwrap())).unwrap();
		}
		let child = Command::new(env!("CARGO_BIN_EXE_retype"))
			.args(["daemon", "--detached", "--state-dir"])
			.arg(&state)
			.env("RETYPE_CONFIG", config)
			.env("RETYPE_TEST_SESSION", "terminal")
			.stdin(Stdio::null())
			.stdout(Stdio::null())
			.stderr(File::create(directory.path().join("daemon.log")).unwrap())
			.spawn()
			.unwrap();
		let mut daemon = Self {
			child,
			directory: Some(directory),
			endpoint: PathBuf::new(),
		};
		let deadline = Instant::now() + WAIT;
		while let Err(error) =
			retype_cli::state::read_endpoint(&state).map(|endpoint| daemon.endpoint = endpoint.into())
		{
			assert!(
				daemon.child.try_wait().unwrap().is_none(),
				"daemon exited before publishing its endpoint"
			);
			assert!(Instant::now() < deadline, "daemon endpoint unavailable: {error}");
			std::thread::sleep(TICK);
		}
		let _ready = daemon.client();
		daemon
	}

	fn client(&self) -> Client {
		let mut client = Client::connect(&self.endpoint).unwrap();
		assert_eq!(client.hello("pipe progress fixture").unwrap().pid, self.child.id());
		client
	}

	fn pipe(&self) -> File {
		let deadline = Instant::now() + Duration::from_secs(1);
		loop {
			match OpenOptions::new().read(true).write(true).open(&self.endpoint) {
				Ok(pipe) => return pipe,
				Err(error) => assert!(Instant::now() < deadline, "cannot open another peer: {error}"),
			}
			std::thread::sleep(TICK);
		}
	}

	fn stop(&mut self, mut client: Client) {
		let response = client.call("shutdown", serde_json::json!({"force": true})).unwrap();
		assert_eq!(response["stopping"], true);
		drop(client);
		assert!(self.exit_status(WAIT).unwrap().expect("daemon did not drain").success());
	}

	fn exit_status(&mut self, timeout: Duration) -> io::Result<Option<ExitStatus>> {
		let deadline = Instant::now() + timeout;
		loop {
			if let Some(status) = self.child.try_wait()? {
				return Ok(Some(status));
			}
			if Instant::now() >= deadline {
				return Ok(None);
			}
			std::thread::sleep(TICK);
		}
	}
}

impl Drop for Daemon {
	fn drop(&mut self) {
		if self.child.try_wait().ok().flatten().is_none() && self.child.kill().is_ok() {
			let _ = self.exit_status(Duration::from_secs(2));
		}
		if std::thread::panicking() {
			let evidence = self.directory.take().unwrap().keep();
			eprintln!("pipe fixture and daemon log retained at {}", evidence.display());
		}
	}
}

#[test]
fn idle_and_partial_peers_do_not_block_status_or_shutdown() {
	let mut daemon = Daemon::start(None);
	let started = Instant::now();
	let idle = Client::connect(&daemon.endpoint).unwrap();
	let mut partial = daemon.pipe();
	partial.write_all(b"{\"id\":1,\"method\":\"hello\"").unwrap();

	let mut client = daemon.client();
	for _ in 0..2 {
		assert_eq!(client.status().unwrap().pid, daemon.child.id());
	}
	assert!(
		started.elapsed() < Duration::from_secs(2),
		"control waited for a peer deadline"
	);
	daemon.stop(client);
	drop((idle, partial));
}

#[test]
fn a_client_waiting_to_read_a_large_reply_does_not_block_control() {
	let mut job = Job::new(
		Source {
			path: "fixture.tar".into(),
			format: "tar".into(),
			size: 0,
			mtime_ns: 0,
			fingerprint: None,
		},
		Some("zip".into()),
		Vec::new(),
		"fixture",
	)
	.unwrap();
	let detail = "x".repeat(256 * 1024);
	job.fail(JobError::new("E_TOOL_FAILED", &detail));
	let id = job.id.clone();
	let mut daemon = Daemon::start(Some(job));
	let mut client = daemon.client();
	assert_eq!(client.jobs_get(id.as_str()).unwrap().error.unwrap().message, detail);

	let mut slow = daemon.pipe();
	let greeting = Request::new(1, "hello")
		.with_params(Hello {
			ipc: IPC_VERSION.to_string(),
			client: "slow reply fixture".to_string(),
			features: Vec::new(),
		})
		.unwrap();
	write_frame(&mut slow, &greeting).unwrap();
	let peer = slow.try_clone().unwrap();
	let (arrived, observe) = std::sync::mpsc::channel();
	let reader = std::thread::spawn(move || {
		let mut reader = BufReader::new(peer);
		let hello = read_frame(&mut reader).unwrap().unwrap();
		assert_eq!(hello["ok"], true);
		let request = Request::new(2, "jobs.get")
			.with_params(serde_json::json!({"id": id}))
			.unwrap();
		write_frame(reader.get_mut(), &request).unwrap();
		let mut first_byte = [0];
		reader.get_mut().read_exact(&mut first_byte).unwrap();
		assert_eq!(first_byte, [b'{']);
		arrived.send(()).unwrap();
	});
	observe
		.recv_timeout(Duration::from_secs(3))
		.expect("large reply did not start");
	reader.join().unwrap();
	assert_eq!(client.status().unwrap().pid, daemon.child.id());
	daemon.stop(client);
	drop(slow);
}
