# Schema.org Validator

This repository contains a Schema.org validator that scans HTML files for embedded JSON-LD (`application/ld+json` blocks) and validates them against a local schema definition.
It can optionally output diagnostics in SARIF format for GitHub Code Scanning integration.

The Validator is a versatile tool designed to help you validate structured data embedded in your HTML files.
At its core, the script parses HTML to extract
```html
<script type="application/ld+json">
```
blocks and validates the included JSON-LD against a set of built‑in schema rules—verifying properties such as required fields, proper date formats (e.g., for startdate), enumerated values, and cross‑field consistency (like ensuring a MusicEvent’s performer is either a Person or a PerformingGroup).
For basic usage, simply run
```bash
bin/validate-schema --file sample/sample.html
```
to receive interactive console feedback about any missing or invalid properties.
The file can be a URL.

## Integration with GitHub Actions

To integrate with GitHub Code Scanning and CI/CD pipelines, you can activate SARIF output by adding the --github flag, which aggregates diagnostics into a schema_validation.sarif file.

## Dynamic Mode

If you want your validations to be driven by the most current standards, the --dynamic flag instructs the tool to download and cache the latest Schema.org vocabulary (currently loading over 900 classes) so that dynamic validations can be performed against live schema definitions.
You may combine these flags as needed—using --file with either or both of --github and --dynamic to tailor the tool for local testing, automated code analysis, or an in‑depth schema audit.
