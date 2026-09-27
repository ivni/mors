use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

pub const SCHEMA: u32 = 1;
/// Opaque stable identifier, not a display name or filesystem path.
#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Id(String);
impl Id {
    pub fn new(value: &str) -> Result<Self> {
        if value.len() != 32
            || !value
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(Error::Invalid);
        }
        Ok(Self(value.into()))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
    pub(crate) fn valid(&self) -> bool {
        Self::new(&self.0).is_ok()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    NaiveProxy,
    Vless,
    Shadowsocks,
    NativeVpn,
}

#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
}
impl Endpoint {
    fn valid(&self) -> bool {
        !self.host.is_empty()
            && self.host.len() <= 253
            && self.port != 0
            && self
                .host
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b".-:".contains(&b))
    }
}
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "snake_case", deny_unknown_fields)]
pub enum Trust {
    System,
    /// CA is immutable protected material, retained with registry backups.
    Custom {
        ca: Id,
        revision: u64,
    },
}
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Tls {
    pub server_name: String,
    pub trust: Trust,
    pub revision: u64,
}

/// Version is per protocol payload, independently of the registry schema.
/// No URI or arbitrary engine options are accepted.
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Profile {
    NaiveProxy {
        version: u32,
        endpoint: Endpoint,
        auth: Id,
        tls: Tls,
    },
    /// Protected protocol-specific input; interpretation belongs to the adapter.
    Vless {
        version: u32,
        parameters: Id,
    },
    Shadowsocks {
        version: u32,
        parameters: Id,
    },
    NativeVpn {
        version: u32,
        object: Id,
    },
}
impl Profile {
    pub fn kind(&self) -> Kind {
        match self {
            Self::NaiveProxy { .. } => Kind::NaiveProxy,
            Self::Vless { .. } => Kind::Vless,
            Self::Shadowsocks { .. } => Kind::Shadowsocks,
            Self::NativeVpn { .. } => Kind::NativeVpn,
        }
    }
    pub(crate) fn references(&self) -> Vec<&Id> {
        match self {
            Self::NaiveProxy { auth, tls, .. } => {
                let mut result = vec![auth];
                if let Trust::Custom { ca, .. } = &tls.trust {
                    result.push(ca);
                }
                result
            }
            Self::Vless { parameters, .. } | Self::Shadowsocks { parameters, .. } => {
                vec![parameters]
            }
            Self::NativeVpn { .. } => vec![],
        }
    }
    fn validate(&self) -> Result<()> {
        let version = match self {
            Self::NaiveProxy {
                version,
                endpoint,
                auth,
                tls,
            } => {
                let name = Endpoint {
                    host: tls.server_name.clone(),
                    port: 443,
                };
                if !endpoint.valid() || !name.valid() || !auth.valid() || tls.revision == 0 {
                    return Err(Error::Invalid);
                }
                if let Trust::Custom { ca, revision } = &tls.trust {
                    if !ca.valid() || *revision == 0 {
                        return Err(Error::Invalid);
                    }
                }
                version
            }
            Self::Vless {
                version,
                parameters,
            }
            | Self::Shadowsocks {
                version,
                parameters,
            } => {
                if !parameters.valid() {
                    return Err(Error::Invalid);
                }
                version
            }
            Self::NativeVpn { version, object } => {
                if !object.valid() {
                    return Err(Error::Invalid);
                }
                version
            }
        };
        if *version != 1 {
            return Err(Error::Schema);
        }
        Ok(())
    }
}
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Connection {
    pub id: Id,
    pub kind: Kind,
    pub name: String,
    pub enabled: bool,
    /// Accepted configuration, not a health/admission/capability assertion.
    pub confirmed: bool,
    pub revision: u64,
    pub profile: Option<Profile>,
}
impl Connection {
    pub fn selection_candidate(&self) -> bool {
        self.enabled && self.confirmed && self.profile.is_some()
    }
}
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Registry {
    pub schema: u32,
    pub revision: u64,
    pub connections: Vec<Connection>,
}
impl Default for Registry {
    fn default() -> Self {
        Self {
            schema: SCHEMA,
            revision: 0,
            connections: vec![],
        }
    }
}
impl Registry {
    pub fn validate(&self) -> Result<()> {
        if self.schema != SCHEMA {
            return Err(Error::Schema);
        }
        if self.connections.len() > 4096 {
            return Err(Error::Invalid);
        }
        let mut ids = BTreeSet::new();
        for c in &self.connections {
            if !c.id.valid()
                || !ids.insert(&c.id)
                || c.name.is_empty()
                || c.name.len() > 256
                || c.name.chars().any(char::is_control)
                || c.revision == 0
                || (c.confirmed && c.profile.is_none())
            {
                return Err(Error::Invalid);
            }
            if let Some(p) = &c.profile {
                p.validate()?;
                if p.kind() != c.kind {
                    return Err(Error::Invalid);
                }
            }
        }
        Ok(())
    }
    /// Closed safe snapshot: names and all protocol data stay private.
    pub fn snapshot(&self) -> Vec<Snapshot> {
        self.connections
            .iter()
            .map(|c| Snapshot {
                id: c.id.clone(),
                kind: c.kind,
                enabled: c.enabled,
                confirmed: c.confirmed,
                revision: c.revision,
            })
            .collect()
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Snapshot {
    pub id: Id,
    pub kind: Kind,
    pub enabled: bool,
    pub confirmed: bool,
    pub revision: u64,
}

macro_rules! redacted_debug {
    ($($t:ty),*) => { $(impl std::fmt::Debug for $t {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str(concat!(stringify!($t), "([REDACTED])")) }
    })* };
}
redacted_debug!(Endpoint, Trust, Tls, Profile, Connection, Registry);
