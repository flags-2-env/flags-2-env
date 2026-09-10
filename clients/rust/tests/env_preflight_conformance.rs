use flags2env::env_map::{parse_canonical_env_value, EnvValueKind};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct Corpus {
    version: u32,
    cases: Vec<Case>,
}

#[derive(Debug, Deserialize)]
struct Case {
    name: String,
    kind: String,
    value: String,
    #[serde(rename = "allowEmpty")]
    allow_empty: bool,
    valid: bool,
}

#[test]
fn rust_matches_shared_env_preflight_corpus() {
    let raw = include_str!("../../../conformance/env-preflight-v1.json");
    let corpus: Corpus = serde_json::from_str(raw).expect("valid env preflight corpus");
    assert_eq!(corpus.version, 1);

    for case in corpus.cases {
        let kind = EnvValueKind::parse(&case.kind)
            .unwrap_or_else(|| panic!("{} has unknown kind {}", case.name, case.kind));
        let accepted = parse_canonical_env_value(kind, &case.value, case.allow_empty).is_some();
        assert_eq!(accepted, case.valid, "conformance case {}", case.name);
    }
}
