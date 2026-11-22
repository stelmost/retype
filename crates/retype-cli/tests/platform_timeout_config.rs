//! Shared native-runner timeouts and early strict-workflow scheduling.

const CONFIG: &str = include_str!("../../../tests/nextest.toml");

#[test]
fn platform_tests_have_bounded_timeouts_without_retries() {
	let config: toml::Value = toml::from_str(CONFIG).unwrap();
	let profile = &config["profile"]["platform"];
	assert_eq!(profile["test-threads"].as_integer(), Some(4));
	assert_eq!(profile["retries"].as_integer(), Some(0));
	assert_eq!(profile["fail-fast"].as_bool(), Some(false));
	assert_eq!(profile["slow-timeout"]["period"].as_str(), Some("30s"));
	assert_eq!(profile["slow-timeout"]["terminate-after"].as_integer(), Some(2));
	assert_eq!(profile["leak-timeout"]["period"].as_str(), Some("3s"));
	assert_eq!(profile["leak-timeout"]["result"].as_str(), Some("fail"));
	let overrides = profile["overrides"].as_array().unwrap();
	assert_eq!(overrides.len(), 2);
	assert_eq!(overrides[0]["priority"].as_integer(), Some(100));
	let filter = overrides[0]["filter"].as_str().unwrap();
	assert!(filter.contains("test(=a_real_watched_heic_conversion_and_undo_preserve_the_original)"));
	assert!(filter.contains("test(=a_real_direct_heic_conversion_and_undo_follow_watched_disposition)"));
	let installer = &overrides[1];
	assert_eq!(
		installer["filter"].as_str(),
		Some("test(=windows_installation_rolls_back_failed_publications)")
	);
	assert_eq!(installer["slow-timeout"]["period"].as_str(), Some("70s"));
	assert_eq!(installer["slow-timeout"]["terminate-after"].as_integer(), Some(3));
}
