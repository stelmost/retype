#![cfg_attr(windows, windows_subsystem = "windows")]

//! Windows protocol entry point. Keep the console subsystem in the terminal CLI.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use retype_cli::{output, state, uri};

#[derive(Parser)]
struct Args {
	#[arg(long)]
	state_dir: Option<PathBuf>,
	#[arg(last = true)]
	uri: String,
}

fn main() -> ExitCode {
	let args = Args::parse();
	state::resolve(args.state_dir)
		.and_then(|state| uri::run(&state, &args.uri, false))
		.unwrap_or_else(|error| ExitCode::from(output::fail_error(&error)))
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn the_url_is_the_only_operand_after_the_terminator() {
		let url = "retype://job/01m6b4rararx3wrttkrgpp1783";
		let path = r"C:\Retype State";
		let args = Args::try_parse_from(["retype-review", "--state-dir", path, "--", url]).unwrap();
		assert_eq!(args.state_dir, Some(PathBuf::from(path)));
		assert_eq!(args.uri, url);
		assert!(
			Args::try_parse_from(["retype-review", "--", url])
				.unwrap()
				.state_dir
				.is_none()
		);
		assert!(Args::try_parse_from(["retype-review", url]).is_err());
		assert!(Args::try_parse_from(["retype-review", "--", url, "--state-dir", path]).is_err());
	}
}
