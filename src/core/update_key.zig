//! Открытый ключ Ed25519, которым подписан манифест обновлений (latest.json).
//! Секретная часть — у владельца (~/.config/rdc/update-signing.key) и в секрете
//! RDC_UPDATE_KEY на GitHub; в репозитории её нет.
pub const public_key_hex = "e524c6d2d9f8ed8769140070ede785ee49e752c6a2028d0501cb7154f449581d";
