//! Bound peer I/O separately from the serialized daemon control operations.

use std::io::{self, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use retype_ipc::read_frame;

use super::{Server, write_response};
use crate::daemon::{connections, peer, signals};
use crate::error::Result;

const IO_POLL: Duration = Duration::from_millis(100);

pub fn serve(listener: UnixListener, server: &mut Server) -> Result<()> {
	listener.set_nonblocking(true)?;
	connections::serve(server, &mut signals::Seen::now(), move || accept(&listener), serve_peer)
}

fn accept(listener: &UnixListener) -> Result<Option<UnixStream>> {
	let socket = match listener.accept() {
		Ok((socket, _)) => socket,
		Err(error) if matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted) => {
			return Ok(None);
		}
		Err(error) => return Err(error.into()),
	};
	let uid = peer::peer_uid(&socket);
	if !peer::accepts(uid, peer::our_uid()) {
		eprintln!("retype: refused a connection from uid {}", uid.unwrap_or_default());
		return Ok(None);
	}
	Ok(Some(socket))
}

fn serve_peer(socket: UnixStream, server: &Mutex<&mut Server>, stopping: &AtomicBool) -> Result<()> {
	socket.set_nonblocking(false)?;
	socket.set_read_timeout(Some(IO_POLL))?;
	socket.set_write_timeout(Some(IO_POLL))?;
	let mut reader = BufReader::new(BoundedIo::new(&socket, Some(stopping)));
	/* Finish an in-flight reply even if its request was shutdown. */
	let mut writer = BoundedIo::new(&socket, None);
	Server::serve_peer(
		server,
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
		self.deadline = Instant::now() + connections::FRAME_TIMEOUT;
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
