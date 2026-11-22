//! The Linux daemon spawns scripted `notify-send` and Zenity stand-ins. These tests
//! exercise action delivery, exact review scope and checked restoration, not a desktop session.

#![cfg(target_os = "linux")]

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use retype_core::safety::Fingerprint;
use retype_core::undo::Store;

#[path = "support/journal.rs"]
mod journal;
mod support;

fn retype() -> Command {
	Command::new(env!("CARGO_BIN_EXE_retype"))
}

enum Session {
	Review,
	NoZenity,
	NoDisplay,
}

fn script(bin: &Path, name: &str, body: &str) {
	let path = bin.join(name);
	fs::write(
		&path,
		format!(
			r#"#!/bin/sh
read_reply() {{
	i=0
	while [ "$i" -lt 400 ]; do
		if [ -f "$1" ] && IFS= read -r answer < "$1"; then return 0; fi
		i=$((i + 1))
		sleep 0.05
	done
	return 1
}}
{body}
"#,
		),
	)
	.unwrap();
	fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn fake_notifier(dir: &Path, session: &Session) -> PathBuf {
	let bin = dir.join("bin");
	fs::create_dir(&bin).unwrap();
	let path = std::env::var_os("PATH").unwrap_or_default();
	for name in ["cp", "sleep"] {
		let program = retype_core::tools::find_in_path(&path, name).unwrap();
		symlink(program.canonicalize().unwrap(), bin.join(name)).unwrap();
	}
	script(
		&bin,
		"fixture-copy",
		r#"case "$1" in */failed.png) printf 'fixture conversion failed\n' >&2; exit 7 ;; esac
exec cp "$@""#,
	);
	script(
		&bin,
		"notify-send",
		r#"printf '%s\n' "$@" '<end>' >> "$RECORD"
for arg do
	if [ "$arg" = '--wait' ]; then
		read_reply "$CLICK" || exit 1
		printf '%s\n' "$answer"
		exit 0
	fi
done"#,
	);
	if let Session::NoZenity = session {
		return bin;
	}
	script(
		&bin,
		"zenity",
		r#"printf '%s\0' "$@" '<end>' > "$DIALOG"
read_reply "$REPLY" || exit 5
case "$answer" in
	undo) code=$ZENITY_OK ;;
	close) code=${ZENITY_CANCEL:-1} ;;
	timeout) code=${ZENITY_TIMEOUT:-5} ;;
	*) code=0 ;;
esac
printf '%s\n' "$code" > "$DIALOG_EXIT"
exit "$code""#,
	);
	bin
}

fn config(dir: &Path) -> PathBuf {
	let config = dir.join("retype.toml");
	fs::write(
		&config,
		"\
version = 'retype-config-1'

[backends]
prefer = ['copy']

[tools.copy]
command = 'fixture-copy'
layout = ['{input}', '{ops}', '{output}']

[formats.png]
family = 'image'
lossy = false
alpha = true
tier = 'exact'

[formats.webp]
family = 'image'
lossy = true
alpha = true
tier = 'converted'
",
	)
	.unwrap();

	config
}

struct Daemon(Child);

impl Drop for Daemon {
	fn drop(&mut self) {
		let _ = self.0.kill();
		let _ = self.0.wait();
	}
}

struct Fixture {
	_daemon: Daemon,
	dir: tempfile::TempDir,
	photos: PathBuf,
	state: PathBuf,
}

impl Fixture {
	fn new(source_names: &[&str]) -> Self {
		Self::start(source_names, Session::Review)
	}

	fn start(source_names: &[&str], session: Session) -> Self {
		let dir = tempfile::tempdir().unwrap();
		let photos = dir.path().join("photos");
		fs::create_dir(&photos).unwrap();
		for name in source_names {
			fs::write(photos.join(name), b"pixels").unwrap();
		}
		let state = dir.path().join("state");
		let record = dir.path().join("notified");
		let bin = fake_notifier(dir.path(), &session);
		let config = config(dir.path());

		let registration = retype()
			.args(["watch", "--register", photos.to_str().unwrap()])
			.arg("--state-dir")
			.arg(&state)
			.output()
			.unwrap();
		assert!(registration.status.success(), "{registration:?}");

		let mut command = retype();
		command
			.args(["daemon", "--detached"])
			.arg("--state-dir")
			.arg(&state)
			.env("RETYPE_CONFIG", &config)
			.env("RETYPE_TEST_SESSION", "graphical")
			.env("PATH", bin)
			.env_remove("DBUS_SESSION_BUS_ADDRESS")
			.env_remove("DISPLAY")
			.env_remove("WAYLAND_DISPLAY")
			.env("RECORD", &record)
			.env("CLICK", dir.path().join("click"))
			.env("DIALOG", dir.path().join("dialog"))
			.env("REPLY", dir.path().join("reply"))
			.env("DIALOG_EXIT", dir.path().join("dialog-exit"))
			.env("ZENITY_CANCEL", "42")
			.env("ZENITY_TIMEOUT", "42")
			.stdout(Stdio::null())
			.stderr(Stdio::from(fs::File::create(dir.path().join("daemon.err")).unwrap()));
		if !matches!(session, Session::NoDisplay) {
			command
				.env("DBUS_SESSION_BUS_ADDRESS", "unix:path=/tmp/retype-test-bus")
				.env("DISPLAY", ":12345");
		}
		let daemon = Daemon(command.spawn().unwrap());
		wait_for("daemon endpoint", || state.join("endpoint").exists().then_some(()));
		support::ready(&state);

		Self {
			_daemon: daemon,
			dir,
			photos,
			state,
		}
	}

	fn rename(&self, from: &str, to: &str) {
		fs::rename(self.photos.join(from), self.photos.join(to)).unwrap();
	}

	fn assert_pixels(&self, names: &[&str]) {
		for name in names {
			assert_eq!(fs::read(self.photos.join(name)).unwrap(), b"pixels", "{name}");
		}
	}

	fn click(&self, action: &str) {
		fs::write(self.dir.path().join("click"), format!("{action}\n")).unwrap();
	}

	fn answer_dialog(&self, action: &str) {
		fs::write(self.dir.path().join("reply"), format!("{action}\n")).unwrap();
	}

	fn wait_for_notification(&self) -> String {
		wait_for("notification", || {
			let text = fs::read_to_string(self.dir.path().join("notified")).ok()?;
			text.ends_with("<end>\n").then_some(text)
		})
	}

	fn wait_for_dialog(&self) -> Vec<String> {
		wait_for("review dialog", || {
			let arguments = fs::read_to_string(self.dir.path().join("dialog")).ok()?;
			let complete = arguments.strip_suffix("<end>\0")?;
			Some(complete.split_terminator('\0').map(str::to_string).collect())
		})
	}

	fn wait_for_dialog_exit(&self) -> String {
		let exit = wait_for("dialog exit", || {
			let text = fs::read_to_string(self.dir.path().join("dialog-exit")).ok()?;
			text.ends_with('\n').then_some(text)
		});
		/* Give the daemon time to handle a refusal, which has no filesystem checkpoint to wait for. */
		std::thread::sleep(Duration::from_millis(300));
		exit
	}
}

fn dialog_text(arguments: &[String]) -> &str {
	&arguments[arguments.iter().position(|arg| arg == "--text").unwrap() + 1]
}

fn wait_for<T>(what: &str, mut ready: impl FnMut() -> Option<T>) -> T {
	let deadline = Instant::now() + Duration::from_secs(20);
	loop {
		if let Some(value) = ready() {
			return value;
		}
		assert!(Instant::now() < deadline, "timed out waiting for {what}");
		std::thread::sleep(Duration::from_millis(25));
	}
}

#[test]
fn a_conversion_sends_one_notification_with_review_as_its_only_action() {
	let fixture = Fixture::new(&["a.png"]);
	fixture.rename("a.png", "a.webp");

	let recorded = fixture.wait_for_notification();
	assert!(recorded.contains("--app-name"), "{recorded}");
	assert!(
		recorded.contains("--hint\nstring:desktop-entry:retype-uri\n"),
		"{recorded}"
	);
	assert!(!recorded.contains("--desktop-entry\n"), "{recorded}");
	assert!(recorded.contains("--wait"), "{recorded}");
	assert!(
		recorded.contains("--expire-time\n0\n"),
		"the Review listener must outlive the toast: {recorded}"
	);
	assert_eq!(recorded.matches("--action\n").count(), 1, "{recorded}");
	assert!(recorded.contains("--action\nreview=Review\n"), "{recorded}");
	assert!(recorded.contains("1 converted (a.png → a.webp)"), "{recorded}");

	fixture.click("undo");
	std::thread::sleep(Duration::from_millis(300));
	assert!(
		!fixture.dir.path().join("dialog").exists(),
		"only Review opens the dialog"
	);
	fixture.assert_pixels(&["a.png", "a.webp"]);
}

#[test]
fn close_is_the_default_and_leaves_the_original_output_and_recovery_untouched() {
	let fixture = Fixture::new(&["b&<photo>.png"]);
	fixture.rename("b&<photo>.png", "b&<photo>.webp");
	fixture.wait_for_notification();
	let store = Store::open(&fixture.state);
	let before = store.list().unwrap();
	assert_eq!(before.len(), 1);

	fixture.click("review");
	let arguments = fixture.wait_for_dialog();
	for flag in [
		"--no-markup",
		"--timeout=60",
		"--question",
		"--default-cancel",
		"--cancel-label=Close",
		"Undo",
	] {
		assert!(arguments.iter().any(|arg| arg == flag), "{arguments:?}");
	}
	let text = dialog_text(&arguments);
	for (label, name) in [("Original", "b&<photo>.png"), ("Output", "b&<photo>.webp")] {
		assert!(
			text.contains(&format!("{label}: {}\n", fixture.photos.join(name).display())),
			"{text}"
		);
	}
	fixture.assert_pixels(&["b&<photo>.png", "b&<photo>.webp"]);
	assert_eq!(store.list().unwrap(), before);

	fixture.answer_dialog("close");
	assert_eq!(fixture.wait_for_dialog_exit(), "1\n");
	fixture.assert_pixels(&["b&<photo>.png", "b&<photo>.webp"]);
	assert_eq!(store.list().unwrap(), before);
	assert!(store.source(&before[0].id).unwrap().is_some(), "recovery still usable");
}

#[test]
fn approving_undo_uses_the_checked_restoration() {
	let fixture = Fixture::new(&["b.png"]);
	fixture.rename("b.png", "b.webp");
	fixture.wait_for_notification();
	let saved = fixture.state.join("saved-live-source");
	fs::rename(fixture.photos.join("b.png"), &saved).unwrap();
	fixture.click("review");
	fixture.wait_for_dialog();
	fixture.answer_dialog("undo");

	let store = Store::open(&fixture.state);
	wait_for("checked undo", || {
		(!fixture.photos.join("b.webp").exists() && store.list().unwrap().is_empty()).then_some(())
	});
	fixture.assert_pixels(&["b.png"]);
	assert_eq!(fs::read(saved).unwrap(), b"pixels");
}

#[test]
fn approval_still_requires_matching_output_bytes_in_checked_restore() {
	let fixture = Fixture::new(&["changed.png"]);
	fixture.rename("changed.png", "changed.webp");
	fixture.wait_for_notification();
	let output = fixture.photos.join("changed.webp");
	/* Change the bytes without changing the inode or size that Review checks. */
	fs::write(&output, b"edited").unwrap();
	fixture.click("review");
	let arguments = fixture.wait_for_dialog();
	assert!(arguments.iter().any(|arg| arg == "Undo"), "{arguments:?}");
	fixture.answer_dialog("undo");
	wait_for("checked restoration refusal", || {
		let text = fs::read_to_string(fixture.dir.path().join("daemon.err")).ok()?;
		text.contains("cannot undo reviewed conversions").then_some(())
	});
	fixture.assert_pixels(&["changed.png"]);
	assert_eq!(fs::read(output).unwrap(), b"edited");
	let store = Store::open(&fixture.state);
	let records = store.list().unwrap();
	assert_eq!(records.len(), 1);
	assert!(store.source(&records[0].id).unwrap().is_some());
}

#[test]
fn missing_recovery_before_review_makes_the_whole_batch_close_only() {
	let fixture = Fixture::new(&["d.png", "e.png"]);
	fixture.rename("d.png", "d.webp");
	fixture.rename("e.png", "e.webp");
	let notification = fixture.wait_for_notification();
	assert!(notification.contains("2 converted"), "{notification}");
	let store = Store::open(&fixture.state);
	let mut remaining = store.list().unwrap();
	assert_eq!(remaining.len(), 2);
	let missing = remaining.pop().unwrap();
	let saved = fixture.state.join("saved-recovery");
	{
		let _lease = store.lease(&missing.id).unwrap();
		fs::rename(store.directory(&missing.id), &saved).unwrap();
	}

	fixture.click("review");
	let arguments = fixture.wait_for_dialog();
	assert!(arguments.iter().any(|arg| arg == "--info"), "{arguments:?}");
	assert!(arguments.iter().any(|arg| arg == "--ok-label=Close"), "{arguments:?}");
	assert!(!arguments.iter().any(|arg| arg == "--question"), "{arguments:?}");
	fixture.answer_dialog("undo"); // Success from a Close-only dialog still cannot authorize Undo.
	fixture.wait_for_dialog_exit();
	fixture.assert_pixels(&["d.png", "d.webp", "e.png", "e.webp"]);
	assert!(saved.join(missing.source_file()).is_file());
	assert_eq!(store.list().unwrap(), remaining);
}

#[test]
fn a_replaced_output_refuses_approved_undo_even_with_the_same_bytes() {
	let fixture = Fixture::new(&["replaced.png"]);
	fixture.rename("replaced.png", "replaced.webp");
	fixture.wait_for_notification();
	fixture.click("review");
	assert!(fixture.wait_for_dialog().iter().any(|arg| arg == "Undo"));

	let store = Store::open(&fixture.state);
	let before = store.list().unwrap();
	let saved = fixture.state.join("owned-output");
	fs::rename(fixture.photos.join("replaced.webp"), &saved).unwrap();
	fs::copy(&saved, fixture.photos.join("replaced.webp")).unwrap();
	fixture.answer_dialog("undo");
	wait_for("replacement refusal", || {
		let text = fs::read_to_string(fixture.dir.path().join("daemon.err")).ok()?;
		text.contains("changed since Review").then_some(())
	});
	fixture.assert_pixels(&["replaced.png", "replaced.webp"]);
	assert_eq!(fs::read(saved).unwrap(), b"pixels");
	assert_eq!(store.list().unwrap(), before);
}

#[test]
fn a_changed_record_refuses_the_whole_approved_batch() {
	let fixture = Fixture::new(&["f.png", "g.png"]);
	fixture.rename("f.png", "f.webp");
	fixture.rename("g.png", "g.webp");
	let notification = fixture.wait_for_notification();
	assert!(notification.contains("2 converted"), "{notification}");
	fixture.click("review");
	let arguments = fixture.wait_for_dialog();
	assert!(arguments.iter().any(|arg| arg == "Undo 2 conversions"), "{arguments:?}");
	let text = dialog_text(&arguments);

	/* Change the last reviewed record to name a different owned output under its lease. */
	let store = Store::open(&fixture.state);
	let mut changed = store
		.list()
		.unwrap()
		.into_iter()
		.max_by_key(|record| {
			text.find(&format!("Original: {}\n", record.source_path.display()))
				.unwrap()
		})
		.unwrap();
	let unreviewed = fixture.state.join("unreviewed.webp");
	fs::write(&unreviewed, b"pixels").unwrap();
	{
		let _lease = store.lease(&changed.id).unwrap();
		changed.outputs[0].path = unreviewed.clone();
		changed.commits[0].output.path = unreviewed.clone();
		changed.commits[0].fingerprint = Fingerprint::of(&unreviewed).unwrap();
		fs::write(
			store.directory(&changed.id).join("meta.toml"),
			toml::to_string(&changed).unwrap(),
		)
		.unwrap();
	}
	let before = store.list().unwrap();
	fixture.answer_dialog("undo");
	wait_for("stale approval refusal", || {
		let text = fs::read_to_string(fixture.dir.path().join("daemon.err")).ok()?;
		text.contains("changed since Review").then_some(())
	});
	fixture.assert_pixels(&["f.png", "f.webp", "g.png", "g.webp"]);
	assert_eq!(fs::read(&unreviewed).unwrap(), b"pixels");
	assert_eq!(store.list().unwrap(), before);
}

#[test]
fn an_actionable_review_shows_the_mixed_batch_summary_and_only_the_affected_paths() {
	let fixture = Fixture::new(&["good.png", "failed.png"]);
	fixture.rename("good.png", "good.webp");
	fixture.rename("failed.png", "failed.webp");
	let notification = fixture.wait_for_notification();
	let summary = notification.lines().rev().nth(1).unwrap();
	assert!(
		summary.contains("1 converted (good.png → good.webp), 1 failed (failed.png:"),
		"{summary}"
	);

	fixture.click("review");
	let arguments = fixture.wait_for_dialog();
	let text = dialog_text(&arguments);
	assert!(text.starts_with(summary), "{text}");
	assert!(text.contains("removes only matching outputs"), "{text}");
	assert!(
		text.contains(&format!("Output: {}\n", fixture.photos.join("good.webp").display())),
		"{text}"
	);
	assert!(
		!text.contains(fixture.photos.join("failed.webp").to_str().unwrap()),
		"{text}"
	);
	assert!(arguments.iter().any(|arg| arg == "Undo"), "{arguments:?}");
	fixture.answer_dialog("close");
	fixture.wait_for_dialog_exit();
}

#[test]
fn timeout_or_normal_exit_without_explicit_approval_does_not_undo() {
	for (reply, exit) in [("timeout", "5\n"), ("unexpected-success", "0\n")] {
		let fixture = Fixture::new(&["h.png"]);
		fixture.rename("h.png", "h.webp");
		fixture.wait_for_notification();
		let store = Store::open(&fixture.state);
		let before = store.list().unwrap();
		fixture.click("review");
		fixture.wait_for_dialog();
		fixture.answer_dialog(reply);
		assert_eq!(fixture.wait_for_dialog_exit(), exit);
		fixture.assert_pixels(&["h.png", "h.webp"]);
		assert_eq!(store.list().unwrap(), before);
	}
}

#[test]
fn without_zenity_the_daemon_sends_a_plain_notification() {
	let fixture = Fixture::start(&["c.png"], Session::NoZenity);
	fixture.rename("c.png", "c.webp");
	let recorded = fixture.wait_for_notification();
	assert!(recorded.contains("--expire-time\n15000\n"), "{recorded}");
	assert!(!recorded.contains("--action"), "{recorded}");
	assert!(!recorded.contains("--wait"), "{recorded}");
	fixture.assert_pixels(&["c.webp"]);
}

#[test]
fn a_conversion_without_a_notification_session_uses_the_log() {
	let fixture = Fixture::start(&["c.png"], Session::NoDisplay);
	fixture.rename("c.png", "c.webp");
	wait_for("logged conversion", || {
		let logged = fs::read_to_string(fixture.dir.path().join("daemon.err")).ok()?;
		logged.contains("retype: 1 converted (c.png → c.webp)").then_some(())
	});

	let contents = fs::read_to_string(fixture.state.join("jobs.jsonl")).unwrap();
	let jobs = journal::latest(&contents);
	assert_eq!(jobs.len(), 1);
	assert_eq!(jobs[0]["state"], "done");
	assert_eq!(jobs[0]["source_disposition"]["state"], "retained");
	assert_eq!(
		jobs[0]["source"]["path"],
		fixture.photos.join("c.png").canonicalize().unwrap().to_str().unwrap()
	);
	fixture.assert_pixels(&["c.webp"]);
	assert!(!fixture.dir.path().join("notified").exists(), "no notifier was run");
}

#[test]
fn a_full_local_review_link_does_not_restore_without_a_desktop() {
	let fixture = Fixture::start(&["headless.png"], Session::NoDisplay);
	fixture.rename("headless.png", "headless.webp");
	let store = Store::open(&fixture.state);
	let before = wait_for("settled recovery", || {
		let records = store.list().unwrap();
		records
			.first()
			.is_some_and(|record| record.retention_started.is_some())
			.then_some(records)
	});
	let uri = format!("retype://job/{}", before[0].id);

	let launch = |extra: &[&str]| {
		retype()
			.arg("--state-dir")
			.arg(&fixture.state)
			.args(["uri", "--", &uri])
			.args(extra)
			.env_remove("DISPLAY")
			.env_remove("WAYLAND_DISPLAY")
			.stdin(Stdio::null())
			.output()
			.unwrap()
	};
	let headless = launch(&[]);
	assert!(!headless.status.success(), "{headless:?}");
	assert!(String::from_utf8_lossy(&headless.stderr).contains("Review needs a local graphical session"));
	let extra = launch(&["--state-dir"]);
	assert!(!extra.status.success(), "{extra:?}");
	assert!(String::from_utf8_lossy(&extra.stderr).contains("unexpected argument"));

	fixture.assert_pixels(&["headless.png", "headless.webp"]);
	assert_eq!(store.list().unwrap(), before);
	assert!(!fixture.dir.path().join("dialog").exists());
}
