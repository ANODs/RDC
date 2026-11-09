//! Ed25519 public key that the update manifest (latest.json) is signed with.
//! The secret half is kept by the owner (~/.config/rdc/update-signing.key) and in the
//! RDC_UPDATE_KEY secret on GitHub; it is not in the repository.
pub const public_key_hex = "e524c6d2d9f8ed8769140070ede785ee49e752c6a2028d0501cb7154f449581d";
