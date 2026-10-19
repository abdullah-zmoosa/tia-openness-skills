# Security policy

## Scope
These tools drive Siemens TIA Portal Openness on engineering PCs and can modify PLC projects.
Treat any issue that could cause an **unintended change to a project or a PLC** as a security issue.
Examples: a way around the writer's safety rails, writing outside the local work area, publishing
without the change check, touching safety (F-) blocks, or anything that could trigger a download.

## Reporting
Please **don't open a public issue** for vulnerabilities. Use the repository's private
"Report a vulnerability" (GitHub security advisories) and include:
- what you did (commands, environment variables, TIA version)
- what happened vs. what should have happened
- whether a real project or PLC was affected

Don't attach real PLC projects or exports. Reproduce with a small synthetic project.

## Design rules we keep
- The reader only ever opens **copies** of projects.
- The writer writes only to the local work area, backs up first, saves only on a clean compile,
  refuses F- and know-how-protected blocks and protected folders, and **never downloads to a PLC**.
- Publishing to a shared location happens only on explicit request, after a change check and a backup.
- No credentials, no network services, no telemetry.

## Supported versions
Only the latest release receives fixes.
