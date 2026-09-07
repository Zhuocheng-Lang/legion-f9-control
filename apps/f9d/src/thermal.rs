//! f9d 温度源模块。
//! 非 Linux 构建中仅测试使用，允许 dead_code。
#![allow(dead_code)]
//! 温度源（Linux v1，SPEC §13.3）。
//!
//! 1. 优先 CPU package 温度；
//! 2. 支持 `x86_pkg_temp`、`TCPU` 与 coretemp package label；
//! 3. aarch64 通过配置选择明确 thermal zone/hwmon（后续扩展）；
//! 4. 多候选时记录选择结果；
//! 5. 温度源消失时不猜测 0 °C；拒绝 NaN 与不合理值。

use std::path::{Path, PathBuf};

/// 温度源 trait。
pub trait TemperatureSource: Send + Sync {
    /// 读取 CPU 温度（°C）。`None` 表示源消失——调用方必须停止写入。
    fn read_c(&self) -> Option<f64>;
}

/// hwmon 温度源（Linux）。
#[derive(Debug, Clone)]
pub struct HwmonSource {
    /// 选中的 hwmon 输入文件。
    input: PathBuf,
    /// 选中来源（用于日志与测试）。
    pub source_name: String,
}

impl HwmonSource {
    /// 扫描 hwmon，优先级：x86_pkg_temp label > TCPU label > coretemp package label。
    pub fn discover() -> Option<Self> {
        let base = Path::new("/sys/class/hwmon");
        let mut candidates: Vec<(u8, String, PathBuf)> = Vec::new();
        let entries = std::fs::read_dir(base).ok()?;
        for hwmon in entries.flatten() {
            let dir = hwmon.path();
            let chip = std::fs::read_to_string(dir.join("name")).unwrap_or_default();
            let chip = chip.trim().to_owned();
            let tdir = match std::fs::read_dir(&dir) {
                Ok(d) => d,
                Err(_) => continue,
            };
            let mut inputs: Vec<(u32, PathBuf)> = tdir
                .flatten()
                .filter_map(|e| {
                    let name = e.file_name().to_string_lossy().to_string();
                    name.strip_prefix("temp").and_then(|rest| {
                        let idx: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
                        let idx: u32 = idx.parse().ok()?;
                        let after = rest.strip_prefix(&idx.to_string())?;
                        after.strip_suffix("_input")?;
                        Some((idx, e.path()))
                    })
                })
                .collect();
            inputs.sort();
            for (idx, input) in inputs {
                let label_path = dir.join(format!("temp{idx}_label"));
                let label = std::fs::read_to_string(&label_path)
                    .map(|s| s.trim().to_owned())
                    .unwrap_or_default();
                // 优先级：package 级 CPU 温度。
                let priority = if label.eq_ignore_ascii_case("x86_pkg_temp") {
                    0
                } else if label.eq_ignore_ascii_case("TCPU") {
                    1
                } else if chip == "coretemp" && (label.is_empty() || label.contains("Package")) {
                    2
                } else {
                    continue;
                };
                let source_name = format!("{chip}/{label}(temp{idx})");
                candidates.push((priority, source_name, input));
            }
        }
        candidates.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
        let (priority, source_name, input) = candidates.into_iter().next()?;
        tracing::info!(source = %source_name, priority, "选择 CPU 温度源");
        Some(Self { input, source_name })
    }

    /// 由已有路径构造（测试与显式配置用）。
    pub fn from_input(input: PathBuf, source_name: impl Into<String>) -> Self {
        Self {
            input,
            source_name: source_name.into(),
        }
    }
}

impl TemperatureSource for HwmonSource {
    fn read_c(&self) -> Option<f64> {
        let raw = std::fs::read_to_string(&self.input).ok()?;
        let milli_c: f64 = raw.trim().parse().ok()?;
        let c = milli_c / 1000.0;
        // 拒绝 NaN 与不合理值。
        if !c.is_finite() || !(-100.0..=200.0).contains(&c) {
            tracing::warn!(value = c, "温度源返回不合理值，忽略本次采样");
            return None;
        }
        Some(c)
    }
}

/// 非 Linux 平台的温度源：v1 不支持 daemon。
pub struct UnsupportedSource;

impl TemperatureSource for UnsupportedSource {
    fn read_c(&self) -> Option<f64> {
        None
    }
}

/// 按平台选择温度源。
pub fn platform_source() -> Option<Box<dyn TemperatureSource>> {
    #[cfg(target_os = "linux")]
    {
        HwmonSource::discover().map(|s| Box::new(s) as Box<dyn TemperatureSource>)
    }
    #[cfg(not(target_os = "linux"))]
    {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_temp(dir: &Path, value: &str) -> PathBuf {
        let p = dir.join("temp1_input");
        let mut f = std::fs::File::create(&p).unwrap();
        f.write_all(value.as_bytes()).unwrap();
        p
    }

    #[test]
    fn reads_milli_celsius() {
        let dir = tempfile::tempdir().unwrap();
        let p = write_temp(dir.path(), "54321\n");
        let src = HwmonSource::from_input(p, "test");
        assert!((src.read_c().unwrap() - 54.321).abs() < 1e-9);
    }

    #[test]
    fn missing_source_is_none() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("nonexistent_input");
        let src = HwmonSource::from_input(p, "test");
        assert!(src.read_c().is_none());
    }

    #[test]
    fn rejects_nan_and_out_of_range() {
        let dir = tempfile::tempdir().unwrap();
        let p = write_temp(dir.path(), "999999999\n");
        let src = HwmonSource::from_input(p, "test");
        assert!(src.read_c().is_none());
        let dir2 = tempfile::tempdir().unwrap();
        let p2 = write_temp(dir2.path(), "garbage\n");
        let src2 = HwmonSource::from_input(p2, "test");
        assert!(src2.read_c().is_none());
        let dir3 = tempfile::tempdir().unwrap();
        let p3 = write_temp(dir3.path(), "-999999\n");
        let src3 = HwmonSource::from_input(p3, "test");
        assert!(src3.read_c().is_none());
    }
}
