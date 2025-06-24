# Schema.org Validator

This repository contains a Perl-based Schema.org validator that scans HTML files for embedded JSON-LD (`application/ld+json` blocks) and validates them against a local schema definition.
It can optionally output diagnostics in SARIF format for GitHub Code Scanning integration.

# Local Testing

```bash
perl bin/validate-schema.pl --file sample/sample.html
```
