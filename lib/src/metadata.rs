// Copyright (C) 2025 Intel Corporation
// SPDX-License-Identifier: MIT

//! Information extracted alongside the Crash Log records.

#[cfg(not(feature = "std"))]
use alloc::vec::Vec;
#[cfg(not(feature = "std"))]
use alloc::{fmt, string::String};
#[cfg(feature = "std")]
use std::fmt;

use crate::cper::CperSectionBody;

/// Crash Log Metadata
#[derive(Default)]
pub struct Metadata {
    /// Name of the computer where the Crash Log has been extracted from.
    pub computer: Option<String>,
    /// Time of the extraction
    pub time: Option<Time>,
    /// Source of the Crash Log extraction (e.g., PMT endpoint path)
    pub source: Option<String>,
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
}

impl fmt::Display for Metadata {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match (self.computer.as_ref(), self.time.as_ref(), self.source.as_ref()) {
            (Some(computer), Some(time), Some(source)) => write!(f, "{computer}-{time}-{source}"),
            (Some(computer), Some(time), None) => write!(f, "{computer}-{time}"),
            (Some(computer), None, Some(source)) => write!(f, "{computer}-{source}"),
            (None, Some(time), Some(source)) => write!(f, "{time}-{source}"),
            (None, None, Some(source)) => write!(f, "{source}"),
            (None, Some(time), None) => write!(f, "{time}"),
            (Some(computer), None, None) => write!(f, "{computer}"),
            (None, None, None) => write!(f, "unnamed"),
        }
    }
}

impl fmt::Display for Time {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(
            f,
            "{:04}-{:02}-{:02}-{:02}-{:02}",
            self.year, self.month, self.day, self.hour, self.minute
        )
    }
}
