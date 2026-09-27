use thiserror::Error;

pub const HEADER_LEN: usize = 32;
pub const PCM16_KIND: u8 = 1;
pub const MAX_FRAMES_PER_PACKET: u16 = 480;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioPacket {
    pub version: u8,
    pub kind: u8,
    pub frame_count: u16,
    pub stream_id: u32,
    pub epoch: u32,
    pub sequence: u32,
    pub first_frame: u64,
    pub source_time_ns: u64,
    /// Interleaved, signed little-endian stereo PCM.
    pub payload: Vec<u8>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PacketError {
    #[error("datagram is shorter than the 32-byte header")]
    Truncated,
    #[error("unsupported protocol version {0}")]
    Version(u8),
    #[error("unsupported audio kind {0}")]
    Kind(u8),
    #[error("frame count {0} is outside 1..={MAX_FRAMES_PER_PACKET}")]
    FrameCount(u16),
    #[error("payload has {actual} bytes, expected {expected}")]
    PayloadLength { actual: usize, expected: usize },
}

impl AudioPacket {
    pub fn encode(&self) -> Result<Vec<u8>, PacketError> {
        self.validate()?;
        let mut out = Vec::with_capacity(HEADER_LEN + self.payload.len());
        out.push(self.version);
        out.push(self.kind);
        out.extend_from_slice(&self.frame_count.to_be_bytes());
        out.extend_from_slice(&self.stream_id.to_be_bytes());
        out.extend_from_slice(&self.epoch.to_be_bytes());
        out.extend_from_slice(&self.sequence.to_be_bytes());
        out.extend_from_slice(&self.first_frame.to_be_bytes());
        out.extend_from_slice(&self.source_time_ns.to_be_bytes());
        out.extend_from_slice(&self.payload);
        Ok(out)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, PacketError> {
        if bytes.len() < HEADER_LEN {
            return Err(PacketError::Truncated);
        }
        let packet = Self {
            version: bytes[0],
            kind: bytes[1],
            frame_count: u16::from_be_bytes(bytes[2..4].try_into().unwrap()),
            stream_id: u32::from_be_bytes(bytes[4..8].try_into().unwrap()),
            epoch: u32::from_be_bytes(bytes[8..12].try_into().unwrap()),
            sequence: u32::from_be_bytes(bytes[12..16].try_into().unwrap()),
            first_frame: u64::from_be_bytes(bytes[16..24].try_into().unwrap()),
            source_time_ns: u64::from_be_bytes(bytes[24..32].try_into().unwrap()),
            payload: bytes[32..].to_vec(),
        };
        packet.validate()?;
        Ok(packet)
    }

    pub fn validate(&self) -> Result<(), PacketError> {
        if self.version != crate::PROTOCOL_MAJOR {
            return Err(PacketError::Version(self.version));
        }
        if self.kind != PCM16_KIND {
            return Err(PacketError::Kind(self.kind));
        }
        if !(1..=MAX_FRAMES_PER_PACKET).contains(&self.frame_count) {
            return Err(PacketError::FrameCount(self.frame_count));
        }
        let expected = self.frame_count as usize * 2 * 2;
        if self.payload.len() != expected {
            return Err(PacketError::PayloadLength {
                actual: self.payload.len(),
                expected,
            });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn example() -> AudioPacket {
        AudioPacket {
            version: 1,
            kind: PCM16_KIND,
            frame_count: 240,
            stream_id: 7,
            epoch: 2,
            sequence: u32::MAX,
            first_frame: 123_456,
            source_time_ns: 9_876_543,
            payload: vec![0x55; 960],
        }
    }

    #[test]
    fn round_trip_uses_fixed_network_order_header() {
        let bytes = example().encode().unwrap();
        assert_eq!(bytes.len(), 992);
        assert_eq!(&bytes[2..4], &[0, 240]);
        assert_eq!(AudioPacket::decode(&bytes).unwrap(), example());
    }

    #[test]
    fn rejects_bad_payload_and_version() {
        let mut p = example();
        p.payload.pop();
        assert!(matches!(p.encode(), Err(PacketError::PayloadLength { .. })));
        let mut bytes = example().encode().unwrap();
        bytes[0] = 2;
        assert_eq!(AudioPacket::decode(&bytes), Err(PacketError::Version(2)));
    }
}
