//! Saying what a batch of jobs did.
//!
//! One notification per rename batch, because a directory full of photographs should
//! not be twelve interruptions. The message is built from the records, so it says what
//! happened rather than what was attempted. On supported desktops Review opens a
//! native dialog; the notification itself never undoes anything.
//!
//! Capability is a property of the platform, so there are three tiers and the daemon
//! uses the best one it has:
//!
//! | Tier | How | Where |
//! |---|---|---|
//! | Review | `notify-send --wait --action`, then Zenity | Linux with notification actions and a graphical session |
//! | Review | protocol activation from the installed notification identity | Windows and macOS |
//! | Plain | `notify-send`, the macOS notifier/`osascript`, or a PowerShell toast | when Review is unavailable or disabled |
//! | Log | a line on the daemon's stderr | anywhere the platform has no notifier |

use std::path::Path;
use std::process::{Command, Stdio};

use retype_core::job::{Job, JobId, JobState, Output, OutputState};

/// How many conversions a message names before it counts the rest. A notification is a
/// glance, not a listing; `retype jobs` is the listing.
const NAMED: usize = 3;

/// What the daemon tells the user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Message {
	pub title: String,
	pub body: String,
	/// Exact job IDs to check for a possible Undo when Review is opened.
	pub undo: Vec<JobId>,
}

impl Message {
	/// Describe a finished batch, or nothing when the batch did nothing worth saying.
	pub fn of(jobs: &[Job], undo_enabled: bool) -> Option<Self> {
		if jobs.is_empty() {
			return None;
		}

		let converted: Vec<&Job> = jobs
			.iter()
			.filter(|job| matches!(job.state, JobState::Done | JobState::Partial))
			.collect();

		let failed = with_state(jobs, JobState::Failed);
		let cancelled = with_state(jobs, JobState::Cancelled);
		let superseded = with_state(jobs, JobState::Superseded);
		let parked: Vec<&Job> = jobs
			.iter()
			.filter(|job| matches!(job.state, JobState::Pending | JobState::NeedsAttention))
			.collect();

		let mut parts = Vec::new();
		if !converted.is_empty() {
			// A count alone leaves the user guessing what became of what, so the names
			// and the formats follow it.
			parts.push(format!(
				"{} converted ({})",
				converted.len(),
				named(&converted, conversion)
			));
		}
		if !failed.is_empty() {
			parts.push(format!("{} failed ({})", failed.len(), named(&failed, failure)));
		}
		if !cancelled.is_empty() {
			parts.push(format!(
				"{} cancelled ({})",
				cancelled.len(),
				named(&cancelled, source_name)
			));
		}
		if !superseded.is_empty() {
			parts.push(format!(
				"{} superseded ({})",
				superseded.len(),
				named(&superseded, source_name)
			));
		}
		if !parked.is_empty() {
			parts.push(format!("{} parked ({})", parked.len(), named(&parked, waiting)));
		}

		if parts.is_empty() {
			return None;
		}

		let mut body = parts.join(", ");

		// A parked job that can run as asked only needs the timer; one that cannot needs
		// a person, so the body says which.
		if !parked.is_empty() {
			body.push_str(&parked_hint(&parked));
		}

		let has_other_outputs = jobs.iter().any(|job| {
			!matches!(job.state, JobState::Done | JobState::Partial)
				&& job.outputs.iter().any(|output| output.state == OutputState::Done)
		});
		let undo = if undo_enabled && !has_other_outputs {
			converted.iter().map(|job| job.id.clone()).collect()
		} else {
			Vec::new()
		};

		Some(Self {
			title: "retype".to_string(),
			body,
			undo,
		})
	}
}

/// Name each conversion and its product, up to `NAMED`, then count the rest.
fn named(jobs: &[&Job], describe: impl Fn(&Job) -> String) -> String {
	let mut names: Vec<String> = jobs.iter().take(NAMED).map(|job| describe(job)).collect();

	if jobs.len() > NAMED {
		names.push(format!("and {} more", jobs.len() - NAMED));
	}

	names.join(", ")
}

/// `a.heic → a.jpg`, plus what was dropped or missed on the way.
fn conversion(job: &Job) -> String {
	let source = file_name(&job.source.path);
	let written = outputs(job);

	if written.is_empty() {
		return source;
	}

	let targets: Vec<String> = written.iter().map(|output| file_name(&output.path)).collect();
	let mut text = format!("{source} → {}", targets.join(", "));

	// A repair ran an intent it had cut down, and a partial conversion left an output
	// unwritten: both are things the user has to know to judge the result.
	if let Some(dropped) = dropped_tokens(job) {
		text.push_str(&format!("; dropped {}", dropped.join(", ")));
	}

	let missed: Vec<String> = job
		.outputs
		.iter()
		.filter(|output| matches!(output.state, OutputState::Failed | OutputState::Skipped))
		.map(missed_output)
		.collect();

	if !missed.is_empty() {
		text.push_str(&format!("; {}", missed.join(", ")));
	}

	text
}

/// The tokens a repair dropped, which a job that ran as asked never has.
fn dropped_tokens(job: &Job) -> Option<&[String]> {
	let dropped = &job.parked.as_ref()?.dropped;

	(!dropped.is_empty()).then_some(dropped.as_slice())
}

/// `a.webp: magick exited 1`, an output of a batch that was not written.
fn missed_output(output: &Output) -> String {
	let name = file_name(&output.path);

	match output.error.as_ref().map(|error| error.message.as_str()) {
		Some(message) if !message.is_empty() => format!("{name}: {message}"),
		_ => name,
	}
}

/// `a.heic: magick exited 1`: the file and the reason it failed.
fn failure(job: &Job) -> String {
	let source = source_name(job);

	match diagnosis(job) {
		Some(message) => format!("{source}: {message}"),
		None => source,
	}
}

/// `a.heic: cost`: the file and the reason `jobs list` shows for the wait.
fn waiting(job: &Job) -> String {
	let source = source_name(job);
	let reason = job
		.parked
		.as_ref()
		.map(|parked| parked.reason.as_str())
		.unwrap_or_default();

	match reason.is_empty() {
		true => source,
		false => format!("{source}: {}", wait_reason(reason)),
	}
}

/// The reason as a person reads it. `size` alone does not say what is waiting.
fn wait_reason(reason: &str) -> &str {
	match reason {
		"size" => "over the automatic size limit",
		other => other,
	}
}

/// The first thing recorded as wrong. A tool's failure lands on its output, and the
/// job's own error is only set when the job never reached one.
fn diagnosis(job: &Job) -> Option<String> {
	job.error
		.as_ref()
		.or_else(|| job.outputs.iter().find_map(|output| output.error.as_ref()))
		.map(|error| error.message.clone())
}

fn source_name(job: &Job) -> String {
	file_name(&job.source.path)
}

/// What ends the wait, so a parked batch says whether it needs a person.
fn parked_hint(jobs: &[&Job]) -> String {
	if jobs.iter().any(|job| job.state == JobState::NeedsAttention) {
		return "; `retype jobs --interactive` decides what happens".to_string();
	}

	let pronoun = match jobs.len() {
		1 => "it",
		_ => "them",
	};

	format!("; the deferral timer will run {pronoun}")
}

fn with_state(jobs: &[Job], state: JobState) -> Vec<&Job> {
	jobs.iter().filter(|job| job.state == state).collect()
}

/// The outputs that were written, falling back to every output the job declared when no
/// state says otherwise.
fn outputs(job: &Job) -> Vec<&Output> {
	let written: Vec<&Output> = job
		.outputs
		.iter()
		.filter(|output| output.state == OutputState::Done)
		.collect();

	match written.is_empty() {
		true => job.outputs.iter().collect(),
		false => written,
	}
}

fn file_name(path: &Path) -> String {
	path.file_name()
		.map(|name| name.to_string_lossy().into_owned())
		.unwrap_or_else(|| path.display().to_string())
}

/// The best way this machine can say something.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Channel {
	/// A notification with a Review button.
	#[cfg(any(target_os = "linux", target_os = "macos", windows))]
	Actions,
	/// A notification without buttons.
	Plain,
	/// A line on the daemon's own output.
	Log,
}

impl Channel {
	/// What this machine can do, decided once at startup.
	pub fn detect(actions: bool) -> Self {
		#[cfg(target_os = "macos")]
		{
			if installed_macos_notifier().is_some() {
				return if actions { Self::Actions } else { Self::Plain };
			}
			if has_command("osascript") {
				Self::Plain
			} else {
				Self::Log
			}
		}

		#[cfg(windows)]
		{
			if review::dialog::windows_powershell().is_none() {
				Self::Log
			} else if actions {
				Self::Actions
			} else {
				Self::Plain
			}
		}

		#[cfg(not(any(target_os = "macos", target_os = "windows")))]
		{
			if !has_session() || !has_notifier() {
				return Self::Log;
			}

			#[cfg(target_os = "linux")]
			if actions && review::dialog::batch_available() {
				return Self::Actions;
			}
			let _ = actions;
			Self::Plain
		}
	}

	/// Show the message, and open a read-only review if requested.
	pub fn send(&self, message: &Message, state_dir: &Path, job: Option<&JobId>) {
		#[cfg(not(target_os = "linux"))]
		let _ = state_dir;
		#[cfg(not(any(windows, target_os = "macos")))]
		let _ = job;
		match self {
			Self::Log => {
				// The title is the product's own name, so a log line would say it twice.
				eprintln!("retype: {}", message.body);
			}
			Self::Plain => {
				let _ = plain(message);
			}
			#[cfg(target_os = "linux")]
			Self::Actions => match notify_send(message, true) {
				Ok(true) => {
					if let Err(error) = review::show_batch(message, state_dir) {
						eprintln!("retype: Review failed: {error}");
					}
				}
				Ok(false) => {}
				/* The notification server may already have displayed a plain fallback. */
				Err(error) => eprintln!("retype: Review notification unavailable: {error}; {}", message.body),
			},
			#[cfg(any(windows, target_os = "macos"))]
			Self::Actions => {
				let url = job.map(crate::uri::review_url);
				#[cfg(windows)]
				let _ = toast(message, url.as_deref());
				#[cfg(target_os = "macos")]
				let _ = macos_notification(message, url.as_deref());
			}
		}
	}
}

/// A notification without actions, on whatever this platform uses.
fn plain(message: &Message) -> Option<String> {
	#[cfg(target_os = "macos")]
	{
		macos_notification(message, None)
	}

	#[cfg(windows)]
	{
		toast(message, None)
	}

	#[cfg(not(any(target_os = "macos", target_os = "windows")))]
	{
		notify_send(message, false).ok().map(|_| String::new())
	}
}

#[cfg(target_os = "macos")]
fn macos_notification(message: &Message, url: Option<&str>) -> Option<String> {
	if let Some(helper) = installed_macos_notifier() {
		let url = url.filter(|_| review::dialog::local_desktop());
		return match send_macos(&helper, message, url, std::time::Duration::from_secs(30)) {
			Ok(()) => Some(String::new()),
			Err(error) => {
				eprintln!("retype: native notification failed: {error}; {}", message.body);
				None
			}
		};
	}

	let quote = |text: &str| format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""));
	let script = format!(
		"display notification {} with title {}",
		quote(&message.body),
		quote(&message.title)
	);

	let output = Command::new("osascript")
		.args(["-e", &script])
		.stdin(Stdio::null())
		.stderr(Stdio::null())
		.output()
		.ok()?;

	output.status.success().then(String::new)
}

#[cfg(target_os = "macos")]
fn installed_macos_notifier() -> Option<std::path::PathBuf> {
	macos_notifier(&std::env::current_exe().ok()?)
}

#[cfg(any(target_os = "macos", test))]
fn macos_notifier(executable: &Path) -> Option<std::path::PathBuf> {
	let parent = executable.parent()?;
	let prefix = parent.parent()?;
	let candidate = if parent.file_name().is_some_and(|name| name == "Resources")
		&& prefix.file_name().is_some_and(|name| name == "Contents")
	{
		prefix.join("MacOS/retype-notifier")
	} else {
		prefix.join("share/retype/macos/retype.app/Contents/MacOS/retype-notifier")
	};
	candidate.is_file().then_some(candidate)
}

#[cfg(any(target_os = "macos", all(test, unix)))]
fn send_macos(
	helper: &Path,
	message: &Message,
	url: Option<&str>,
	timeout: std::time::Duration,
) -> std::io::Result<()> {
	let child = Command::new(helper)
		.args(["notify", &message.title, &message.body])
		.args(url)
		.stdin(Stdio::null())
		.stdout(Stdio::null())
		.stderr(Stdio::inherit())
		.spawn()?;
	let status = wait_for_helper(child, timeout, "native notifier")?;
	if !status.success() {
		return Err(std::io::Error::other(format!("native notifier exited {status}")));
	}
	Ok(())
}

#[cfg(any(target_os = "linux", target_os = "macos", windows, all(test, unix)))]
fn wait_for_helper(
	mut child: std::process::Child,
	timeout: std::time::Duration,
	name: &str,
) -> std::io::Result<std::process::ExitStatus> {
	use std::io::{Error, ErrorKind};
	use std::time::{Duration, Instant};

	let deadline = Instant::now() + timeout;
	let error = loop {
		match child.try_wait() {
			Ok(Some(status)) => return Ok(status),
			Err(error) => break error,
			Ok(None) => {}
		}
		if Instant::now() >= deadline {
			break Error::new(ErrorKind::TimedOut, format!("{name} timed out"));
		}
		std::thread::sleep(Duration::from_millis(10));
	};
	/* Only the desktop helper is killed; it never runs conversion or undo. */
	let _ = child.kill();
	let _ = child.wait();
	Err(error)
}

/// Run `notify-send`, answering whether the user pressed Review.
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn notify_send(message: &Message, with_action: bool) -> std::io::Result<bool> {
	let mut command = Command::new("notify-send");
	// GNOME keeps actions visible after a finite notify-send wait has timed out.
	let expiry = if with_action { "0" } else { "15000" };
	command.args([
		"--app-name",
		"retype",
		/* Debian 13's notify-send supports the hint, not the dedicated option. */
		"--hint",
		"string:desktop-entry:retype-uri",
		"--expire-time",
		expiry,
	]);

	if with_action {
		command.args(["--wait", "--action", "review=Review"]);
	}

	let output = command
		.arg(&message.title)
		.arg(&message.body)
		.stdin(Stdio::null())
		.stderr(Stdio::null())
		.output()?;
	if !output.status.success() {
		return Err(std::io::Error::other(format!("notify-send exited {}", output.status)));
	}
	Ok(output.stdout == b"review\n")
}

#[cfg(any(target_os = "linux", target_os = "macos", windows))]
pub(crate) mod review {
	use std::collections::BTreeSet;
	use std::fs;
	use std::io;

	use retype_core::error::{Code, Diagnostic, Result};
	use retype_core::execute::Cancellation;
	use retype_core::job::JobId;
	use retype_core::safety::Fingerprint;
	use retype_core::undo::{Link, Record, Store};

	use super::{Message, OutputState, Path, file_name};

	pub(super) mod dialog;

	const MAX_PATHS: usize = 6;
	const MAX_PATH_BYTES: usize = 120;
	const MAX_SUMMARY_CHARS: usize = 240;

	struct Proposal {
		records: Vec<Record>,
		text: String,
	}

	pub(crate) fn open_job(state_dir: &Path, id: &JobId) -> Result<()> {
		if !dialog::local_desktop() {
			return Err(Diagnostic::global(Code::Unsupported, "Review needs a local graphical session").into());
		}
		let store = Store::open(state_dir);
		let message = local_job(state_dir, &store, id)?;
		show(&store, &message, |text, label| {
			let approved = dialog::show(&format!("Job {id}\n\n{text}"), label)?;
			Ok(approved && dialog::local_desktop())
		})
	}

	fn local_job(state_dir: &Path, store: &Store, id: &JobId) -> Result<Message> {
		/* Check existing state without creating it or changing permissions. */
		match fs::symlink_metadata(state_dir) {
			Ok(metadata) if private_state(&metadata) => {}
			Ok(_) => return Err(io::Error::other("Review requires private Retype state").into()),
			Err(error) if error.kind() == io::ErrorKind::NotFound => return Err(job_not_found()),
			Err(error) => return Err(error.into()),
		}
		let job = crate::client::connect(state_dir)
			.ok()
			.and_then(|mut client| client.jobs_get(id.as_str()).ok())
			.filter(|job| &job.id == id);
		if let Some(job) = job {
			return Ok(
				Message::of(std::slice::from_ref(&job), true).unwrap_or_else(|| Message {
					title: "retype".to_string(),
					body: format!("{}: {:?}", file_name(&job.source.path), job.state),
					undo: Vec::new(),
				}),
			);
		}
		let record = store
			.load(id)?
			.filter(|record| &record.id == id)
			.ok_or_else(job_not_found)?;
		Ok(Message {
			title: "retype".to_string(),
			body: format!("Retained recovery for {}", file_name(&record.source_path)),
			undo: vec![record.id],
		})
	}

	fn job_not_found() -> retype_core::error::Error {
		Diagnostic::global(Code::JobNotFound, "no local job matches this Review link").into()
	}

	fn private_state(metadata: &fs::Metadata) -> bool {
		if !metadata.is_dir() {
			return false;
		}
		#[cfg(unix)]
		{
			use std::os::unix::fs::MetadataExt;
			metadata.uid() == unsafe { libc::geteuid() } && metadata.mode() & 0o077 == 0
		}
		#[cfg(windows)]
		{
			use std::os::windows::fs::MetadataExt;
			use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;
			metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0
		}
	}

	#[cfg(target_os = "linux")]
	pub(super) fn show_batch(message: &Message, state_dir: &Path) -> Result<()> {
		show(&Store::open(state_dir), message, dialog::show_batch)
	}

	fn show(store: &Store, message: &Message, display: impl Fn(&str, Option<&str>) -> io::Result<bool>) -> Result<()> {
		let approval = match propose(store, message) {
			Ok(proposal) => proposal,
			Err(error) => {
				eprintln!("retype: cannot review undo records: {error}");
				None
			}
		};
		let Some(proposal) = approval else {
			display(&close_only_text(&message.body), None)?;
			return Ok(());
		};
		let label = match proposal.records.len() {
			1 => "Undo".to_string(),
			count => format!("Undo {count} conversions"),
		};
		if display(&proposal.text, Some(&label))?
			&& let Err(error) = restore(store, &proposal.records)
		{
			eprintln!("retype: cannot undo reviewed conversions: {error}");
			let message = format!("Retype could not finish Undo.\n\n{}", summary(&error.to_string()));
			if let Err(display_error) = display(&message, None) {
				eprintln!("retype: cannot show Undo result: {display_error}");
			}
			return Err(error);
		}
		Ok(())
	}

	fn propose(store: &Store, message: &Message) -> Result<Option<Proposal>> {
		let ids = &message.undo;
		if ids.is_empty() || ids.len() > MAX_PATHS / 2 || message.body.chars().nth(MAX_SUMMARY_CHARS).is_some() {
			return Ok(None);
		}
		let mut records = Vec::with_capacity(ids.len());
		for id in ids {
			let Some(record) = store.load(id)? else {
				return Ok(None);
			};
			/* Publication intents are not a complete inventory until the record is settled. */
			if &record.id != id
				|| record.pinned
				|| record.undo_progress.is_some()
				|| record.retention_started.is_none()
				|| record.link != Link::Copy
				|| record.commits.is_empty()
				|| record.commits.len() >= MAX_PATHS
				|| record.commits.len() != record.outputs.len()
				|| !record.commits.iter().all(|commit| {
					commit.output.state == OutputState::Done
						&& record
							.outputs
							.iter()
							.any(|output| output.path == commit.output.path && output.ext == commit.output.format)
				}) {
				return Ok(None);
			}
			records.push(record);
		}
		let Some(text) = review_text(&message.body, &records) else {
			return Ok(None);
		};
		for record in &records {
			if !files_eligible(store, record)? {
				return Ok(None);
			}
		}
		Ok(Some(Proposal { records, text }))
	}

	fn review_text(body: &str, records: &[Record]) -> Option<String> {
		let mut text = summary(body);
		text.push_str("\n\nUndo restores missing originals and removes only matching outputs listed below.\n");
		let mut seen = BTreeSet::new();
		for record in records {
			text.push('\n');
			let paths = std::iter::once(("Original", &record.source_path))
				.chain(record.commits.iter().map(|commit| ("Output", &commit.output.path)));
			for (label, path) in paths {
				if seen.len() == MAX_PATHS || !seen.insert(path) || !path.is_absolute() {
					return None;
				}
				let name = path.to_str()?;
				if name.len() > MAX_PATH_BYTES || name.trim_end() != name || name.chars().any(hidden) {
					return None;
				}
				text.push_str(&format!("{label}: {name}\n"));
			}
		}
		Some(text)
	}

	/* A path must not inject a new line or reorder the review's labels. */
	fn hidden(character: char) -> bool {
		character.is_control()
			|| (character.is_whitespace() && character != ' ')
			|| matches!(character, '\u{061c}' | '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2060}'..='\u{206f}' | '\u{feff}')
	}

	fn summary(body: &str) -> String {
		let mut chars = body.chars().map(|c| if hidden(c) { ' ' } else { c });
		let mut text: String = chars.by_ref().take(MAX_SUMMARY_CHARS).collect();
		if chars.next().is_some() {
			text.push('…');
		}
		text
	}

	fn close_only_text(body: &str) -> String {
		format!("{}\n\nUndo is not available.", summary(body))
	}

	/* Preflight only metadata; checked restoration verifies backup and output contents. */
	fn files_eligible(store: &Store, record: &Record) -> Result<bool> {
		let Some(original) = &record.source_fingerprint else {
			return Ok(false);
		};
		let backup = fs::symlink_metadata(store.directory(&record.id).join(record.source_file()))?;
		if !backup.is_file() || backup.len() != original.bytes {
			return Ok(false);
		}
		match fs::symlink_metadata(&record.source_path) {
			Ok(metadata) if !metadata.is_file() => return Ok(false),
			Ok(metadata) if record.consume_source && !matches_metadata(&record.source_path, &metadata, original) => {
				return Ok(false);
			}
			Ok(_) => {}
			Err(error) if error.kind() == io::ErrorKind::NotFound => {}
			Err(error) => return Err(error.into()),
		}
		for commit in &record.commits {
			let path = &commit.output.path;
			if !matches_metadata(path, &fs::symlink_metadata(path)?, &commit.fingerprint) {
				return Ok(false);
			}
		}
		Ok(true)
	}

	fn matches_metadata(path: &Path, metadata: &fs::Metadata, fingerprint: &Fingerprint) -> bool {
		use retype_core::job::FileIdentity;

		if !metadata.is_file() || metadata.len() != fingerprint.bytes {
			return false;
		}
		#[cfg(unix)]
		{
			use std::os::unix::fs::MetadataExt;
			let _ = path;
			matches!(fingerprint.identity, Some(FileIdentity::Unix { dev, ino, .. })
				if dev == metadata.dev() && ino == metadata.ino())
		}
		#[cfg(windows)]
		{
			fingerprint
				.identity
				.as_ref()
				.zip(FileIdentity::of(path))
				.is_some_and(|(wanted, found)| wanted.matches(&found))
		}
	}

	fn restore(store: &Store, records: &[Record]) -> Result<()> {
		/* Refuse a stale approval for the whole batch before beginning any job's undo. */
		let leases = records
			.iter()
			.map(|record| store.lease(&record.id))
			.collect::<Result<Vec<_>>>()?;
		for record in records {
			if store.load(&record.id)?.as_ref() != Some(record) || !files_eligible(store, record)? {
				return Err(io::Error::other(format!("{} changed since Review", record.id)).into());
			}
		}
		for (record, lease) in records.iter().zip(leases) {
			store.restore_owned(lease, &Cancellation::default())?;
			eprintln!("retype: undid {}", record.id);
		}
		Ok(())
	}

	#[cfg(test)]
	#[test]
	fn retained_recovery_is_selected_by_exact_id_without_starting_a_daemon() {
		use retype_core::undo::Subject;

		let temp = tempfile::tempdir().unwrap();
		let state = temp.path().join("state");
		crate::state::ensure_private_directory(&state).unwrap();
		let source = temp.path().join("sample.png");
		fs::write(&source, b"sample").unwrap();
		let id = JobId::parse("01m6b4rararx3wrttkrgpp1783").unwrap();
		let other = JobId::parse("01m6b4rararx3wrttkrgpp1784").unwrap();
		let store = Store::open(&state);
		let record = store
			.save(Subject {
				id: id.clone(),
				intent: "webp".to_string(),
				machine: "fixture".to_string(),
				bytes: source.clone(),
				source_path: source,
				source_ext: "png".to_string(),
				outputs: Vec::new(),
				consume_source: false,
			})
			.unwrap();

		let message = local_job(&state, &store, &id).unwrap();
		assert_eq!(message.undo, vec![id.clone()]);
		assert_eq!(store.load(&id).unwrap(), Some(record));
		assert_eq!(local_job(&state, &store, &other).unwrap_err().code(), Code::JobNotFound);
		fs::rename(store.directory(&id), store.directory(&other)).unwrap();
		assert_eq!(local_job(&state, &store, &other).unwrap_err().code(), Code::JobNotFound);
		assert!(!state.join(crate::state::ENDPOINT_FILE).exists());
	}
}

/// The AppUserModelID the toast is shown under, in the publisher's reverse-DNS form.
#[cfg(any(target_os = "windows", test))]
const APP_ID: &str = "com.lapilliworks.retype.cli";

/// Show a toast through system PowerShell. Without our registered handler it stays plain.
#[cfg(windows)]
fn toast(message: &Message, url: Option<&str>) -> Option<String> {
	let mut command = Command::new(review::dialog::windows_powershell()?);
	let url = url.filter(|_| review::dialog::local_desktop() && installed_windows_handler());
	command
		.args(["-NoProfile", "-NonInteractive", "-EncodedCommand"])
		.arg(encoded_command(&toast_script(message, url)))
		.stdin(Stdio::null())
		.stdout(Stdio::null())
		.stderr(Stdio::null());
	retype_core::process::hide_console(&mut command);

	match command
		.spawn()
		.and_then(|child| wait_for_helper(child, std::time::Duration::from_secs(30), "Windows notification"))
	{
		Ok(status) if status.success() => Some(String::new()),
		result => {
			eprintln!("retype: native notification failed: {result:?}; {}", message.body);
			None
		}
	}
}

#[cfg(windows)]
fn installed_windows_handler() -> bool {
	use windows_sys::Win32::UI::Shell::{ASSOCF_IS_PROTOCOL, ASSOCF_NOTRUNCATE, ASSOCSTR_COMMAND, AssocQueryStringW};

	let Ok(executable) = std::env::current_exe() else {
		return false;
	};
	let Some(executable) = executable.to_str() else {
		return false;
	};
	let mut buffer = vec![0u16; 32768];
	let mut length = buffer.len() as u32;
	let result = unsafe {
		AssocQueryStringW(
			ASSOCF_IS_PROTOCOL | ASSOCF_NOTRUNCATE,
			ASSOCSTR_COMMAND,
			windows_sys::w!("retype"),
			std::ptr::null(),
			buffer.as_mut_ptr(),
			&mut length,
		)
	};
	if result != 0 {
		return false;
	}
	let length = buffer.iter().position(|word| *word == 0).unwrap_or(buffer.len());
	String::from_utf16(&buffer[..length]).is_ok_and(|handler| is_windows_handler(&handler, executable))
}

#[cfg(any(windows, test))]
fn is_windows_handler(handler: &str, executable: &str) -> bool {
	handler
		.strip_prefix('"')
		.and_then(|command| command.split_once('"'))
		.is_some_and(|(path, args)| path.eq_ignore_ascii_case(executable) && args.ends_with(r#" uri -- "%1""#))
}

/// Use protocol activation only with our installed identity. The fallback toast is plain.
#[cfg(any(windows, test))]
fn toast_script(message: &Message, url: Option<&str>) -> String {
	let xml = format!(
		"<toast><visual><binding template=\"ToastGeneric\"><text>{}</text><text>{}</text></binding></visual></toast>",
		xml_escape(&message.title),
		xml_escape(&message.body)
	);
	let review = url
		.map(|url| {
			format!(
				"$document.LoadXml($plain.Replace('</toast>', '<actions><action content=\"Review\" \
		 activationType=\"protocol\" arguments=\"{}\"/></actions></toast>'))",
				xml_escape(url),
			)
		})
		.unwrap_or_default();
	format!(
		r#"$ErrorActionPreference = 'Stop'
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$document = New-Object Windows.Data.Xml.Dom.XmlDocument
$plain = '{xml}'
$document.LoadXml($plain)
$app = '{APP_ID}'
try {{
	$key = 'HKCU:\Software\Classes\AppUserModelId\' + $app
	if (-not (Test-Path -LiteralPath $key)) {{
		New-Item -Path $key -Force | Out-Null
		New-ItemProperty -LiteralPath $key -Name 'DisplayName' -Value 'retype' -PropertyType String -Force | Out-Null
	}}
	{review}
	$toast = New-Object -TypeName Windows.UI.Notifications.ToastNotification -ArgumentList $document
	[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show($toast)
}} catch {{
	$document.LoadXml($plain)
	$toast = New-Object -TypeName Windows.UI.Notifications.ToastNotification -ArgumentList $document
	$fallback = '{{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}}\WindowsPowerShell\v1.0\powershell.exe'
	[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($fallback).Show($toast)
}}"#
	)
}

/// `-EncodedCommand` takes the script in base64 over UTF-16LE, so no quoting and no
/// console code page stands between a file name and the toast.
#[cfg(any(target_os = "windows", test))]
fn encoded_command(script: &str) -> String {
	base64(&script.encode_utf16().flat_map(u16::to_le_bytes).collect::<Vec<u8>>())
}

#[cfg(any(target_os = "windows", test))]
fn base64(bytes: &[u8]) -> String {
	const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

	let mut text = String::with_capacity(bytes.len().div_ceil(3) * 4);

	for chunk in bytes.chunks(3) {
		let triple = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
		let bits = u32::from_be_bytes([0, triple[0], triple[1], triple[2]]);

		text.push(ALPHABET[(bits >> 18) as usize & 63] as char);
		text.push(ALPHABET[(bits >> 12) as usize & 63] as char);
		text.push(match chunk.len() > 1 {
			true => ALPHABET[(bits >> 6) as usize & 63] as char,
			false => '=',
		});
		text.push(match chunk.len() > 2 {
			true => ALPHABET[bits as usize & 63] as char,
			false => '=',
		});
	}

	text
}

#[cfg(any(target_os = "windows", test))]
fn xml_escape(text: &str) -> String {
	let mut escaped = String::with_capacity(text.len());

	for character in text.chars() {
		match character {
			'&' => escaped.push_str("&amp;"),
			'<' => escaped.push_str("&lt;"),
			'>' => escaped.push_str("&gt;"),
			'"' => escaped.push_str("&quot;"),
			'\'' => escaped.push_str("&apos;"),
			_ => escaped.push(character),
		}
	}

	escaped
}

/// Whether there is a session to appear in at all.
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn has_session() -> bool {
	["DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "DISPLAY"]
		.iter()
		.any(|name| std::env::var_os(name).is_some_and(|value| !value.is_empty()))
}

/// Whether a notifier command exists. `notify-send` is libnotify's own client and the
/// one every desktop session ships.
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn has_notifier() -> bool {
	has_command("notify-send")
}

#[cfg(not(windows))]
fn has_command(command: &str) -> bool {
	retype_core::tools::find_in_path(&std::env::var_os("PATH").unwrap_or_default(), command).is_some()
}

#[cfg(test)]
mod tests {
	use super::*;
	use retype_core::job::{Job, JobError, Parked, Source, Tier};

	fn job(id: usize, state: JobState) -> Job {
		let mut job = Job::new(
			Source {
				path: format!("/photos/{id}.heic").into(),
				format: "heic".to_string(),
				size: 0,
				mtime_ns: 0,
				fingerprint: None,
			},
			Some("jpg".to_string()),
			vec![Output::pending(
				format!("/photos/{id}.jpg").into(),
				"jpg".to_string(),
				Tier::Converted,
			)],
			"machine",
		)
		.expect("a job");

		job.id = JobId::parse(&format!("01J{:023}", id)).expect("an id");
		job.state = state;

		if matches!(state, JobState::Done | JobState::Partial) {
			for output in &mut job.outputs {
				output.state = OutputState::Done;
			}
		}

		job
	}

	/// The same job, parked for a reason, as the daemon records one.
	fn park(mut job: Job, reason: &str) -> Job {
		job.parked = Some(Parked {
			reason: reason.to_string(),
			deadline: None,
			batch: None,
			estimate: None,
			requested: None,
			corrected: None,
			dropped: Vec::new(),
			consume: true,
			force: false,
			input_fingerprint: None,
		});

		job
	}

	#[test]
	fn a_batch_of_conversions_names_what_became_what() {
		let jobs = vec![job(1, JobState::Done), job(2, JobState::Done)];

		let message = Message::of(&jobs, true).expect("a message");

		assert_eq!(message.body, "2 converted (1.heic → 1.jpg, 2.heic → 2.jpg)");
		assert_eq!(message.undo.len(), 2);
	}

	#[test]
	fn a_long_batch_names_a_few_and_counts_the_rest() {
		let jobs: Vec<Job> = (1..=5).map(|id| job(id, JobState::Done)).collect();

		let message = Message::of(&jobs, true).expect("a message");

		assert_eq!(
			message.body,
			"5 converted (1.heic → 1.jpg, 2.heic → 2.jpg, 3.heic → 3.jpg, and 2 more)"
		);
	}

	#[test]
	fn several_outputs_of_one_job_are_all_named() {
		let mut job = job(1, JobState::Done);
		job.outputs = ["webp", "jpg"]
			.iter()
			.map(|format| Output::pending(format!("/photos/1.{format}").into(), *format, Tier::Converted))
			.collect();
		for output in &mut job.outputs {
			output.state = OutputState::Done;
		}

		let message = Message::of(&[job], true).expect("a message");

		assert_eq!(message.body, "1 converted (1.heic → 1.webp, 1.jpg)");
	}

	#[test]
	fn a_partial_conversion_names_the_output_it_missed() {
		let mut partial = job(1, JobState::Partial);
		let mut missed = Output::pending("/photos/1.webp".into(), "webp", Tier::Converted);
		missed.state = OutputState::Failed;
		missed.error = Some(JobError {
			code: "E_TOOL_FAILED".to_string(),
			message: "magick exited 1".to_string(),
		});
		partial.outputs.push(missed);

		let message = Message::of(&[partial], true).expect("a message");

		assert_eq!(message.body, "1 converted (1.heic → 1.jpg; 1.webp: magick exited 1)");
	}

	#[test]
	fn a_repaired_conversion_says_what_it_dropped() {
		let mut repaired = park(job(1, JobState::Done), "inapplicable");
		repaired.parked.as_mut().expect("a parked record").dropped = vec!["quality80".to_string()];

		let message = Message::of(&[repaired], true).expect("a message");

		assert_eq!(message.body, "1 converted (1.heic → 1.jpg; dropped quality80)");
	}

	#[test]
	fn a_failure_is_named_rather_than_counted() {
		let mut failed = job(1, JobState::Failed);
		failed.error = Some(JobError {
			code: "E_TOOL_MISSING".to_string(),
			message: "magick is not installed".to_string(),
		});

		let converted = job(2, JobState::Done);
		let id = converted.id.clone();
		let message = Message::of(&[converted, failed], true).expect("a message");

		assert_eq!(
			message.body,
			"1 converted (2.heic → 2.jpg), 1 failed (1.heic: magick is not installed)"
		);
		assert_eq!(message.undo, vec![id]);
	}

	#[test]
	fn a_failure_without_a_job_error_takes_the_outputs_reason() {
		let mut failed = job(1, JobState::Failed);
		failed.outputs[0].state = OutputState::Failed;
		failed.outputs[0].error = Some(JobError {
			code: "E_TOOL_FAILED".to_string(),
			message: "magick exited 1: no decode delegate".to_string(),
		});

		let message = Message::of(&[failed], true).expect("a message");

		assert_eq!(message.body, "1 failed (1.heic: magick exited 1: no decode delegate)");
	}

	#[test]
	fn a_cancelled_job_and_a_superseded_one_are_named_and_kept_apart() {
		let jobs = vec![job(1, JobState::Cancelled), job(2, JobState::Superseded)];

		let message = Message::of(&jobs, true).expect("a message");

		assert_eq!(message.body, "1 cancelled (1.heic), 1 superseded (2.heic)");
	}

	#[test]
	fn a_pending_batch_names_the_file_and_what_ends_the_wait() {
		let message = Message::of(&[park(job(1, JobState::Pending), "cost")], true).expect("a message");

		assert_eq!(message.body, "1 parked (1.heic: cost); the deferral timer will run it");
		assert!(message.undo.is_empty());
	}

	#[test]
	fn a_batch_that_needs_attention_says_where_to_decide() {
		let message = Message::of(&[park(job(1, JobState::NeedsAttention), "intent")], true).expect("a message");

		assert_eq!(
			message.body,
			"1 parked (1.heic: intent); `retype jobs --interactive` decides what happens"
		);
		assert!(message.undo.is_empty());
	}

	#[test]
	fn a_size_park_is_named_in_plain_words() {
		let message = Message::of(&[park(job(1, JobState::NeedsAttention), "size")], true).expect("a message");

		assert_eq!(
			message.body,
			"1 parked (1.heic: over the automatic size limit); `retype jobs --interactive` decides what happens"
		);
	}

	#[test]
	fn with_undo_disabled_there_are_no_undo_candidates() {
		let message = Message::of(&[job(1, JobState::Done)], false).expect("a message");

		assert!(message.undo.is_empty());
	}

	#[test]
	fn a_batch_with_nothing_to_say_says_nothing() {
		assert!(Message::of(&[], true).is_none());
	}

	#[test]
	fn the_macos_notifier_is_resolved_from_the_exact_installation() {
		let directory = tempfile::tempdir().unwrap();
		let app = directory.path().join("share/retype/macos/retype.app/Contents");
		let helper = app.join("MacOS/retype-notifier");
		std::fs::create_dir_all(helper.parent().unwrap()).unwrap();
		std::fs::write(&helper, b"fixture").unwrap();
		assert_eq!(
			macos_notifier(&directory.path().join("bin/retype")),
			Some(helper.clone())
		);
		assert_eq!(macos_notifier(&app.join("Resources/retype")), Some(helper));
		assert!(macos_notifier(&directory.path().join("target/debug/retype")).is_none());
	}

	#[cfg(unix)]
	#[test]
	fn the_native_notifier_receives_literal_arguments_and_reports_failure() {
		use std::os::unix::fs::PermissionsExt;
		use std::time::Duration;

		let directory = tempfile::tempdir().unwrap();
		let helper = directory.path().join("notifier with spaces");
		let record = directory.path().join("arguments");
		std::fs::write(
			&helper,
			format!("#!/bin/sh\nprintf '%s\\0' \"$@\" > '{}'\n", record.display()),
		)
		.unwrap();
		std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
		let message = Message {
			title: "retype \"title\"".to_string(),
			body: "a&b; $HOME `echo no`\nnew line".to_string(),
			undo: Vec::new(),
		};
		let url = crate::uri::review_url(&job(1, JobState::Done).id);
		for url in [None, Some(url.as_str())] {
			send_macos(&helper, &message, url, Duration::from_secs(2)).unwrap();
			let mut expected = format!("notify\0{}\0{}\0", message.title, message.body);
			if let Some(url) = url {
				expected.push_str(url);
				expected.push('\0');
			}
			assert_eq!(std::fs::read(&record).unwrap(), expected.as_bytes());
		}
		std::fs::write(&helper, "#!/bin/sh\nexit 7\n").unwrap();
		let error = send_macos(&helper, &message, None, Duration::from_secs(2)).unwrap_err();
		assert!(error.to_string().contains('7'), "{error}");
	}

	#[cfg(unix)]
	#[test]
	fn a_native_notifier_timeout_is_bounded_and_reaped() {
		use std::os::unix::fs::PermissionsExt;
		use std::time::{Duration, Instant};

		let directory = tempfile::tempdir().unwrap();
		let helper = directory.path().join("notifier");
		std::fs::write(&helper, "#!/bin/sh\nexec sleep 60\n").unwrap();
		std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
		let message = Message {
			title: "retype".to_string(),
			body: "fixture".to_string(),
			undo: Vec::new(),
		};
		let start = Instant::now();
		let error = send_macos(&helper, &message, None, Duration::from_millis(50)).unwrap_err();
		assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
		assert!(start.elapsed() < Duration::from_secs(2));
	}

	#[test]
	fn a_command_is_encoded_as_utf16_little_endian() {
		assert_eq!(encoded_command(""), "");
		assert_eq!(encoded_command("A"), "QQA=");
		assert_eq!(encoded_command("AB"), "QQBCAA==");
	}

	#[test]
	fn the_encoding_pads_the_tail() {
		assert_eq!(base64(b""), "");
		assert_eq!(base64(b"f"), "Zg==");
		assert_eq!(base64(b"fo"), "Zm8=");
		assert_eq!(base64(b"foo"), "Zm9v");
		assert_eq!(base64(b"foobar"), "Zm9vYmFy");
	}

	#[test]
	fn a_toast_carries_both_lines_and_registers_the_identifier() {
		let message = Message {
			title: "retype".to_string(),
			body: "1 converted (a&b<c>.heic → a.jpg)".to_string(),
			undo: Vec::new(),
		};

		let script = toast_script(&message, None);

		assert!(script.contains("<text>retype</text>"), "{script}");
		assert!(!script.contains("<action"), "{script}");
		assert!(
			script.contains("<text>1 converted (a&amp;b&lt;c&gt;.heic → a.jpg)</text>"),
			"{script}"
		);
		assert!(script.contains(APP_ID), "{script}");
		assert!(script.contains("AppUserModelId"), "{script}");
	}

	#[test]
	fn desktop_review_names_one_full_job_and_toast_fallback_is_plain() {
		let job = job(1, JobState::Done);
		let message = Message::of(std::slice::from_ref(&job), true).unwrap();
		let url = crate::uri::review_url(&job.id);
		assert_eq!(url, format!("retype://job/{}", job.id));
		let script = toast_script(&message, Some(&url));
		let (registered, fallback) = script.split_once("} catch {").unwrap();
		assert!(registered.contains(&format!(
			r#"content="Review" activationType="protocol" arguments="{url}""#
		)));
		assert!(!fallback.contains(&url) && fallback.contains("$document.LoadXml($plain)"));
	}

	#[test]
	fn protocol_activation_needs_our_installed_single_operand_handler() {
		let executable = r"C:\Retype Test\bin\retype.exe";
		let handler = format!(r#""{executable}" --state-dir "C:\Retype State" uri -- "%1""#);
		assert!(is_windows_handler(&handler, executable));
		assert!(!is_windows_handler(&handler, r"C:\Other\retype.exe"));
		assert!(!is_windows_handler(&handler.replace(" -- ", " "), executable));
	}
}
