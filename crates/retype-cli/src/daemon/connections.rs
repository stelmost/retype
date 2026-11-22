//! Bound transport workers without holding the daemon lock during peer I/O.

use std::io;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, ScopedJoinHandle};
use std::time::Duration;

use super::server::{Server, connection_result};
use super::signals;
use crate::error::Result;

const CONNECTIONS: usize = 16;
pub(super) const FRAME_TIMEOUT: Duration = Duration::from_secs(2);

pub(super) fn serve<T: Send>(
	server: &mut Server,
	seen: &mut signals::Seen,
	mut accept: impl FnMut() -> Result<Option<T>>,
	serve_peer: impl Fn(T, &Mutex<&mut Server>, &AtomicBool) -> Result<()> + Sync,
) -> Result<()> {
	let server = Mutex::new(server);
	let stopping = AtomicBool::new(false);
	let serve_peer = &serve_peer;
	thread::scope(|scope| {
		let result = (|| {
			let mut clients: Vec<ScopedJoinHandle<'_, ()>> = Vec::new();
			while service_controls(&server, seen)? {
				clients.retain(|client| !client.is_finished());
				let accepted = if clients.len() < CONNECTIONS { accept()? } else { None };
				let Some(peer) = accepted else {
					thread::sleep(signals::POLL);
					continue;
				};
				let (server, stopping) = (&server, &stopping);
				clients.push(thread::Builder::new().name("retype-peer".to_string()).spawn_scoped(
					scope,
					move || {
						if let Err(error) = connection_result(serve_peer(peer, server, stopping)) {
							if !stopping.load(Ordering::Relaxed) {
								eprintln!("retype: client connection closed: {error}");
							}
						}
					},
				)?);
			}
			Ok(())
		})();
		stopping.store(true, Ordering::Relaxed);
		drop(accept);
		result
	})
}

fn service_controls(server: &Mutex<&mut Server>, seen: &mut signals::Seen) -> Result<bool> {
	let (asked, next) = seen.asked();
	*seen = next;
	let mut server = server
		.lock()
		.map_err(|_| io::Error::other("daemon control lock poisoned"))?;
	match asked {
		signals::Asked::Nothing => {}
		signals::Asked::Drain => {
			server.stop(false);
			eprintln!("retype: stopping after the running jobs finish; a second signal cancels them");
		}
		signals::Asked::Now => {
			server.stop(true);
		}
	}
	Ok(!server.stopped())
}
