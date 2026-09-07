//! 指数退避，含 jitter 与上限（SPEC §10.3）。

use std::time::Duration;

#[derive(Debug, Clone)]
pub struct Backoff {
    base: Duration,
    max: Duration,
    current: Duration,
    jitter_ratio: f64,
}

impl Backoff {
    pub fn new(base: Duration, max: Duration) -> Self {
        Self {
            base,
            max,
            current: base,
            jitter_ratio: 0.2,
        }
    }

    /// 计算下一次等待时长； jitter 在 ±ratio 之间。
    /// `rand01` 由调用者提供（便于测试确定性）。
    pub fn next(&mut self, rand01: f64) -> Duration {
        let jitter = 1.0 + self.jitter_ratio * (rand01 * 2.0 - 1.0);
        let wait = self.current.mul_f64(jitter.clamp(0.0, f64::MAX));
        // 增长当前基准，封顶 max。
        self.current = std::cmp::min(self.current.mul_f64(2.0), self.max);
        wait
    }

    pub fn reset(&mut self) {
        self.current = self.base;
    }
}

impl Default for Backoff {
    fn default() -> Self {
        Self::new(Duration::from_millis(500), Duration::from_secs(30))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grows_exponentially_and_caps() {
        let mut b = Backoff::new(Duration::from_millis(100), Duration::from_millis(1000));
        let mut last = Duration::ZERO;
        for i in 0..8 {
            let w = b.next(0.5); // jitter = 1.0
            assert!(
                w >= last.saturating_sub(Duration::from_millis(1)),
                "iteration {i}"
            );
            last = w;
        }
        assert_eq!(last, Duration::from_millis(1000));
    }

    #[test]
    fn jitter_bounds() {
        let mut b = Backoff::new(Duration::from_secs(1), Duration::from_secs(60));
        let w0 = b.next(0.0);
        assert_eq!(w0, Duration::from_millis(800));
        let mut b2 = Backoff::new(Duration::from_secs(1), Duration::from_secs(60));
        let w1 = b2.next(1.0);
        assert_eq!(w1, Duration::from_millis(1200));
    }

    #[test]
    fn reset_restores_base() {
        let mut b = Backoff::new(Duration::from_millis(100), Duration::from_secs(10));
        for _ in 0..5 {
            b.next(0.5);
        }
        b.reset();
        assert_eq!(b.next(0.5), Duration::from_millis(100));
    }
}
