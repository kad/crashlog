// Copyright (C) 2025 Intel Corporation
// SPDX-License-Identifier: MIT

//! Information extracted alongside the Crash Log records.

#[cfg(not(feature = "std"))]
use alloc::vec::Vec;
#[cfg(not(feature = "std"))]
use alloc::{fmt, format, string::String};
#[cfg(feature = "std")]
use std::fmt;

use crate::cper::CperSectionBody;
use crate::source::CrashLogSource;

/// Crash Log Metadata
#[derive(Default)]
pub struct Metadata {
    /// Name of the computer where the Crash Log has been extracted from.
    pub computer: Option<String>,
    /// Name of the source where the Crash Log has been extracted from.
    pub source: Option<CrashLogSource>,
    /// Time of the extraction, used as a fallback when no hardware timestamp could be found in
    /// the Crash Log records.
    pub time: Option<Time>,
    /// Type of the records found in the Crash Log (e.g. "Punit", "PCODE", "MCA"...).
    ///
    /// A single Crash Log can contain records of several different types, in which case they are
    /// all listed here in the order they were first found.
    pub record_types: Vec<&'static str>,
    /// Hardware timestamp of when the crash occurred, extracted from the record headers.
    ///
    /// This takes precedence over [`Metadata::time`] when building a human-readable
    /// representation of the metadata, since it reflects the actual time of the crash rather
    /// than the time of the extraction.
    pub hardware_timestamp: Option<u64>,
    /// When the Crash Log is extracted from a CPER, this field stores the extra CPER sections that
    /// could be read from the CPER structure.
    pub extra_cper_sections: Vec<CperSectionBody>,
}

/// Crash Log Extraction Time
pub struct Time {
    pub year: u16,
    pub month: u8,
    pub day: u8,
    pub hour: u8,
    pub minute: u8,
    pub second: u8,
    pub millisecond: u16,
}

#[cfg(feature = "std")]
impl Time {
    /// Returns the current wall-clock time, expressed in UTC.
    ///
    /// This is used to record when the Crash Log was collected.
    pub fn now() -> Option<Self> {
        let duration = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .ok()?;
        let secs = duration.as_secs();
        let millisecond = duration.subsec_millis() as u16;

        // Convert the Unix timestamp into a broken-down UTC calendar date/time without pulling in
        // an external date/time crate.
        let days = secs / 86400;
        let rem = secs % 86400;
        let hour = (rem / 3600) as u8;
        let minute = ((rem % 3600) / 60) as u8;
        let second = (rem % 60) as u8;

        let mut z = days as i64 + 719468;
        let era = if z >= 0 { z } else { z - 146096 } / 146097;
        z -= era * 146097;
        let doe = z as u64;
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        let y = yoe as i64 + era * 400;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let day = (doy - (153 * mp + 2) / 5 + 1) as u8;
        let month = if mp < 10 { mp + 3 } else { mp - 9 } as u8;
        let year = if month <= 2 { y + 1 } else { y } as u16;

        Some(Time {
            year,
            month,
            day,
            hour,
            minute,
            second,
            millisecond,
        })
    }
}

impl fmt::Display for Metadata {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let mut parts: Vec<String> = Vec::new();

        if let Some(computer) = self.computer.as_ref() {
            parts.push(computer.clone());
        }

        if let Some(source) = self.source.as_ref() {
            parts.push(format!("{source}"));
        }

        if !self.record_types.is_empty() {
            parts.push(self.record_types.join("+"));
        }

        match self.time.as_ref() {
            Some(time) => parts.push(format!("{time}")),
            None => parts.push(String::from("unknown-time")),
        }

        // The hardware timestamp embedded in the record header is an optional, additional
        // component: its unit/epoch aren't documented, so it's kept as a raw value rather than
        // being converted to a human-readable date.
        if let Some(timestamp) = self.hardware_timestamp {
            parts.push(format!("hw0x{timestamp:x}"));
        }

        if parts.is_empty() {
            write!(f, "unnamed")
        } else {
            write!(f, "{}", parts.join("-"))
        }
    }
}

impl fmt::Display for Time {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        // ISO 8601 basic format (no colons, filesystem-safe), UTC, with millisecond precision.
        write!(
            f,
            "{:04}{:02}{:02}T{:02}{:02}{:02}.{:03}Z",
            self.year, self.month, self.day, self.hour, self.minute, self.second, self.millisecond
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_unnamed() {
        assert_eq!(Metadata::default().to_string(), "unknown-time");
    }

    #[test]
    fn display_record_types_and_hardware_timestamp() {
        let metadata = Metadata {
            record_types: vec!["Punit", "MCA"],
            time: Some(Time {
                year: 2026,
                month: 1,
                day: 2,
                hour: 3,
                minute: 4,
                second: 5,
                millisecond: 123,
            }),
            hardware_timestamp: Some(0x1234),
            ..Metadata::default()
        };

        assert_eq!(
            metadata.to_string(),
            "Punit+MCA-20260102T030405.123Z-hw0x1234"
        );
    }

    #[test]
    fn display_collection_time_without_hardware_timestamp() {
        let metadata = Metadata {
            record_types: vec!["Punit"],
            time: Some(Time {
                year: 2026,
                month: 1,
                day: 2,
                hour: 3,
                minute: 4,
                second: 5,
                millisecond: 0,
            }),
            ..Metadata::default()
        };

        assert_eq!(metadata.to_string(), "Punit-20260102T030405.000Z");
    }

    #[cfg(feature = "std")]
    #[test]
    fn time_now_returns_a_time() {
        assert!(Time::now().is_some());
    }
}
