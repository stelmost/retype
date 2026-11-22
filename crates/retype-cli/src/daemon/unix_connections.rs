//! Bound peer I/O separately from the serialized daemon control operations.

use std::io::{self, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, ScopedJoinHandle};
use std::time::{Duration, Instant};

use retype_ipc::read_frame;

use super::{Server, connection_result, write_response};
use crate::daemon::{peer, signals};
use crate::error::Result;

const CONNECTIONS: usize = 16;
const IO_POLL: Duration = Duration::from_millis(100);
const FRAME_TIMEOUT: Duration = Duration::from_secs(2);

pub fn serve(listener: UnixListener, server: &mut Server) -> Result<()> {
	listener.set_nonblocking(true)?;
	let server = Mutex::new(server);
	let stopping = AtomicBool::new(false);
	thread::scope(|scope| {
		let result = (|| {
			let mut seen = signals::Seen::now();
			let mut clients: Vec<ScopedJoinHandle<'_, ()>> = Vec::new();
			while service_controls(&server, &mut seen)? {
				clients.retain(|client| !client.is_finished());
				if clients.len() >= CONNECTIONS {
					thread::sleep(signals::POLL);
					continue;
				}
				let socket = match listener.accept() {
					Ok((socket, _)) => socket,
					Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
						thread::sleep(signals::POLL);
						continue;
					}
					Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
					Err(error) => return Err(error.into()),
				};
				let uid = peer::peer_uid(&socket);
				if !peer::accepts(uid, peer::our_uid()) {
					eprintln!("retype: refused a connection from uid {}", uid.unwrap_or_default());
					continue;
				}
				let (server, stopping) = (&server, &stopping);
				clients.push(thread::Builder::new().name("retype-peer".to_string()).spawn_scoped(
					scope,
					move || {
						if let Err(error) = connection_result(serve_peer(&socket, server, stopping)) {
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

fn serve_peer(socket: &UnixStream, server: &Mutex<&mut Server>, stopping: &AtomicBool) -> Result<()> {
	socket.set_nonblocking(false)?;
	socket.set_read_timeout(Some(IO_POLL))?;
	socket.set_write_timeout(Some(IO_POLL))?;
	let mut reader = BufReader::new(BoundedIo::new(socket, Some(stopping)));
	/* Finish an in-flight reply even if its request was shutdown. */
	let mut writer = BoundedIo::new(socket, None);
	Server::serve_frames(
		|| {
			if stopping.load(Ordering::Relaxed) {
				return Ok(None);
			}
			reader.get_mut().begin_frame();
			read_frame(&mut reader)
		},
		|response| {
			writer.begin_frame();
			write_response(&mut writer, response)
		},
		None,
		|request| {
			let mut server = server
				.lock()
				.map_err(|_| io::Error::other("daemon control lock poisoned"))?;
			if server.stopped() {
				return Err(io::Error::from(io::ErrorKind::ConnectionAborted).into());
			}
			server.reply(request)
		},
	)
}

struct BoundedIo<'a> {
	socket: &'a UnixStream,
	stopping: Option<&'a AtomicBool>,
	deadline: Instant,
}

impl<'a> BoundedIo<'a> {
	fn new(socket: &'a UnixStream, stopping: Option<&'a AtomicBool>) -> Self {
		Self {
			socket,
			stopping,
			deadline: Instant::now(),
		}
	}

	fn begin_frame(&mut self) {
		self.deadline = Instant::now() + FRAME_TIMEOUT;
	}

	fn transfer(&self, mut io: impl FnMut(&UnixStream) -> io::Result<usize>) -> io::Result<usize> {
		loop {
			if self.stopping.is_some_and(|stopping| stopping.load(Ordering::Relaxed)) {
				return Err(io::ErrorKind::ConnectionAborted.into());
			}
			if Instant::now() >= self.deadline {
				return Err(io::Error::new(io::ErrorKind::TimedOut, "IPC frame deadline elapsed"));
			}
			match io(self.socket) {
				Err(error)
					if matches!(
						error.kind(),
						io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut | io::ErrorKind::Interrupted
					) => {}
				result => return result,
			}
		}
	}
}

impl Read for BoundedIo<'_> {
	fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
		self.transfer(|mut socket| socket.read(buffer))
	}
}

impl Write for BoundedIo<'_> {
	fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
		self.transfer(|mut socket| socket.write(buffer))
	}

	fn flush(&mut self) -> io::Result<()> {
		Ok(())
	}
}
