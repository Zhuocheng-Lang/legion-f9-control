//! 交换策略。

use std::time::Duration;

/// 单次交换策略。实现不得在超时后对**写**自动重试（SPEC §14）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExchangePolicy {
    pub timeout: Duration,
}

impl Default for ExchangePolicy {
    fn default() -> Self {
        Self {
            timeout: Duration::from_secs(2),
        }
    }
}

impl ExchangePolicy {
    pub fn with_timeout(timeout: Duration) -> Self {
        Self { timeout }
    }
}
