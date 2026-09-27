# Contributing

Run `cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D warnings`, `flutter analyze`, and `flutter test` before submitting changes.

Keep realtime callbacks allocation-free and bounded. New wire fields require protocol tests, and timing changes require a deterministic scenario with a fixed seed.

