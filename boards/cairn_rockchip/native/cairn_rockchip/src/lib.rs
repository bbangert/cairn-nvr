//! The Rockchip board library's native half: one cdylib the BEAM loads as
//! `Cairn.Rockchip.Native`, the [`rknn`] backend, and the probe binary that
//! runs `cairn-detect`'s CLI with that backend registered. It depends on
//! `cairn-detect` and nothing in the base.

pub mod rknn;

rustler::init!("Elixir.Cairn.Rockchip.Native");
