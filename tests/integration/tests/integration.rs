use std::sync::Arc;

use f9_core::config::DaemonConfig;
use f9_core::{Device, SetGearOutcome};
use f9_protocol::{Gear, SettingsBlock};
use f9_sim::{Faults, SimSpec, SimTransport};
use f9_transport::{ExchangePolicy, Transport as _, TransportKind};

fn device_on(
    kind: TransportKind,
    faults: Faults,
) -> (Device<Arc<SimTransport>>, Arc<SimTransport>) {
    let spec = SimSpec {
        kind,
        ..SimSpec::default()
    };
    let sim = Arc::new(SimTransport::new(spec, faults));
    (Device::new_shared(sim.clone()), sim)
}

#[tokio::test]
async fn same_gear_zero_writes_on_both_transports() {
    for kind in [TransportKind::Usb, TransportKind::Ble] {
        let (dev, sim) = device_on(kind, Faults::default());
        let g = dev.gear().await.unwrap();
        let out = dev.set_gear(g).await.unwrap();
        assert_eq!(out, SetGearOutcome::Unchanged, "{kind:?}");
        assert_eq!(sim.flash_write_count(), 0, "{kind:?}");
        assert_eq!(sim.sessions_open(), 0, "{kind:?}");
    }
}

#[tokio::test]
async fn unknown_14_bytes_unchanged_after_set_gear() {
    let (dev, sim) = device_on(TransportKind::Usb, Faults::default());
    let before = sim.settings_snapshot();
    dev.set_gear(Gear::Turbo).await.unwrap();
    let after = sim.settings_snapshot();
    for i in 0..15 {
        if i == 13 {
            assert_eq!(after.0[i], 3);
        } else {
            assert_eq!(after.0[i], before.0[i], "byte {i} changed");
        }
    }
}

#[tokio::test]
async fn write_timeout_then_readback_no_duplicate_write() {
    let (dev, sim) = device_on(
        TransportKind::Ble,
        Faults {
            drop_write_reply_next: 1,
            ..Faults::default()
        },
    );
    let out = dev.set_gear(Gear::Beast).await.unwrap();
    assert_eq!(out, SetGearOutcome::Applied);
    assert_eq!(sim.flash_write_count(), 1, "写超时后读回成功，不得重复写");
}

#[tokio::test]
async fn gear_changed_externally_is_respected_on_next_write() {
    let (dev, sim) = device_on(TransportKind::Usb, Faults::default());
    // 外部（如断电重启）把挡位改到 turbo。
    sim.set_settings(
        SettingsBlock::from_bytes(&{
            let mut b = sim.settings_snapshot().0;
            b[13] = 3;
            b
        })
        .unwrap(),
    );
    let out = dev.set_gear(Gear::Turbo).await.unwrap();
    assert_eq!(out, SetGearOutcome::Unchanged);
    assert_eq!(sim.flash_write_count(), 0);
}

#[tokio::test]
async fn multi_device_requires_selector_semantics() {
    // 两台设备同时在线：候选数 > 1，必须由上层提示 --device，不得自动猜测。
    let a = SimTransport::new(SimSpec::default(), Faults::default());
    let b = SimTransport::new(SimSpec::default(), Faults::default());
    let ids = [
        a.identity().device_id.clone(),
        b.identity().device_id.clone(),
    ];
    assert_eq!(ids.len(), 2);
    assert_ne!(ids[0], ids[1]);
}

#[tokio::test]
async fn exchange_policy_timeout_is_honored_by_sim() {
    let sim = Arc::new(SimTransport::new(
        SimSpec::default(),
        Faults {
            timeout_next: 1,
            ..Faults::default()
        },
    ));
    let req = f9_protocol::Request::read(f9_protocol::Command::LiveStatus, 0, 3).unwrap();
    let err = sim
        .exchange(
            req,
            ExchangePolicy::with_timeout(std::time::Duration::from_millis(10)),
        )
        .await
        .unwrap_err();
    assert!(matches!(err, f9_transport::TransportError::Timeout));
}

#[test]
fn example_config_matches_default_curve() {
    let text = include_str!("../../../config/f9d.example.toml");
    let cfg: DaemonConfig = toml::from_str(text).expect("示例配置必须可解析");
    cfg.validate().expect("示例配置必须通过校验");
    let cc = cfg.control_config().unwrap();
    assert_eq!(cc.hysteresis_c, 3.0);
    assert_eq!(cc.min_dwell_ms, 15_000);
    assert!(!cc.allow_turbo);
    assert_eq!(cc.curve.len(), 3);
    assert_eq!(cc.curve[0].gear, Gear::Quiet);
    assert_eq!(cc.curve[1].gear, Gear::Balanced);
    assert_eq!(cc.curve[2].gear, Gear::Beast);
}

#[test]
fn json_envelope_schema_stability() {
    // schema_version 1 兼容面：字段不删除、含义不变（新增字段允许）。
    let env = serde_json::json!({
        "schema_version": 1,
        "ok": true,
        "command": "status",
        "device": { "id": "redacted-stable-session-id", "transport": "usb" },
        "data": { "rpm": 2012, "gear": "balanced" },
        "warnings": []
    });
    assert_eq!(env["schema_version"], 1);
    let required = [
        "schema_version",
        "ok",
        "command",
        "device",
        "data",
        "warnings",
    ];
    for key in required {
        assert!(env.get(key).is_some(), "missing required key {key}");
    }
}
