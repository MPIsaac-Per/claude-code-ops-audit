# Releasing

1. Confirm `main` is green and the dependency audit has no unresolved findings.
2. Re-run the synthetic ingestion test with the supported DuckDB version.
3. Move relevant entries from `Unreleased` in `CHANGELOG.md` into a dated version section.
4. Update `project.version` in `pyproject.toml` and `version` in `CITATION.cff`.
5. Open and merge a release pull request.
6. Create a signed tag in the form `vMAJOR.MINOR.PATCH` from the merge commit.
   Signing uses the repository's SSH signing configuration (`gpg.format ssh`,
   `user.signingkey`, `tag.gpgsign true`). Register the same public key as a
   signing key on GitHub so the tag shows as verified. v0.1.0 and v0.1.1
   predate this configuration and are unsigned.
7. Create a GitHub release from the tag and copy the matching changelog section into the release notes.
8. Verify the release page, source archive, and workflow results.

The repository does not publish corpus data or a package artifact. Releases identify tested methodology snapshots.
