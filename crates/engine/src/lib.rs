//! Portable, deterministic pieces of the Sonara engine.
//!
//! Platform callbacks and sockets deliberately live outside this crate.  The
//! types here are testable without audio hardware or wall-clock sleeps.

pub mod diagnostics;
pub mod invitation;
pub mod packet;
pub mod session;
pub mod simulation;
pub mod sync;

pub const PROTOCOL_MAJOR: u8 = 1;
pub const LOGICAL_SAMPLE_RATE: u32 = 48_000;
pub const CHANNELS: u16 = 2;
