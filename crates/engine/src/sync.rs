use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct ClockExchange {
    pub t1: f64,
    pub t2: f64,
    pub t3: f64,
    pub t4: f64,
}

impl ClockExchange {
    pub fn rtt(self) -> f64 {
        (self.t4 - self.t1) - (self.t3 - self.t2)
    }
    pub fn offset(self) -> f64 {
        ((self.t2 - self.t1) + (self.t3 - self.t4)) / 2.0
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct ClockModel {
    pub rate: f64,
    pub offset_seconds: f64,
    pub uncertainty_seconds: f64,
    pub samples: usize,
}

#[derive(Debug, Default)]
pub struct ClockEstimator {
    samples: VecDeque<(f64, f64, f64)>,
}

impl ClockEstimator {
    pub fn observe(&mut self, x: ClockExchange) -> bool {
        let rtt = x.rtt();
        if !rtt.is_finite() || !(0.0..=2.0).contains(&rtt) || !x.offset().is_finite() {
            return false;
        }
        self.samples.push_back((x.t1, x.offset(), rtt));
        while let Some((time, _, _)) = self.samples.front() {
            if x.t1 - time > 60.0 {
                self.samples.pop_front();
            } else {
                break;
            }
        }
        true
    }

    pub fn model(&self) -> Option<ClockModel> {
        if self.samples.is_empty() {
            return None;
        }
        let mut rtts: Vec<_> = self.samples.iter().map(|x| x.2).collect();
        rtts.sort_by(f64::total_cmp);
        let cutoff = rtts[((rtts.len() as f64 * 0.35).ceil() as usize).saturating_sub(1)];
        let chosen: Vec<_> = self
            .samples
            .iter()
            .filter(|x| x.2 <= cutoff * 1.25 + 1e-6)
            .collect();
        let mean_offset = chosen.iter().map(|x| x.1).sum::<f64>() / chosen.len() as f64;
        let span = chosen.last().unwrap().0 - chosen.first().unwrap().0;
        let (rate, intercept) = if chosen.len() >= 8 && span >= 5.0 {
            let x0 = chosen.iter().map(|x| x.0).sum::<f64>() / chosen.len() as f64;
            let y0 = mean_offset;
            let denominator = chosen.iter().map(|x| (x.0 - x0).powi(2)).sum::<f64>();
            let slope = if denominator > 0.0 {
                chosen.iter().map(|x| (x.0 - x0) * (x.1 - y0)).sum::<f64>() / denominator
            } else {
                0.0
            };
            (1.0 + slope, y0 - slope * x0)
        } else {
            (1.0, mean_offset)
        };
        let variance = chosen
            .iter()
            .map(|x| {
                let expected_offset = (rate - 1.0) * x.0 + intercept;
                (x.1 - expected_offset).powi(2)
            })
            .sum::<f64>()
            / chosen.len() as f64;
        Some(ClockModel {
            rate,
            offset_seconds: intercept,
            uncertainty_seconds: variance.sqrt() + cutoff / 2.0,
            samples: chosen.len(),
        })
    }
}

#[derive(Debug, Clone)]
pub struct DriftController {
    filtered_error: f64,
    integral: f64,
    output_ppm: f64,
}

impl Default for DriftController {
    fn default() -> Self {
        Self {
            filtered_error: 0.0,
            integral: 0.0,
            output_ppm: 0.0,
        }
    }
}

impl DriftController {
    pub fn update(&mut self, error_seconds: f64, feed_forward_ppm: f64, dt_seconds: f64) -> f64 {
        let alpha = 1.0 - (-dt_seconds / 1.0).exp();
        self.filtered_error += alpha * (error_seconds - self.filtered_error);
        self.integral = (self.integral + self.filtered_error * dt_seconds).clamp(-1.0, 1.0);
        let requested = (feed_forward_ppm
            + (0.05 * self.filtered_error + 0.0005 * self.integral) * 1_000_000.0)
            .clamp(-500.0, 500.0);
        let max_step = 20.0 * dt_seconds;
        self.output_ppm += (requested - self.output_ppm).clamp(-max_step, max_step);
        self.output_ppm
    }
}

pub fn synchronized_delay_ms(requirements_ms: &[f64], ceiling_ms: f64) -> Option<u32> {
    let maximum = requirements_ms.iter().copied().fold(0.0, f64::max);
    let rounded = (maximum / 5.0).ceil() * 5.0;
    (rounded <= ceiling_ms && rounded <= 1_000.0).then_some(rounded as u32)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exchange_math() {
        let x = ClockExchange {
            t1: 1.0,
            t2: 1.106,
            t3: 1.107,
            t4: 1.013,
        };
        assert!((x.rtt() - 0.012).abs() < 1e-9);
        assert!((x.offset() - 0.1).abs() < 1e-9);
    }
    #[test]
    fn delay_rounds_and_rejects() {
        assert_eq!(synchronized_delay_ms(&[83.0, 91.0], 150.0), Some(95));
        assert_eq!(synchronized_delay_ms(&[151.0], 150.0), None);
    }
    #[test]
    fn positive_lateness_consumes_faster() {
        let mut c = DriftController::default();
        let mut out = 0.0;
        for _ in 0..1000 {
            out = c.update(0.010, 0.0, 0.1);
        }
        assert!(out > 0.0);
        assert!(out <= 500.0);
    }
}
