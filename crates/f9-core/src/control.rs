//! 温控守护控制逻辑：曲线、滞回、最短驻留与降级状态机（SPEC §13.4、§13.5）。
//!
//! 时间以**单调时钟**毫秒数传入，不依赖系统墙钟。

use f9_protocol::Gear;

/// daemon 状态机阶段（SPEC §13.5）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DaemonPhase {
    Starting,
    Discovering,
    /// 已连接但尚未写入（先读后写）。
    ConnectedReadOnly,
    Controlling,
    /// 连续失败后只读降级：只探测读取，不发送配置写。
    DegradedReadOnly,
    Reconnecting,
    Stopped,
}

/// 曲线点：温度达到 `at_c` 时进入 `gear`。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CurvePoint {
    pub at_c: f64,
    pub gear: Gear,
}

/// 控制配置。
#[derive(Debug, Clone)]
pub struct ControlConfig {
    /// 最短驻留：任意两次实际写入的最小间隔。
    pub min_dwell_ms: u64,
    /// 降挡滞回：需低于当前挡触发阈值至少该差值。
    pub hysteresis_c: f64,
    /// daemon 中 turbo 默认禁用。
    pub allow_turbo: bool,
    /// 连续失败阈值（默认 3）。
    pub failure_threshold: u8,
    /// 按 `at_c` 升序排列的曲线。
    pub curve: Vec<CurvePoint>,
}

impl Default for ControlConfig {
    fn default() -> Self {
        // SPEC §13.2 默认曲线。
        Self {
            min_dwell_ms: 15_000,
            hysteresis_c: 3.0,
            allow_turbo: false,
            failure_threshold: 3,
            curve: vec![
                CurvePoint {
                    at_c: 0.0,
                    gear: Gear::Quiet,
                },
                CurvePoint {
                    at_c: 50.0,
                    gear: Gear::Balanced,
                },
                CurvePoint {
                    at_c: 60.0,
                    gear: Gear::Beast,
                },
            ],
        }
    }
}

impl ControlConfig {
    /// 校验配置（启动前完整校验，错误配置不得部分生效）。
    pub fn validate(&self) -> Result<(), String> {
        if self.curve.is_empty() {
            return Err("curve must not be empty".into());
        }
        if self.curve.windows(2).any(|w| w[0].at_c >= w[1].at_c) {
            return Err("curve must be strictly increasing in at_c".into());
        }
        if self.curve[0].at_c != 0.0 {
            return Err("first curve point must start at 0.0 °C".into());
        }
        if !(self.hysteresis_c >= 0.0 && self.hysteresis_c < 50.0) {
            return Err("hysteresis_c out of range".into());
        }
        if self.min_dwell_ms == 0 {
            return Err("min_dwell must be positive".into());
        }
        Ok(())
    }
}

/// 单次控制决策。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// 不做任何事。
    None,
    /// 需要写入该挡位（调用方负责执行完整写事务）。
    Write(Gear),
}

/// 纯逻辑控制器：不接触 I/O，便于虚拟时钟测试。
pub struct Controller {
    cfg: ControlConfig,
    phase: DaemonPhase,
    /// 最近一次读回/写入的设备挡位。
    device_gear: Option<Gear>,
    /// 最近一次**实际写入**时刻（单调毫秒）。
    last_write_at: Option<u64>,
    /// 连续失败计数。
    failures: u8,
    /// turbo 是否因 allow_turbo=false 被钳制到 beast。
    turbo_clamped: bool,
}

impl Controller {
    pub fn new(cfg: ControlConfig) -> Self {
        Self {
            cfg,
            phase: DaemonPhase::Starting,
            device_gear: None,
            last_write_at: None,
            failures: 0,
            turbo_clamped: false,
        }
    }

    pub fn phase(&self) -> DaemonPhase {
        self.phase
    }

    pub fn turbo_clamped(&self) -> bool {
        self.turbo_clamped
    }

    pub fn failures(&self) -> u8 {
        self.failures
    }

    pub fn config(&self) -> &ControlConfig {
        &self.cfg
    }

    pub fn set_phase(&mut self, phase: DaemonPhase) {
        self.phase = phase;
    }

    /// 建立连接：进入 ConnectedReadOnly；在首次成功读取之前绝不写入。
    pub fn on_connected(&mut self) {
        self.phase = DaemonPhase::ConnectedReadOnly;
    }

    pub fn on_disconnected(&mut self) {
        self.phase = DaemonPhase::Reconnecting;
    }

    pub fn on_stopped(&mut self) {
        self.phase = DaemonPhase::Stopped;
    }

    /// 曲线目标挡位（不考虑滞回/驻留）。
    pub fn curve_target(&self, temp_c: f64) -> Option<Gear> {
        self.cfg
            .curve
            .iter()
            .rfind(|p| temp_c >= p.at_c)
            .map(|p| p.gear)
    }

    /// 当前挡位的触发阈值（曲线上进入该挡的最低 at_c）。
    fn activation_threshold(&self, gear: Gear) -> Option<f64> {
        self.cfg
            .curve
            .iter()
            .filter(|p| p.gear == gear)
            .map(|p| p.at_c)
            .fold(None, |acc: Option<f64>, t| {
                Some(match acc {
                    None => t,
                    Some(a) => a.min(t),
                })
            })
    }

    /// 温度轮询决策。
    ///
    /// - `temp_c=None`：温度源消失，停止写入，不猜测 0 °C；
    /// - `device_gear=None`：尚未成功读取设置，绝不写入；
    /// - 滞回：降挡需低于当前挡触发阈值至少 hysteresis；
    /// - 驻留：距上次实际写入不足 min_dwell 不写；
    /// - 降级/重连阶段只读。
    pub fn on_temperature(&mut self, temp_c: Option<f64>, now_ms: u64) -> Decision {
        if matches!(
            self.phase,
            DaemonPhase::DegradedReadOnly
                | DaemonPhase::ConnectedReadOnly
                | DaemonPhase::Reconnecting
                | DaemonPhase::Stopped
                | DaemonPhase::Starting
                | DaemonPhase::Discovering
        ) {
            return Decision::None;
        }
        let temp = match temp_c {
            Some(t) if t.is_finite() && (-100.0..=200.0).contains(&t) => t,
            // NaN、不合理值：停止写入。
            _ => return Decision::None,
        };
        // 目标挡位。
        let mut target = match self.curve_target(temp) {
            Some(g) => g,
            None => return Decision::None,
        };
        // daemon 默认禁用 turbo：钳制到 beast。
        if target == Gear::Turbo && !self.cfg.allow_turbo {
            target = Gear::Beast;
            self.turbo_clamped = true;
        }
        // 尚未读到设备挡位：不写（连接后先读）。
        let current = match self.device_gear {
            Some(g) => g,
            None => return Decision::None,
        };
        if target == current {
            return Decision::None;
        }
        // 降挡滞回：目标低于当前挡时，要求温度低于当前挡触发阈值 - hysteresis。
        if (target as u8) < (current as u8) {
            let threshold = match self.activation_threshold(current) {
                Some(t) => t,
                None => return Decision::None,
            };
            if temp >= threshold - self.cfg.hysteresis_c {
                return Decision::None;
            }
        }
        // 最短驻留。
        if let Some(last) = self.last_write_at
            && now_ms.saturating_sub(last) < self.cfg.min_dwell_ms
        {
            return Decision::None;
        }
        Decision::Write(target)
    }

    /// 读回成功：清零失败计数；降级后一次完整读取成功即恢复控制，
    /// 恢复前由调用方重新计算目标（下一次 on_temperature）。
    pub fn on_gear_read_ok(&mut self, gear: Gear) {
        self.failures = 0;
        self.device_gear = Some(gear);
        if self.phase == DaemonPhase::DegradedReadOnly
            || self.phase == DaemonPhase::ConnectedReadOnly
        {
            self.phase = DaemonPhase::Controlling;
        }
    }

    pub fn on_read_failed(&mut self) {
        self.failures = self.failures.saturating_add(1);
        if self.failures >= self.cfg.failure_threshold {
            self.phase = DaemonPhase::DegradedReadOnly;
        }
    }

    /// 写入开始（记录驻留起点：写入成功才算；此处仅用于状态迁移）。
    pub fn on_write_started(&mut self) {
        if self.phase == DaemonPhase::ConnectedReadOnly {
            self.phase = DaemonPhase::Controlling;
        }
    }

    /// 写入成功并读回验证。
    pub fn on_write_ok(&mut self, gear: Gear, now_ms: u64) {
        self.failures = 0;
        self.device_gear = Some(gear);
        self.last_write_at = Some(now_ms);
        self.phase = DaemonPhase::Controlling;
    }

    /// 写入失败：计入连续失败。
    pub fn on_write_failed(&mut self) {
        self.failures = self.failures.saturating_add(1);
        if self.failures >= self.cfg.failure_threshold {
            self.phase = DaemonPhase::DegradedReadOnly;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctrl() -> Controller {
        Controller::new(ControlConfig::default())
    }

    fn connect_and_read(c: &mut Controller, gear: Gear) {
        c.on_connected();
        c.on_gear_read_ok(gear);
    }

    #[test]
    fn default_config_validates() {
        assert!(ControlConfig::default().validate().is_ok());
    }

    #[test]
    fn config_validation_rejects_bad_curves() {
        let mut cfg = ControlConfig::default();
        cfg.curve.clear();
        assert!(cfg.validate().is_err());
        cfg.curve = vec![
            CurvePoint {
                at_c: 50.0,
                gear: Gear::Quiet,
            },
            CurvePoint {
                at_c: 40.0,
                gear: Gear::Beast,
            },
        ];
        assert!(cfg.validate().is_err());
        cfg.curve = vec![CurvePoint {
            at_c: 10.0,
            gear: Gear::Quiet,
        }];
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn curve_target_ladder() {
        let c = ctrl();
        assert_eq!(c.curve_target(0.0), Some(Gear::Quiet));
        assert_eq!(c.curve_target(49.9), Some(Gear::Quiet));
        assert_eq!(c.curve_target(50.0), Some(Gear::Balanced));
        assert_eq!(c.curve_target(59.9), Some(Gear::Balanced));
        assert_eq!(c.curve_target(60.0), Some(Gear::Beast));
        assert_eq!(c.curve_target(95.0), Some(Gear::Beast));
    }

    #[test]
    fn no_write_before_first_read() {
        let mut c = ctrl();
        c.on_connected();
        // 设备挡位未知：绝不立即写。
        assert_eq!(c.on_temperature(Some(80.0), 0), Decision::None);
    }

    #[test]
    fn missing_temperature_stops_writes() {
        let mut c = ctrl();
        connect_and_read(&mut c, Gear::Quiet);
        assert_eq!(c.on_temperature(None, 0), Decision::None);
    }

    #[test]
    fn unreasonable_temperature_stops_writes() {
        let mut c = ctrl();
        connect_and_read(&mut c, Gear::Quiet);
        assert_eq!(c.on_temperature(Some(f64::NAN), 0), Decision::None);
        assert_eq!(c.on_temperature(Some(1000.0), 0), Decision::None);
        assert_eq!(c.on_temperature(Some(-500.0), 0), Decision::None);
    }

    #[test]
    fn writes_on_difference() {
        let mut c = ctrl();
        connect_and_read(&mut c, Gear::Quiet);
        assert_eq!(
            c.on_temperature(Some(65.0), 0),
            Decision::Write(Gear::Beast)
        );
    }

    #[test]
    fn turbo_clamped_when_disabled() {
        // 构造含 turbo 的曲线验证钳制。
        let mut c = Controller::new(ControlConfig {
            allow_turbo: false,
            curve: vec![
                CurvePoint {
                    at_c: 0.0,
                    gear: Gear::Quiet,
                },
                CurvePoint {
                    at_c: 70.0,
                    gear: Gear::Turbo,
                },
            ],
            ..ControlConfig::default()
        });
        connect_and_read(&mut c, Gear::Quiet);
        assert_eq!(
            c.on_temperature(Some(80.0), 0),
            Decision::Write(Gear::Beast)
        );
        assert!(c.turbo_clamped());
    }

    #[test]
    fn hysteresis_blocks_early_downswitch() {
        let mut c = ctrl();
        connect_and_read(&mut c, Gear::Balanced);
        // 50–<60 为 balanced。降到 quiet 需 < 50 - 3 = 47。
        assert_eq!(c.on_temperature(Some(49.0), 20_000), Decision::None);
        assert_eq!(
            c.on_temperature(Some(46.9), 30_000),
            Decision::Write(Gear::Quiet)
        );
    }

    #[test]
    fn dwell_blocks_rapid_rewrites() {
        let mut c = ctrl();
        connect_and_read(&mut c, Gear::Quiet);
        assert_eq!(
            c.on_temperature(Some(65.0), 0),
            Decision::Write(Gear::Beast)
        );
        c.on_write_ok(Gear::Beast, 1_000);
        // 驻留期内不写。
        assert_eq!(c.on_temperature(Some(20.0), 10_000), Decision::None);
        // 驻留结束后按滞回降挡。
        assert_eq!(
            c.on_temperature(Some(20.0), 16_000),
            Decision::Write(Gear::Quiet)
        );
    }

    #[test]
    fn degraded_after_consecutive_failures() {
        let mut c = ctrl();
        connect_and_read(&mut c, Gear::Quiet);
        c.on_read_failed();
        c.on_read_failed();
        assert_ne!(c.phase(), DaemonPhase::DegradedReadOnly);
        c.on_read_failed();
        assert_eq!(c.phase(), DaemonPhase::DegradedReadOnly);
        // 降级后只读：不决策写入。
        assert_eq!(c.on_temperature(Some(90.0), 20_000), Decision::None);
    }

    #[test]
    fn recovery_requires_full_read_then_recompute() {
        let mut c = ctrl();
        connect_and_read(&mut c, Gear::Quiet);
        for _ in 0..3 {
            c.on_read_failed();
        }
        assert_eq!(c.phase(), DaemonPhase::DegradedReadOnly);
        // 一次完整读取成功后恢复。
        c.on_gear_read_ok(Gear::Balanced);
        assert_eq!(c.phase(), DaemonPhase::Controlling);
        // 恢复前重新计算目标：此时温度高，允许写入（驻留已过）。
        assert_eq!(
            c.on_temperature(Some(65.0), 20_000),
            Decision::Write(Gear::Beast)
        );
    }

    #[test]
    fn reconnect_phase_is_read_only() {
        let mut c = ctrl();
        connect_and_read(&mut c, Gear::Quiet);
        c.on_disconnected();
        assert_eq!(c.phase(), DaemonPhase::Reconnecting);
        assert_eq!(c.on_temperature(Some(90.0), 0), Decision::None);
        c.on_connected();
        // 重新连接后未读取，仍不写。
        assert_eq!(c.on_temperature(Some(90.0), 0), Decision::None);
        c.on_gear_read_ok(Gear::Beast);
        assert_eq!(
            c.on_temperature(Some(20.0), 30_000),
            Decision::Write(Gear::Quiet)
        );
    }

    #[test]
    fn daemon_restart_does_not_write_unconditionally() {
        // 重启后无任何读取：不应产生写。
        let mut c = ctrl();
        c.on_connected();
        assert_eq!(c.on_temperature(Some(90.0), 0), Decision::None);
    }
}
