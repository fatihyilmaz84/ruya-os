//! What every service with ADR-026 v2 jobs needs the same way (RUY-29): the smoothed download
//! rate of a job (`rate`) and the per-day totals behind `GetDownloadStats` (`ledger`). Pure apart
//! from `ledger::load`; the caller owns the file's path, how long days are kept, and writing it.

pub mod ledger;
pub mod rate;
