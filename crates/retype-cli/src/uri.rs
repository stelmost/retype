//! Desktop links select a local job for Review. A URL never authorizes a job action.

use std::path::Path;
use std::process::ExitCode;

use retype_core::error::Code;
use retype_core::job::JobId;

use crate::error::Result;
use crate::output;

#[cfg(any(windows, target_os = "macos", test))]
pub(crate) fn review_url(id: &JobId) -> String {
	format!("retype://job/{id}")
}

fn parse(uri: &str) -> Option<JobId> {
	let (scheme, address) = uri.split_once("://")?;
	let (path, action) = address.split_once('?').unwrap_or((address, "action=review"));
	let (kind, id) = path.split_once('/')?;
	if !scheme.eq_ignore_ascii_case("retype")
		|| !kind.eq_ignore_ascii_case("job")
		|| action != "action=review"
		|| !id.bytes().all(|byte| byte.is_ascii_alphanumeric())
	{
		return None;
	}
	JobId::parse(id).ok()
}

pub fn run(state_dir: &Path, uri: &str, json: bool) -> Result<ExitCode> {
	let Some(id) = parse(uri) else {
		return Ok(ExitCode::from(output::fail(
			&Code::UsageArgs,
			"a retype URI can only open Review for one full job ID",
		)));
	};
	if json {
		return Ok(ExitCode::from(output::fail(
			&Code::UsageConflict,
			"Review needs a graphical dialog, not JSON mode",
		)));
	}
	open_review(state_dir, &id)?;
	Ok(ExitCode::SUCCESS)
}

#[cfg(any(target_os = "linux", target_os = "macos", windows))]
fn open_review(state_dir: &Path, id: &JobId) -> Result<()> {
	Ok(crate::notify::review::open_job(state_dir, id)?)
}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
fn open_review(_: &Path, _: &JobId) -> Result<()> {
	Err(
		retype_core::error::Diagnostic::global(Code::Unsupported, "desktop Review is unavailable on this platform")
			.into(),
	)
}

#[cfg(test)]
mod tests {
	use super::*;

	const ID: &str = "01m6b4rararx3wrttkrgpp1783";

	#[test]
	fn review_links_name_one_full_job() {
		let id = JobId::parse(ID).unwrap();
		assert_eq!(parse(&review_url(&id)), Some(id.clone()));
		assert_eq!(
			parse(&format!("RETYPE://JOB/{}?action=review", ID.to_uppercase())),
			Some(id)
		);
	}

	#[test]
	fn links_cannot_name_an_action_other_than_review_or_supply_other_parameters() {
		for suffix in [
			"?action=undo",
			"?action=cancel",
			"?action=resolve",
			"?action=review&action=undo",
			"?",
			"#link",
			"/another",
			"/",
			"?file=original",
			"?action=review&yes=1",
			" --yes",
		] {
			assert!(parse(&format!("retype://job/{ID}{suffix}")).is_none(), "{suffix}");
		}
		for address in [
			"retype://job",
			"retype://job/01m6",
			"retype://job/../file",
			"https://job/01m6",
			"retype://job/%30",
		] {
			assert!(parse(address).is_none(), "{address}");
		}
	}
}
