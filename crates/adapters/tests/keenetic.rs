use mors_adapters::keenetic::*;
use mors_adapters::{Adapter, NaiveProxy};
use mors_domain::{Capability, Transport};
const OLD: &[u8] = include_bytes!("fixtures/interfaces-3-array.json");
const NEW: &[u8] = include_bytes!("fixtures/interfaces-5-map.json");
const XML: &[u8] = include_bytes!("fixtures/components-5.xml");

#[test]
fn offline_and_missing_fields_are_preserved_without_guessing() {
    let rows = parse_interfaces(200, OLD).unwrap();
    assert_eq!(rows[0].administrative, State::Up);
    assert_eq!(rows[0].link, State::Down);
    assert_eq!(rows[0].connected, Connected::No);
    assert_eq!(rows[0].system_name, None);
    assert_eq!(rows[0].role, Role::Unknown);
    assert_eq!(rows[1].administrative, State::Down);
    assert_eq!(rows[1].role, Role::Unknown); // A provider PPTP is not inferred to be a client.
    assert_eq!(rows[2].disposition, Disposition::Upstream); // Even without defaultgw.
    assert_eq!(rows[3].system_name.as_deref(), Some("opkg21")); // No invented t2s21 mapping.
    assert_eq!(rows[3].disposition, Disposition::ProxyNeedsOwnership);
    assert_eq!(rows[4].disposition, Disposition::OutsideScope);
    assert_eq!(rows[5].role, Role::Server);
    assert_eq!(rows[6].id, None);
    assert_eq!(rows[6].administrative, State::Unknown);
    assert_eq!(rows[6].connected, Connected::Unknown);
}
#[test]
fn map_shape_and_unrecognised_types_do_not_grant_admission() {
    let rows = parse_interfaces(200, NEW).unwrap();
    let get = |id| rows.iter().find(|r| r.id.as_deref() == Some(id)).unwrap();
    assert_eq!(get("GigabitEthernet0").role, Role::Upstream);
    assert_eq!(get("Bridge0").disposition, Disposition::OutsideScope);
    assert_eq!(get("New0").disposition, Disposition::Unknown);
    assert_eq!(get("Wireguard0").role, Role::Unknown); // Up is not proof of client egress.
    let row = parse_interfaces(200, br#"{"Wireguard9":{"type":"Wireguard"}}"#).unwrap();
    assert_eq!(row[0].id, None);
}
#[test]
fn protocol_subtypes_are_not_guessed() {
    for kind in ["IKE", "L2TP", "Wireguard", "SSTP", "OpenConnect", "PPTP"] {
        let body = format!(r#"[{{"type":"{kind}"}}]"#);
        let row = &parse_interfaces(200, body.as_bytes()).unwrap()[0];
        assert_eq!(row.kind.as_deref(), Some(kind));
        assert_eq!(row.role, Role::Unknown);
        assert_eq!(row.disposition, Disposition::VpnNeedsValidation);
    }
}
#[test]
fn http_and_nested_semantic_errors_are_separate() {
    for status in [301, 401, 403, 404, 500, 503] {
        assert_eq!(
            parse_interfaces(status, b"secret response"),
            Err(Error::Http(status))
        );
    }
    for body in [
        r#"[{"status":"error","message":"secret"}]"#,
        r#"{"result":{"error":"secret"}}"#,
        r#"{"status":[{"status":"error","code":"x"}]}"#,
    ] {
        assert_eq!(parse_interfaces(200, body.as_bytes()), Err(Error::Semantic));
    }
}
#[test]
fn malformed_responses_fail_without_partial_inventory() {
    for body in [
        "",
        "null",
        "true",
        "[1]",
        "{",
        r#"[{"id":4}]"#,
        r#"[{"type":"IKE","defaultgw":"false"}]"#,
        r#"[{"type":"IKE","connected":true}]"#,
        r#"[{"id":"x"},{"id":"x"}]"#,
        r#"{"result":{"unexpected":true}}"#,
        r#"[{"id":"x"},{}]"#,
    ] {
        assert_eq!(
            parse_interfaces(200, body.as_bytes()),
            Err(Error::Malformed),
            "{body}"
        );
    }
    assert_eq!(
        parse_interfaces(200, &vec![b' '; MAX_RESPONSE_BYTES + 1]),
        Err(Error::Limit)
    );
    assert!(parse_interfaces(200, b"[]").unwrap().is_empty());
}
#[test]
fn component_names_are_scoped_to_installed_manifest_entries() {
    let c = parse_components(XML).unwrap();
    assert!(c.contains("proxy"));
    assert!(!c.contains("NotAComponent"));
    assert!(!c.contains("wireguard"));
    assert_eq!(c.os_version.as_deref(), Some("5.00.C.12.0-0"));
    let old =
        parse_components(b"<components><component><name>base</name></component></components>")
            .unwrap();
    assert_eq!(old.os_version, None);
}
#[test]
fn malformed_xml_and_entities_fail_closed() {
    for xml in [
        "",
        "<components>",
        "<other/>",
        "<components><component/></components>",
        "<components><component><name>x</name><name>y</name></component></components>",
        "<!DOCTYPE components [<!ENTITY x 'secret'>]><components>&x;</components>",
    ] {
        assert_eq!(parse_components(xml.as_bytes()), Err(Error::Malformed));
    }
    assert_eq!(
        parse_components(&vec![0; MAX_RESPONSE_BYTES + 1]),
        Err(Error::Limit)
    );
}
struct Fixture {
    reads: Vec<&'static str>,
    components_error: bool,
}
impl ReadOnlySource for Fixture {
    fn interfaces(&mut self) -> Result<(u32, Vec<u8>), Error> {
        self.reads.push("interfaces");
        Ok((200, NEW.to_vec()))
    }
    fn components(&mut self) -> Result<Vec<u8>, Error> {
        self.reads.push("components");
        if self.components_error {
            Err(Error::Unavailable)
        } else {
            Ok(XML.to_vec())
        }
    }
}
#[test]
fn discovery_reads_only_and_component_failure_does_not_hide_interfaces() {
    for missing in [false, true] {
        let mut source = Fixture {
            reads: vec![],
            components_error: missing,
        };
        let inv = discover(&mut source).unwrap();
        assert_eq!(source.reads, ["interfaces", "components"]);
        assert_eq!(inv.interfaces.len(), 6);
        assert_eq!(inv.components.is_err(), missing);
        assert_eq!(
            NaiveProxy.transport_capability(Transport::Tcp),
            Capability::Unknown
        );
        assert_eq!(
            NaiveProxy.transport_capability(Transport::Udp),
            Capability::Unsupported
        );
    }
}
#[test]
fn bounded_reader_cannot_allocate_an_unbounded_body() {
    assert_eq!(read_bounded(&b"abc"[..]).unwrap(), b"abc");
    assert_eq!(read_bounded(std::io::repeat(0)), Err(Error::Limit));
}
