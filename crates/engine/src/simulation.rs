use crate::sync::{ClockEstimator, ClockExchange, DriftController};
use rand::{Rng, SeedableRng, rngs::StdRng};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Scenario {
    pub name: String,
    pub duration_seconds: f64,
    pub seed: u64,
    pub receiver_drift_ppm: f64,
    pub base_one_way_ms: f64,
    pub jitter_ms: f64,
    pub loss_percent: f64,
    pub asymmetry_ms: f64,
}
impl Default for Scenario {
    fn default() -> Self {
        Self {
            name: "good-lan".into(),
            duration_seconds: 60.0,
            seed: 7,
            receiver_drift_ppm: 100.0,
            base_one_way_ms: 2.0,
            jitter_ms: 5.0,
            loss_percent: 1.0,
            asymmetry_ms: 0.0,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct SimulationReport {
    pub scenario: String,
    pub seed: u64,
    pub probes_sent: u64,
    pub probes_received: u64,
    pub loss_percent: f64,
    pub estimated_drift_ppm: f64,
    pub final_rate_correction_ppm: f64,
    pub offset_error_ms: f64,
    pub uncertainty_ms: f64,
    pub timing_quality: String,
}

pub fn run(s: &Scenario) -> SimulationReport {
    let mut rng = StdRng::seed_from_u64(s.seed);
    let mut estimator = ClockEstimator::default();
    let mut controller = DriftController::default();
    let mut sent = 0;
    let mut received = 0;
    let true_offset = 0.120;
    let mut t = 0.0;
    while t < s.duration_seconds {
        sent += 1;
        if rng.random_range(0.0..100.0) >= s.loss_percent {
            let forward =
                s.base_one_way_ms + s.asymmetry_ms / 2.0 + rng.random_range(0.0..s.jitter_ms);
            let reverse =
                s.base_one_way_ms - s.asymmetry_ms / 2.0 + rng.random_range(0.0..s.jitter_ms);
            let map = |host: f64| host * (1.0 + s.receiver_drift_ppm / 1e6) + true_offset;
            let t1 = t;
            let t2 = map(t1 + forward / 1000.0);
            let t3 = t2 + 0.0002;
            let host_response = (t3 - true_offset) / (1.0 + s.receiver_drift_ppm / 1e6);
            let t4 = host_response + reverse / 1000.0;
            if estimator.observe(ClockExchange { t1, t2, t3, t4 }) {
                received += 1;
            }
        }
        t += if t < 2.0 { 0.05 } else { 0.5 };
    }
    let model = estimator.model().unwrap();
    let estimated_drift = (model.rate - 1.0) * 1e6;
    // Compare at the end of the observation window. The model's intercept is
    // extrapolated back to host time zero and is intentionally not itself an
    // accuracy metric when fitting only the rolling 60-second window.
    let estimated_offset_now = (model.rate - 1.0) * t + model.offset_seconds;
    let true_offset_now = true_offset + s.receiver_drift_ppm / 1e6 * t;
    let offset_error = ((estimated_offset_now - true_offset_now) * 1000.0).abs();
    let mut correction = 0.0;
    for _ in 0..600 {
        correction = controller.update(0.001, -s.receiver_drift_ppm, 0.1);
    }
    SimulationReport {
        scenario: s.name.clone(),
        seed: s.seed,
        probes_sent: sent,
        probes_received: received,
        loss_percent: 100.0 * (sent - received) as f64 / sent as f64,
        estimated_drift_ppm: estimated_drift,
        final_rate_correction_ppm: correction,
        offset_error_ms: offset_error,
        uncertainty_ms: model.uncertainty_seconds * 1000.0,
        timing_quality: if s.asymmetry_ms.abs() > 0.5 {
            "estimated-asymmetry-uncertain"
        } else {
            "timestamp-observed"
        }
        .into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn deterministic_and_bounded() {
        let a = run(&Scenario::default());
        let b = run(&Scenario::default());
        assert_eq!(
            serde_json::to_string(&a).unwrap(),
            serde_json::to_string(&b).unwrap()
        );
        assert!((a.estimated_drift_ppm - 100.0).abs() < 25.0);
    }
}
