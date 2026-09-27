use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

const PREFIX: &str = "sonara1:";
pub const INVITATION_LIFETIME_SECS: u64 = 120;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Invitation {
    pub protocol: u8,
    pub id: Uuid,
    pub endpoints: Vec<String>,
    pub host_fingerprint: String,
    /// Exact self-signed host certificate used as the first-contact trust anchor.
    #[serde(with = "certificate_encoding")]
    pub host_certificate_der: Vec<u8>,
    #[serde(with = "token_encoding")]
    token: [u8; 32],
    pub issued_at_unix: u64,
    pub expires_at_unix: u64,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum InvitationError {
    #[error("invitation has an invalid prefix or encoding")]
    InvalidEncoding,
    #[error("invitation is for protocol {0}, but this build speaks protocol 1")]
    Version(u8),
    #[error("invitation has expired")]
    Expired,
    #[error("invitation timestamp is invalid")]
    InvalidTime,
    #[error("invitation has no endpoint candidates")]
    NoEndpoints,
}

impl Invitation {
    pub fn issue(
        endpoints: Vec<String>,
        host_fingerprint: String,
        host_certificate_der: Vec<u8>,
        now_unix: u64,
    ) -> Self {
        let mut token = [0u8; 32];
        rand::rng().fill_bytes(&mut token);
        Self {
            protocol: crate::PROTOCOL_MAJOR,
            id: Uuid::new_v4(),
            endpoints,
            host_fingerprint,
            host_certificate_der,
            token,
            issued_at_unix: now_unix,
            expires_at_unix: now_unix + INVITATION_LIFETIME_SECS,
        }
    }

    pub fn encode(&self) -> String {
        let json = serde_json::to_vec(self).expect("Invitation is serializable");
        format!("{PREFIX}{}", URL_SAFE_NO_PAD.encode(json))
    }

    pub fn decode(encoded: &str, now_unix: u64) -> Result<Self, InvitationError> {
        let body = encoded
            .strip_prefix(PREFIX)
            .ok_or(InvitationError::InvalidEncoding)?;
        let bytes = URL_SAFE_NO_PAD
            .decode(body)
            .map_err(|_| InvitationError::InvalidEncoding)?;
        let invite: Self =
            serde_json::from_slice(&bytes).map_err(|_| InvitationError::InvalidEncoding)?;
        invite.validate(now_unix)?;
        Ok(invite)
    }

    pub fn validate(&self, now_unix: u64) -> Result<(), InvitationError> {
        if self.protocol != crate::PROTOCOL_MAJOR {
            return Err(InvitationError::Version(self.protocol));
        }
        if self.endpoints.is_empty() {
            return Err(InvitationError::NoEndpoints);
        }
        if self.host_certificate_der.is_empty() || self.host_fingerprint.is_empty() {
            return Err(InvitationError::InvalidEncoding);
        }
        if self.host_fingerprint != certificate_fingerprint(&self.host_certificate_der) {
            return Err(InvitationError::InvalidEncoding);
        }
        if self.expires_at_unix < self.issued_at_unix
            || self.expires_at_unix - self.issued_at_unix > INVITATION_LIFETIME_SECS
        {
            return Err(InvitationError::InvalidTime);
        }
        if now_unix > self.expires_at_unix {
            return Err(InvitationError::Expired);
        }
        Ok(())
    }

    pub fn token_matches(&self, candidate: &[u8]) -> bool {
        if candidate.len() != self.token.len() {
            return false;
        }
        // Constant-time with respect to token contents.
        candidate
            .iter()
            .zip(self.token)
            .fold(0u8, |diff, (a, b)| diff | (a ^ b))
            == 0
    }

    /// Token presented once, inside the certificate-pinned TLS connection.
    pub fn pairing_token(&self) -> [u8; 32] {
        self.token
    }
}

pub fn certificate_fingerprint(certificate_der: &[u8]) -> String {
    let digest = Sha256::digest(certificate_der);
    let hex = digest
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    format!("sha256:{hex}")
}

mod token_encoding {
    use super::*;
    use serde::{Deserializer, Serializer};
    pub fn serialize<S: Serializer>(value: &[u8; 32], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&URL_SAFE_NO_PAD.encode(value))
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<[u8; 32], D::Error> {
        let value = String::deserialize(deserializer)?;
        let bytes = URL_SAFE_NO_PAD
            .decode(value)
            .map_err(serde::de::Error::custom)?;
        bytes
            .try_into()
            .map_err(|_| serde::de::Error::custom("token must be 32 bytes"))
    }
}

mod certificate_encoding {
    use super::*;
    use serde::{Deserializer, Serializer};
    pub fn serialize<S: Serializer>(value: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&URL_SAFE_NO_PAD.encode(value))
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        let value = String::deserialize(deserializer)?;
        URL_SAFE_NO_PAD
            .decode(value)
            .map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn invitation_round_trip_and_expiry() {
        let i = Invitation::issue(
            vec!["192.0.2.1:49812".into()],
            certificate_fingerprint(&[1, 2, 3]),
            vec![1, 2, 3],
            1_000,
        );
        let decoded = Invitation::decode(&i.encode(), 1_100).unwrap();
        assert_eq!(decoded.id, i.id);
        assert_eq!(
            Invitation::decode(&i.encode(), 1_121),
            Err(InvitationError::Expired)
        );
        assert!(i.token_matches(&i.pairing_token()));
        assert!(!i.token_matches(&[0; 32]));
    }

    #[test]
    fn certificate_tampering_invalidates_invitation() {
        let mut i = Invitation::issue(
            vec!["192.0.2.1:49812".into()],
            certificate_fingerprint(&[1, 2, 3]),
            vec![1, 2, 3],
            1_000,
        );
        i.host_certificate_der[0] ^= 1;
        assert_eq!(
            Invitation::decode(&i.encode(), 1_001),
            Err(InvitationError::InvalidEncoding)
        );
    }
}
