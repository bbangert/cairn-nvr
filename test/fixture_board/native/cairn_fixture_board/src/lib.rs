//! The fixture board's NIF library: one function, so that the base's
//! loader has a board NIF to resolve from the board directory's `priv` and
//! to ask for the contract it was built against.

/// The `Cairn.Stage.contract/0` this library is built against. Not read
/// from the Elixir source: a contract bump must fail the fixture's boot
/// test until the fixture is moved along with it.
const CONTRACT: u32 = 1;

#[rustler::nif]
fn contract() -> u32 {
    CONTRACT
}

rustler::init!("Elixir.Cairn.FixtureBoard.Native");
