//! The Rockchip board library's native half: one cdylib the BEAM loads as
//! `Cairn.Rockchip.Native`, and the probe binary. It depends on `cairn-detect`
//! and nothing in the base.

rustler::init!("Elixir.Cairn.Rockchip.Native");
