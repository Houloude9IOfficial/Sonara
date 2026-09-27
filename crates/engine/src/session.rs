use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Idle,
    Preparing,
    Synchronizing,
    Streaming,
    Recovering,
    Stopping,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionMachine {
    state: SessionState,
    revision: u64,
    generation: u64,
}

#[derive(Debug, Error, PartialEq, Eq)]
#[error("invalid transition from {from:?} to {to:?}")]
pub struct TransitionError {
    pub from: SessionState,
    pub to: SessionState,
}

impl Default for SessionMachine {
    fn default() -> Self {
        Self {
            state: SessionState::Idle,
            revision: 0,
            generation: 0,
        }
    }
}

impl SessionMachine {
    pub fn state(&self) -> SessionState {
        self.state
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn transition(&mut self, to: SessionState) -> Result<u64, TransitionError> {
        use SessionState::*;
        let valid = matches!(
            (self.state, to),
            (Idle, Preparing)
                | (Preparing, Synchronizing)
                | (Synchronizing, Streaming)
                | (Streaming, Recovering)
                | (Recovering, Synchronizing)
                | (Preparing | Synchronizing | Streaming | Recovering, Stopping)
                | (Stopping, Idle)
                | (
                    Preparing | Synchronizing | Streaming | Recovering | Stopping,
                    Error
                )
                | (Error, Idle)
        );
        if !valid {
            return Err(TransitionError {
                from: self.state,
                to,
            });
        }
        if matches!((self.state, to), (Idle, Preparing) | (Error, Idle)) {
            self.generation += 1;
        }
        self.state = to;
        self.revision += 1;
        Ok(self.revision)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn enforces_lifecycle() {
        let mut s = SessionMachine::default();
        assert!(s.transition(SessionState::Streaming).is_err());
        for next in [
            SessionState::Preparing,
            SessionState::Synchronizing,
            SessionState::Streaming,
            SessionState::Stopping,
            SessionState::Idle,
        ] {
            s.transition(next).unwrap();
        }
        assert_eq!(s.revision(), 5);
        assert_eq!(s.generation(), 1);
    }
}
