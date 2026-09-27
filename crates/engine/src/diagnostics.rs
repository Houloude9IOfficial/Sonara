use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Diagnostics {
    pub schema_version: u8,
    pub generated_at_unix: u64,
    pub app_version: String,
    pub platform: String,
    pub interface: String,
    pub route: String,
    pub timing_quality: String,
    pub rtt_p50_ms: f64,
    pub rtt_p95_ms: f64,
    pub alignment_p95_ms: f64,
    pub loss_percent: f64,
    pub drift_ppm: f64,
    pub buffer_ms: f64,
    pub underruns: u64,
}

impl Diagnostics {
    pub fn scrubbed_example(now: u64) -> Self {
        Self {
            schema_version: 1,
            generated_at_unix: now,
            app_version: env!("CARGO_PKG_VERSION").into(),
            platform: std::env::consts::OS.into(),
            interface: "not measured".into(),
            route: "not measured".into(),
            timing_quality: "unknown".into(),
            rtt_p50_ms: 0.0,
            rtt_p95_ms: 0.0,
            alignment_p95_ms: 0.0,
            loss_percent: 0.0,
            drift_ppm: 0.0,
            buffer_ms: 0.0,
            underruns: 0,
        }
    }
}
