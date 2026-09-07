//! 跨 crate 集成测试 crate。
//!
//! 实际测试位于 `tests/integration.rs`（cargo 集成测试目标），
//! 覆盖：USB/BLE 共同语义、写事务不变量、daemon 稳态无持续写、
//! 配置 schema 回归与 JSON envelope 兼容面（SPEC §17）。
