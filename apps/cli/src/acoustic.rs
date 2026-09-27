use anyhow::{Context, Result, bail};
use serde::Serialize;
use std::path::Path;

const ANALYSIS_RATE: u32 = 2_000;
const MAX_ANALYSIS_SECONDS: u32 = 10;

#[derive(Debug, Serialize)]
pub struct AcousticSyncReport {
    pub reference_channel: u16,
    pub target_channel: u16,
    pub offset_ms: f64,
    pub peak_correlation: f64,
    pub peak_to_sidelobe_ratio: f64,
    pub confidence: &'static str,
    pub source_sample_rate: u32,
    pub analyzed_seconds: f64,
}

pub fn measure(
    input: &Path,
    reference_channel: u16,
    target_channel: u16,
    max_offset_ms: u32,
) -> Result<AcousticSyncReport> {
    if max_offset_ms == 0 || max_offset_ms > 1_000 {
        bail!("max offset must be between 1 and 1000 ms");
    }
    let mut reader = hound::WavReader::open(input)
        .with_context(|| format!("opening acoustic recording {}", input.display()))?;
    let spec = reader.spec();
    if spec.sample_format != hound::SampleFormat::Int || spec.bits_per_sample != 16 {
        bail!("acoustic measurement currently requires 16-bit PCM WAV input");
    }
    if reference_channel >= spec.channels || target_channel >= spec.channels {
        bail!(
            "requested channels {reference_channel}/{target_channel}, but recording has {} channels",
            spec.channels
        );
    }
    if reference_channel == target_channel {
        bail!("reference and target channels must be different");
    }

    let frame_limit = u64::from(spec.sample_rate) * u64::from(MAX_ANALYSIS_SECONDS);
    let mut reference = Vec::new();
    let mut target = Vec::new();
    for (index, sample) in reader.samples::<i16>().enumerate() {
        let frame = index as u64 / u64::from(spec.channels);
        if frame >= frame_limit {
            break;
        }
        let channel = index as u16 % spec.channels;
        let normalized = f64::from(sample?) / f64::from(i16::MAX);
        if channel == reference_channel {
            reference.push(normalized);
        } else if channel == target_channel {
            target.push(normalized);
        }
    }
    let downsample = (spec.sample_rate / ANALYSIS_RATE).max(1) as usize;
    let analysis_rate = spec.sample_rate as f64 / downsample as f64;
    let reference = downsample_average(&reference, downsample);
    let target = downsample_average(&target, downsample);
    let length = reference.len().min(target.len());
    if length < analysis_rate as usize / 2 {
        bail!("recording must contain at least 0.5 seconds of both channels");
    }
    let max_lag = ((f64::from(max_offset_ms) * analysis_rate / 1_000.0).ceil() as usize)
        .min(length.saturating_sub(2));
    let (lag, peak, ratio) = estimate_offset(&reference[..length], &target[..length], max_lag)?;
    let confidence = if peak >= 0.65 && ratio >= 1.15 {
        "high"
    } else if peak >= 0.35 && ratio >= 1.05 {
        "medium"
    } else {
        "low"
    };
    Ok(AcousticSyncReport {
        reference_channel,
        target_channel,
        offset_ms: lag as f64 * 1_000.0 / analysis_rate,
        peak_correlation: peak,
        peak_to_sidelobe_ratio: ratio,
        confidence,
        source_sample_rate: spec.sample_rate,
        analyzed_seconds: length as f64 / analysis_rate,
    })
}

fn downsample_average(samples: &[f64], factor: usize) -> Vec<f64> {
    samples
        .chunks(factor)
        .filter(|chunk| chunk.len() == factor)
        .map(|chunk| chunk.iter().sum::<f64>() / chunk.len() as f64)
        .collect()
}

fn estimate_offset(reference: &[f64], target: &[f64], max_lag: usize) -> Result<(isize, f64, f64)> {
    let reference_mean = reference.iter().sum::<f64>() / reference.len() as f64;
    let target_mean = target.iter().sum::<f64>() / target.len() as f64;
    let mut scores = Vec::with_capacity(max_lag * 2 + 1);
    for lag in -(max_lag as isize)..=(max_lag as isize) {
        let start = if lag < 0 { (-lag) as usize } else { 0 };
        let end = reference
            .len()
            .min(target.len().saturating_sub(lag.max(0) as usize));
        if end <= start + 100 {
            continue;
        }
        let mut dot = 0.0;
        let mut left_energy = 0.0;
        let mut right_energy = 0.0;
        for (index, &left_sample) in reference.iter().enumerate().take(end).skip(start) {
            let right_index = (index as isize + lag) as usize;
            let left = left_sample - reference_mean;
            let right = target[right_index] - target_mean;
            dot += left * right;
            left_energy += left * left;
            right_energy += right * right;
        }
        let denominator = (left_energy * right_energy).sqrt();
        if denominator > 1e-12 {
            scores.push((lag, (dot / denominator).abs()));
        }
    }
    let &(best_lag, best_score) = scores
        .iter()
        .max_by(|left, right| left.1.total_cmp(&right.1))
        .context("recording has insufficient signal energy")?;
    let guard = 10isize;
    let sidelobe = scores
        .iter()
        .filter(|(lag, _)| (*lag - best_lag).abs() > guard)
        .map(|(_, score)| *score)
        .fold(0.0, f64::max);
    let ratio = if sidelobe > 1e-9 {
        best_score / sidelobe
    } else {
        f64::INFINITY
    };
    Ok((best_lag, best_score, ratio))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_positive_target_delay() {
        let reference: Vec<_> = (0..4_000)
            .map(|index| {
                let time = index as f64 / ANALYSIS_RATE as f64;
                (2.0 * std::f64::consts::PI * (170.0 + 80.0 * time) * time).sin()
                    * (time * 3.0).min(1.0)
            })
            .collect();
        let delay = 37usize;
        let mut target = vec![0.0; delay];
        target.extend(reference.iter().copied());
        target.truncate(reference.len());
        let (lag, peak, _) = estimate_offset(&reference, &target, 100).unwrap();
        assert_eq!(lag, delay as isize);
        assert!(peak > 0.99);
    }
}
