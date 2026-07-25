//! Contract ndjson writer (see `docs/plugin-contract.md`).

use std::io::Write;

use serde::Serialize;

/// Cairn drops any line longer than this, so a too-long line is a lost
/// sample rather than a soft error — we shed detections to stay under it.
pub const MAX_LINE_BYTES: usize = 8192;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Det {
    pub label: String,
    pub score: f64,
    pub bbox: [f64; 4],
}

#[derive(Serialize)]
struct Line<'a> {
    camera_id: &'a str,
    pts: i64,
    dets: &'a [Det],
}

/// Serialize one contract line, shedding the lowest-scoring detections until
/// it fits the byte budget. Returns the line and how many dets survived.
///
/// Detections arrive sorted by score, so truncation drops the least
/// interesting ones. A line with zero dets is emitted even if it somehow
/// still exceeds the budget: a valid oversized line is dropped by Cairn, a
/// truncated one would be malformed for every consumer.
pub fn line(camera_id: &str, pts: i64, dets: &[Det]) -> (String, usize) {
    let mut kept = dets.len();
    loop {
        let json = serde_json::to_string(&Line {
            camera_id,
            pts,
            dets: &dets[..kept],
        })
        .expect("contract line is always serializable");
        // `<=`: Cairn reads with erlang line mode `{:line, 8192}`, whose limit
        // applies to the line data excluding the newline delimiter — a JSON
        // payload of exactly 8192 bytes is still delivered whole.
        if kept == 0 || json.len() <= MAX_LINE_BYTES {
            return (json, kept);
        }
        kept -= 1;
    }
}

pub fn emit(out: &mut impl Write, camera_id: &str, pts: i64, dets: &[Det]) -> std::io::Result<()> {
    let (json, kept) = line(camera_id, pts, dets);
    if kept < dets.len() {
        eprintln!(
            "line budget: dropped {} of {} dets at pts {pts}",
            dets.len() - kept,
            dets.len()
        );
    }
    out.write_all(json.as_bytes())?;
    out.write_all(b"\n")?;
    out.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn det(label: &str, score: f64) -> Det {
        Det {
            label: label.to_string(),
            score,
            bbox: [0.1234, 0.5678, 0.25, 0.5],
        }
    }

    #[test]
    fn emits_contract_shape() {
        let (json, kept) = line("front_door", 90000, &[det("person", 0.87)]);
        assert_eq!(kept, 1);
        assert_eq!(
            json,
            r#"{"camera_id":"front_door","pts":90000,"dets":[{"label":"person","score":0.87,"bbox":[0.1234,0.5678,0.25,0.5]}]}"#
        );
    }

    #[test]
    fn empty_dets_are_valid() {
        let (json, kept) = line("cam", 0, &[]);
        assert_eq!(kept, 0);
        assert_eq!(json, r#"{"camera_id":"cam","pts":0,"dets":[]}"#);
    }

    #[test]
    fn sheds_dets_to_fit_the_budget() {
        let dets: Vec<Det> = (0..200)
            .map(|i| det(&format!("label{i:03}"), 0.9))
            .collect();
        let (json, kept) = line("cam", 1, &dets);
        assert!(kept > 0 && kept < dets.len());
        assert!(json.len() <= MAX_LINE_BYTES);
        assert!(serde_json::from_str::<serde_json::Value>(&json).is_ok());
    }

    #[test]
    fn writes_one_flushed_line() {
        let mut out = Vec::new();
        emit(&mut out, "cam", 42, &[det("car", 0.5)]).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert_eq!(text.matches('\n').count(), 1);
        assert!(text.ends_with('\n'));
    }
}
