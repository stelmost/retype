//! The `retype://` handler a desktop entry or Start-menu shortcut calls.
//!
//! A click on a notification or a link names one job and one action. The handler
//! starts nothing: an undo can run in-process from the store, and every action that
//! needs the daemon reports unavailable rather than replacing a job that the user
//! may not know is gone. The GUI owns the editor action; the CLI owns undo, cancel
//! and resolve.

use std::io::{self, BufRead, IsTerminal, Write};
use std::path::Path;
use std::process::ExitCode;

use retype_core::error::Code;
use retype_core::identifier::normalize;
use retype_core::job::JobId;
use serde_json::json;

use crate::error::Result;
use crate::output;

/// What a URI asks for, with every name in its canonical spelling.
struct Parsed {
	id: String,
	action: String,
}

/// Read `retype://job/<id>[?action=...]`.
///
/// The scheme, the object name and the action are identifiers a person may have
/// typed, so they are read in either case and normalized. The job id itself is
/// normalized by the same rule as a handle on the command line.
fn parse(uri: &str) -> std::result::Result<Parsed, String> {
	let Some((scheme, rest)) = uri.split_once("://") else {
		return Err(format!("'{uri}' is not a retype:// URI"));
	};

	if !scheme.eq_ignore_ascii_case("retype") {
		return Err(format!("'{uri}' is not a retype:// URI"));
	}

	let (path, query) = rest.split_once('?').unwrap_or((rest, ""));
	let mut parts = path.split('/');

	match parts.next() {
		Some(kind) if kind.eq_ignore_ascii_case("job") => {}
		_ => return Err(format!("'{uri}' names no job")),
	}

	let id = parts
		.next()
		.and_then(|id| JobId::parse(id).ok())
		.filter(|_| parts.next().is_none())
		.ok_or_else(|| "a retype URI requires one full job id".to_string())?;
	let action = if query.is_empty() {
		"undo".to_string()
	} else {
		let (key, action) = query.split_once('=').ok_or("a retype URI has an invalid query")?;
		if !key.eq_ignore_ascii_case("action") {
			return Err("a retype URI has an unknown query field".to_string());
		}
		normalize(action)
	};
	if !matches!(action.as_str(), "undo" | "cancel" | "resolve") {
		return Err("a retype URI action must be undo, cancel or resolve".to_string());
	}
	Ok(Parsed {
		id: id.to_string(),
		action,
	})
}

pub fn run(state_dir: &Path, uri: &str, json: bool) -> Result<ExitCode> {
	let Parsed { id, action } = match parse(uri) {
		Ok(parsed) => parsed,
		Err(message) => return Ok(ExitCode::from(output::fail(&Code::UsageArgs, message))),
	};

	/* The registered handler is public; launching it is not consent to act on a job. */
	let instruction = match action.as_str() {
		"undo" => format!("retype undo {id}"),
		"cancel" => format!("retype jobs cancel {id}"),
		_ => format!("retype jobs resolve {id} --now"),
	};
	let stdin = io::stdin();
	let stderr = io::stderr();
	if json || !stdin.is_terminal() || !stderr.is_terminal() {
		return Ok(ExitCode::from(output::fail(
			&Code::JobState,
			format!("a retype URI cannot change job state without terminal confirmation; run `{instruction}`"),
		)));
	}
	{
		let mut stderr = stderr.lock();
		write!(stderr, "Run `{instruction}`? Type yes to confirm: ")?;
		stderr.flush()?;
	}
	let mut answer = String::new();
	stdin.lock().read_line(&mut answer)?;
	if !answer.trim().eq_ignore_ascii_case("yes") {
		return Ok(ExitCode::from(output::fail(
			&Code::JobState,
			"URI action not confirmed",
		)));
	}

	match action.as_str() {
		"undo" => crate::undo::run(state_dir, Some(&id), false, json),
		"cancel" | "resolve" => {
			let mut client = match crate::client::connect(state_dir) {
				Ok(client) => client,
				Err(_) => {
					return Ok(ExitCode::from(output::fail(
						&Code::IpcUnavailable,
						"the daemon is not running; start it and try again",
					)));
				}
			};

			let method = match action.as_str() {
				"cancel" => "jobs.cancel",
				_ => "jobs.resolve",
			};
			let params = match action.as_str() {
				"cancel" => json!({"id": id}),
				_ => json!({"id": id, "mode": "now"}),
			};

			let answer = client.call(method, params)?;

			if json {
				output::success(answer);
			} else if let Some(state) = answer.get("state").and_then(|value| value.as_str()) {
				println!("{id}  {state}");
			}

			Ok(ExitCode::SUCCESS)
		}
		other => Ok(ExitCode::from(output::fail(
			&Code::UsageArgs,
			format!("'{other}' is not an action this build handles; use undo, cancel or resolve"),
		))),
	}
}

#[cfg(test)]
mod tests {
	use super::parse;

	#[test]
	fn a_uri_is_read_in_either_case() {
		let parsed = parse("RETYPE://JOB/01M6B4RARARX3WrTTKRGPP1783?ACTION=UNDO").expect("a URI");

		assert_eq!(parsed.id, "01m6b4rararx3wrttkrgpp1783");
		assert_eq!(parsed.action, "undo");
	}

	#[test]
	fn the_action_defaults_to_undo() {
		let parsed = parse("retype://job/01m6b4rararx3wrttkrgpp1783").expect("a URI");

		assert_eq!(parsed.action, "undo");
	}

	#[test]
	fn a_uri_requires_a_full_unambiguous_request() {
		for uri in [
			"retype://job/01m6",
			"retype://job/01m6b4rararx3wrttkrgpp1783/extra",
			"retype://job/01m6b4rararx3wrttkrgpp1783?action=undo&action=cancel",
			"retype://job/01m6b4rararx3wrttkrgpp1783?unexpected=1",
		] {
			assert!(parse(uri).is_err(), "{uri}");
		}
	}

	#[test]
	fn json_uri_calls_cannot_perform_an_offline_mutation() {
		let directory = tempfile::tempdir().unwrap();
		let state = directory.path().join("never-created");
		let result = super::run(&state, "retype://job/01m6b4rararx3wrttkrgpp1783", true).unwrap();
		assert_ne!(result, std::process::ExitCode::SUCCESS);
		assert!(!state.exists());
	}

	#[test]
	fn a_uri_without_a_job_is_refused() {
		assert!(parse("retype://photo/01m6b4rararx3wrttkrgpp1783").is_err());
		assert!(parse("retype://job").is_err());
		assert!(parse("https://job/01m6b4rararx3wrttkrgpp1783").is_err());
	}
}
